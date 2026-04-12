import Foundation

public enum TagColorSuggester {
    /// Returns the hex string for the next unused Flexoki hue at shade 600.
    ///
    /// Algorithm: check which `FlexokiHue` values are already represented in
    /// `existingHexValues` (matching any shade in the hue's ramp), then return
    /// the first unused hue's shade 600. Wraps to the first hue if all are used.
    public static func suggestColor(existingHexValues: [String]) -> String {
        let normalised = Set(existingHexValues.map { $0.uppercased() })
        let usedHues: Set<FlexokiHue> = Set(
            FlexokiHue.allCases.filter { hue in
                let rampValues = Set(FlexokiRaw.ramp(for: hue).values.map { $0.uppercased() })
                return !rampValues.isDisjoint(with: normalised)
            }
        )

        let suggested = FlexokiHue.allCases.first { !usedHues.contains($0) }
            ?? FlexokiHue.allCases[0]

        return FlexokiRaw.shade(suggested, 600)
    }
}
