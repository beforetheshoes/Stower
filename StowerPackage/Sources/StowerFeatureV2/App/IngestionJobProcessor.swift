import ComposableArchitecture
import Foundation
import StowerData

// The ingestion queue's job pipeline: claim, run, and settle each job. Lives
// apart from `AppFeature`, which only decides *when* to drain.

/// Drains the ingestion queue until nothing is left to claim.
///
/// Call through `IngestionCoordinator.run` so two drains never overlap.
func processIngestionJobs(
    repository: StowerRepository,
    ingestionClient: URLIngestionClient,
    pdfIngestionClient: PDFIngestionClient,
    textIngestionClient: TextIngestionClient,
    ingestionCoordinator: IngestionCoordinator,
    now: @escaping @Sendable () -> Date
) async throws {
    // Jobs an earlier drain had to abandon go straight back in the queue.
    let interrupted = await ingestionCoordinator.takeInterrupted()
    if !interrupted.isEmpty {
        do {
            try await repository.releaseIngestionJobs(interrupted)
        } catch {
            for id in interrupted {
                await ingestionCoordinator.noteInterrupted(id)
            }
            throw error
        }
    }

    while let job = try await repository.claimNextIngestionJob(now()) {
        do {
            try await processIngestionJob(
                job,
                repository: repository,
                ingestionClient: ingestionClient,
                pdfIngestionClient: pdfIngestionClient,
                textIngestionClient: textIngestionClient
            )
            try await repository.completeIngestionJob(job.id, now())
        } catch where isIngestionInterruption(error) {
            // The app is being backgrounded (the database has stopped taking
            // locks) or the drain was cancelled. Nothing is wrong with this
            // import — recording it as a failure would blame the user's
            // article for the app being suspended. The database may refuse a
            // write right now, so the job is remembered and released at the
            // start of the next drain.
            await ingestionCoordinator.noteInterrupted(job.id)
            if error.isDatabaseSuspension, !Task.isCancelled {
                return
            }
            throw CancellationError()
        } catch {
            // `try?`, not `try`: if recording the failure itself fails, the
            // remaining queued imports must still be drained. Rethrowing here
            // stranded every job that the failing one was ahead of.
            try? await repository.failIngestionJob(job.id, error.localizedDescription, now())
        }
    }
}

/// Whether an import stopped because the app is going away rather than
/// because of the content being imported. Once the drain's task is cancelled
/// any error counts: cancellation surfaces as whatever the interrupted layer
/// happens to throw.
private func isIngestionInterruption(_ error: any Error) -> Bool {
    Task.isCancelled || error is CancellationError || error.isDatabaseSuspension
}

