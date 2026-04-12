import Foundation

/// Derives a meaningful reader line-width range from the current viewport
/// without introducing device-specific persistence or schema changes.
struct ReaderLineWidthPolicy: Equatable, Sendable {
    let range: ClosedRange<Double>
    let defaultWidth: Double

    init(viewportWidth: Double?) {
        guard let viewportWidth, viewportWidth.isFinite, viewportWidth > 0 else {
            self.range = ReaderAppearanceSettings.lineWidthRange
            self.defaultWidth = ReaderAppearanceSettings().lineWidth
            return
        }

        let availableWidth = max(
            ReaderAppearanceSettings.lineWidthRange.lowerBound,
            viewportWidth - 40
        )
        let upperBound = min(
            ReaderAppearanceSettings.lineWidthRange.upperBound,
            availableWidth
        )
        let lowerBound = min(
            upperBound,
            max(
                ReaderAppearanceSettings.lineWidthRange.lowerBound,
                min(420, availableWidth * 0.75)
            )
        )
        let defaultWidth = min(
            upperBound,
            max(lowerBound, min(820, availableWidth * 0.86))
        )

        self.range = lowerBound ... upperBound
        self.defaultWidth = defaultWidth
    }

    func clamped(_ width: Double) -> Double {
        min(max(width, range.lowerBound), range.upperBound)
    }
}
