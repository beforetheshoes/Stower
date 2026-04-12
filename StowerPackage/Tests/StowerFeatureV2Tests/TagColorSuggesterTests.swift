import Foundation
@testable import StowerData
import Testing

@Suite
struct TagColorSuggesterTests {
    @Test
    func suggestsFirstHue_whenNoTagsExist() {
        let hex = TagColorSuggester.suggestColor(existingHexValues: [])
        // First hue in FlexokiHue.allCases is red; shade 600.
        #expect(hex == FlexokiRaw.shade(.red, 600))
    }

    @Test
    func suggestsNextUnusedHue() {
        let redHex = FlexokiRaw.shade(.red, 600)
        let orangeHex = FlexokiRaw.shade(.orange, 600)
        let hex = TagColorSuggester.suggestColor(existingHexValues: [redHex, orangeHex])
        #expect(hex == FlexokiRaw.shade(.yellow, 600))
    }

    @Test
    func cyclesWhenAllHuesUsed() {
        let allHexes = FlexokiHue.allCases.map { FlexokiRaw.shade($0, 600) }
        let hex = TagColorSuggester.suggestColor(existingHexValues: allHexes)
        // When all hues are taken, wraps to first hue.
        #expect(hex == FlexokiRaw.shade(.red, 600))
    }

    @Test
    func skipsUsedHue_inMiddle() {
        // Only orange is used — should suggest red (first unused).
        let orangeHex = FlexokiRaw.shade(.orange, 600)
        let hex = TagColorSuggester.suggestColor(existingHexValues: [orangeHex])
        #expect(hex == FlexokiRaw.shade(.red, 600))
    }

    @Test
    func matchesAnyShadeOfHue() {
        // Red shade-400 should still count as "red used".
        let redShade400 = FlexokiRaw.shade(.red, 400)
        let hex = TagColorSuggester.suggestColor(existingHexValues: [redShade400])
        // Red is taken, so first suggestion is orange.
        #expect(hex == FlexokiRaw.shade(.orange, 600))
    }
}
