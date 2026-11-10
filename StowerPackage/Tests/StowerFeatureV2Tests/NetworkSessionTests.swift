import Dependencies
import Foundation
@testable import StowerFeature
import Testing

@Suite
struct NetworkSessionTests {
    @Test
    func ingestionNeverUsesTheSharedSessionInTests() {
        #expect(networkSession() !== URLSession.shared)
    }

    @Test
    func ingestionFetchesThroughAnOverriddenSession() {
        let stub = URLSession(configuration: .ephemeral)

        let resolved = withDependencies {
            $0.urlSession = stub
        } operation: {
            networkSession()
        }

        #expect(resolved === stub)
    }
}