private func processIngestionJob(
    _ job: IngestionJob,
    repository: StowerRepository,
    ingestionClient: URLIngestionClient,
    pdfIngestionClient: PDFIngestionClient,
    textIngestionClient: TextIngestionClient
) async throws {
    @Dependency(\.articleSaveClient)
    var articleSaveClient
    switch job.kind {
        case .url:
            let trimmed = job.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw IngestionProcessingError.invalidHydrationURL(trimmed)
            }
            _ = try await articleSaveClient.save(url)
        case .pdf:
            // Payload is the absolute path of a PDF file that the share
            // extension or in-app picker copied into the shared App Group
            // container. The file lives inside a UUID-named subdirectory
            // (so the original filename is preserved for title fallback);
            // clean up the whole subdir once ingestion is done.
            let pdfURL = URL(fileURLWithPath: job.payload)
            let scratchDir = pdfURL.deletingLastPathComponent()
            do {
                let result = try await pdfIngestionClient.ingest(pdfURL)
                let item = try await repository.createItemFromIngestion(result)
                try? PDFArchiver.archivePDF(from: pdfURL, itemID: item.id)
                if let payload = try? AssetJobPayload(
                    itemID: item.id,
                    kind: .pdf,
                    originalFilename: pdfURL.lastPathComponent
                ).encoded() {
                    try? await repository.enqueueIngestionJob(.uploadAsset, payload)
                }
                try? FileManager.default.removeItem(at: scratchDir)
            } catch where isIngestionInterruption(error) {
                // Keep the staged file: the job runs again.
                throw error
            } catch {
                let fallback = pdfURL.deletingPathExtension().lastPathComponent
                _ = try? await repository.createItemFromIngestion(
                    .sharedText("Failed to ingest PDF: \(fallback)\n\n\(error.localizedDescription)")
                )
                try? FileManager.default.removeItem(at: scratchDir)
            }
        case .epub:
            // Payload is the absolute path of an EPUB the share extension
            // copied into the shared App Group container, inside a UUID-named
            // subdirectory that keeps the original filename for the title
            // fallback.
            @Dependency(\.epubIngestionClient)
            var epubIngestionClient
            let epubURL = URL(fileURLWithPath: job.payload)
            let scratchDir = epubURL.deletingLastPathComponent()
            do {
                let result = try await epubIngestionClient.ingest(epubURL)
                let item = try await repository.createItemFromIngestion(result)
                try? EPUBBookArchiver.archiveBook(from: epubURL, itemID: item.id)
                if let payload = try? AssetJobPayload(
                    itemID: item.id,
                    kind: .epub,
                    originalFilename: epubURL.lastPathComponent
                ).encoded() {
                    try? await repository.enqueueIngestionJob(.uploadAsset, payload)
                }
                try? FileManager.default.removeItem(at: scratchDir)
            } catch let error as EPUBIngestionError {
                // The file itself is the problem, so a retry cannot succeed.
                // Drop the staged copy and report the import as failed.
                try? FileManager.default.removeItem(at: scratchDir)
                throw error
            }
        case .text:
            let payload = QueuedTextPayloadCodec.decode(job.payload, defaultMode: .auto)
            let result = try await textIngestionClient.ingest(
                payload.content,
                nil,
                payload.titleHint,
                payload.mode
            )
            _ = try await repository.createItemFromIngestion(result)
        case .markdown:
            let payload = QueuedTextPayloadCodec.decode(job.payload, defaultMode: .markdown)
            let result = try await textIngestionClient.ingest(
                payload.content,
                nil,
                payload.titleHint,
                .markdown
            )
            _ = try await repository.createItemFromIngestion(result)
        case .hydrateText:
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(TextHydrationPayload.self, from: data)
            do {
                let mode = payload.rawSourceMode
                    .flatMap(TextImportMode.init(rawValue:))
                    ?? .auto
                let result = try await textIngestionClient.ingest(
                    payload.rawSourceText,
                    payload.title,
                    nil,
                    mode
                )
                try await repository.hydrateItemContent(payload.itemID, result)
            } catch where isIngestionInterruption(error) {
                throw error
            } catch {
                try? await repository.updateLocalContentStatus(payload.itemID, "failed", error.localizedDescription)
                throw error
            }
        case .hydrate:
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(HydrationPayload.self, from: data)
            if let url = URL(string: payload.url) {
                do {
                    try await repository.updateLocalContentStatus(payload.itemID, "downloading", nil)
                    _ = try await articleSaveClient.hydrate(payload.itemID, url)
                } catch where isIngestionInterruption(error) {
                    throw error
                } catch {
                    try? await repository.updateLocalContentStatus(payload.itemID, "failed", error.localizedDescription)
                    throw error
                }
            } else {
                throw IngestionProcessingError.invalidHydrationURL(payload.url)
            }
        case .website:
            // Payload is the absolute path of a .zip file the share extension
            // (or another background enqueuer) copied into the shared App
            // Group container (PendingWebsites/{uuid}/). The in-app picker
            // path imports inline via WebsiteImportService without touching
            // this queue.
            let zipURL = URL(fileURLWithPath: job.payload)
            let scratchDir = zipURL.deletingLastPathComponent()
            do {
                _ = try await WebsiteImportService.importWebsite(
                    zipURL: zipURL,
                    repository: repository
                )
                try? FileManager.default.removeItem(at: scratchDir)
            } catch where isIngestionInterruption(error) {
                // Keep the staged file: the job runs again.
                throw error
            } catch {
                let fallback = zipURL.deletingPathExtension().lastPathComponent
                _ = try? await repository.createItemFromIngestion(
                    .sharedText("Failed to import website: \(fallback)\n\n\(error.localizedDescription)")
                )
                try? FileManager.default.removeItem(at: scratchDir)
            }
        case .uploadAsset:
            let payload = try AssetJobPayload.decoded(from: job.payload)
            try await CloudAssetService.upload(payload: payload)
        case .downloadAsset:
            let payload = try AssetJobPayload.decoded(from: job.payload)
            try await CloudAssetService.restore(itemID: payload.itemID, repository: repository)
        case .migrateWebsiteAsset:
            let payload = try AssetJobPayload.decoded(from: job.payload)
            try await CloudAssetService.migrateWebsiteZip(
                itemID: payload.itemID,
                repository: repository
            )
        case .migrateCaptureAsset:
            let payload = try AssetJobPayload.decoded(from: job.payload)
            try await CloudAssetService.migrateCapture(
                itemID: payload.itemID,
                repository: repository
            )
        case .hydrateWebsite:
            // Receive-side: the website archive arrived via CloudKit sync but
            // the site isn't unpacked locally yet. Pull the zip bytes out of
            // the sync table and run the same unpack logic we use on the
            // originating device.
            let data = Data(job.payload.utf8)
            let payload = try JSONDecoder().decode(WebsiteHydrationPayload.self, from: data)
            do {
                guard let archive = try await repository.loadWebsiteArchive(payload.itemID) else {
                    throw IngestionProcessingError.missingWebsiteArchive
                }
                try await WebsiteImportService.hydrateWebsite(
                    itemID: payload.itemID,
                    archive: archive,
                    repository: repository
                )
            } catch where isIngestionInterruption(error) {
                throw error
            } catch {
                try? await repository.updateLocalContentStatus(
                    payload.itemID,
                    "failed",
                    error.localizedDescription
                )
                throw error
            }
        }
}

private enum IngestionProcessingError: LocalizedError {
    case invalidHydrationURL(String)
    case missingWebsiteArchive

    var errorDescription: String? {
        switch self {
        case .invalidHydrationURL(let value):
            "Invalid hydration URL: \(value)"
        case .missingWebsiteArchive:
            "The synced website archive is not available yet."
        }
    }
}
