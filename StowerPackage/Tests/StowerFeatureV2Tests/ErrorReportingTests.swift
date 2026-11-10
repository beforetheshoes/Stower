import Foundation
import GRDB
@testable import StowerData
import Testing

@Suite
struct ErrorReportingTests {
    private struct Unexpected: Error {}

    @Test
    func aSuccessfulOperationReturnsItsValue() async {
        let value = await reportingErrors { 42 }
        #expect(value == 42)
    }

    @Test
    func cancellationIsQuiet() async {
        let value: Int? = await reportingErrors { throw CancellationError() }
        #expect(value == nil)
    }

    @Test
    func aSuspendedDatabaseIsQuiet() async {
        let value: Int? = await reportingErrors {
            throw DatabaseError(resultCode: .SQLITE_INTERRUPT, message: "Database is suspended")
        }
        #expect(value == nil)
    }

    @Test
    func anythingElseIsReportedAndTheCallerCarriesOn() async {
        await withKnownIssue {
            let value: Int? = await reportingErrors { throw Unexpected() }
            #expect(value == nil)
        }
    }
}
