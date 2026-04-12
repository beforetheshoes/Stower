import Foundation
@testable import StowerData
@testable import StowerFeature
import Testing

@Suite
struct ReaderAppearancePolicyTests {
    @Test
    func lineWidthPolicy_narrowerViewportYieldsNarrowerRangeAndDefault() {
        let narrow = ReaderLineWidthPolicy(viewportWidth: 375)
        let wide = ReaderLineWidthPolicy(viewportWidth: 834)

        #expect(narrow.range.upperBound < wide.range.upperBound)
        #expect(narrow.defaultWidth < wide.defaultWidth)
    }

    @Test
    func lineWidthPolicy_clampsStoredWidthIntoViewportRange() {
        let policy = ReaderLineWidthPolicy(viewportWidth: 375)

        #expect(policy.clamped(100) == policy.range.lowerBound)
        #expect(policy.clamped(980) == policy.range.upperBound)
    }

    @Test
    func defaultAppearance_resolvesToMeaningfulWidthOnNarrowAndWideViewports() {
        let appearance = ReaderAppearanceSettings()
        let narrow = ReaderLineWidthPolicy(viewportWidth: 375)
        let wide = ReaderLineWidthPolicy(viewportWidth: 1024)

        #expect(narrow.clamped(appearance.lineWidth) <= narrow.range.upperBound)
        #expect(wide.clamped(appearance.lineWidth) <= wide.range.upperBound)
        #expect(narrow.clamped(appearance.lineWidth) < wide.clamped(appearance.lineWidth))
    }

    @Test
    func readerCSS_usesViewportAwareCenteredArticleWidth_andLocksHorizontalOverflow() {
        let appearance = ReaderAppearanceSettings(lineWidth: 820)
        let policy = ReaderLineWidthPolicy(viewportWidth: 375)
        let css = appearance.readerCSS(pageWidth: 375)

        #expect(css.contains(".stower-article"))
        #expect(css.contains("max-width: \(policy.clamped(appearance.lineWidth))px !important;"))
        #expect(css.contains("overflow-x: hidden"))
        #expect(css.contains("overscroll-behavior-x: none"))
        #expect(css.contains("touch-action: pan-y pinch-zoom"))
        #expect(!css.contains("max-width: 820.0px !important;"))
    }
}
