import Foundation
@testable import StowerData
import Testing

@Suite
struct ReadingProgressTests {
    @Test
    func snapshotCalculatesFractionAndPercent() {
        let progress = ReadingProgressSnapshot(currentUnitIndex: 2, totalUnitCount: 5)

        #expect(progress?.fractionComplete == 0.4)
        #expect(progress?.percentComplete == 40)
    }

    @Test
    func snapshotIsNilForUnreadOrCompleteExtremes() {
        #expect(ReadingProgressSnapshot(currentUnitIndex: 4, totalUnitCount: 5) == nil)
        #expect(ReadingProgressSnapshot(currentUnitIndex: 0, totalUnitCount: 1) == nil)
    }

    @Test
    func libraryReadingProgressShowsOnlyForPartialNonWebItems() {
        let partial = SavedItem(
            title: "Partial",
            content: "Body",
            renderFormat: .structuredV1,
            lastReadBlockIndex: 2,
            progressUnitCount: 6,
            isRead: true
        )
        #expect(partial.libraryReadingProgress?.percentComplete == 33)

        let unread = SavedItem(
            title: "Unread",
            content: "Body",
            renderFormat: .structuredV1,
            lastReadBlockIndex: 2,
            progressUnitCount: 6,
            isRead: false
        )
        #expect(unread.libraryReadingProgress == nil)

        let complete = SavedItem(
            title: "Complete",
            content: "Body",
            renderFormat: .structuredV1,
            lastReadBlockIndex: 5,
            progressUnitCount: 6,
            isRead: true
        )
        #expect(complete.libraryReadingProgress == nil)

        let webView = SavedItem(
            title: "Web",
            content: "Body",
            renderFormat: .webView,
            lastReadBlockIndex: 2,
            progressUnitCount: 6,
            isRead: true
        )
        #expect(webView.libraryReadingProgress == nil)
    }
}
