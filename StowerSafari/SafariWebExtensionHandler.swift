import SafariServices
import StowerData

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private final class RequestContext: @unchecked Sendable {
        let value: NSExtensionContext

        init(_ value: NSExtensionContext) {
            self.value = value
        }
    }

    func beginRequest(with context: NSExtensionContext) {
        let requestContext = RequestContext(context)
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard message?["action"] as? String == "save",
              let value = message?["url"] as? String,
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased())
        else {
            Self.complete(
                requestContext,
                response: Self.failure("This page cannot be saved.")
            )
            return
        }

        Task {
            do {
                try await ShareIngestionClient.enqueueURL(url)
                Self.complete(requestContext, response: ["success": true])
            } catch {
                Self.complete(
                    requestContext,
                    response: Self.failure(error.localizedDescription)
                )
            }
        }
    }

    private static func complete(
        _ requestContext: RequestContext,
        response: [String: Any]
    ) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        requestContext.value.completeRequest(returningItems: [item])
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["success": false, "error": message]
    }
}
