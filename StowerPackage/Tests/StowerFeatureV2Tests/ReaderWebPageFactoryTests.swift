@testable import StowerFeature
import Testing

@Suite
struct ReaderWebPageFactoryTests {
    @Test
    func contentTapScript_emitsChromeToggleURL_andSkipsInteractiveTargets() {
        let script = ReaderWebPageFactory.contentTapScript

        #expect(script.contains("stower-reader://toggle-chrome"))
        #expect(script.contains("a, button, input, textarea, select, option, label"))
        #expect(script.contains("iframe"))
        #expect(script.contains("video"))
        #expect(script.contains("audio"))
        #expect(script.contains(".stower-yt-facade"))
        #expect(script.contains("window.getSelection"))
    }
}
