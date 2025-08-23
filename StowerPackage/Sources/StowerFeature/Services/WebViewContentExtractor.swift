import Foundation
import WebKit
import SwiftSoup

@MainActor
public class WebViewContentExtractor: NSObject {
    private var webView: WKWebView?
    private var completion: ((Result<String, Error>) -> Void)?
    public var debugLogger: ((String) -> Void)?
    
    public override init() {
        super.init()
    }
    
    private func log(_ message: String) {
        print(message)
        debugLogger?(message)
    }
    
    public func extractRenderedHTML(from url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.completion = { result in
                continuation.resume(with: result)
            }
            
            // Configure WKWebView for content extraction
            let config = WKWebViewConfiguration()
            config.processPool = WKProcessPool()
            
            // Enable JavaScript execution
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            config.defaultWebpagePreferences = preferences
            
            // Disable media autoplay and other unnecessary features
            #if os(iOS)
            config.allowsInlineMediaPlayback = false
            #endif
            config.mediaTypesRequiringUserActionForPlayback = .all
            
            // Allow mixed content for sites with HTTP resources
            config.upgradeKnownHostsToHTTPS = false
            
            // Create webview
            self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            self.webView?.navigationDelegate = self
            
            log("🌐 WebView: Loading URL for rendering: \(url.absoluteString)")
            
            // Set a reasonable user agent
            self.webView?.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            
            // Load the URL
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            self.webView?.load(request)
            
            // Set a timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if self.completion != nil {
                    self.log("⏰ WebView: Timeout reached, extracting current content")
                    self.extractCurrentHTML()
                }
            }
        }
    }
    
    private func extractCurrentHTML() {
        guard let webView = webView, let completion = completion else { return }
        
        print("📄 WebView: Extracting rendered HTML content")
        
        // Get the full HTML after JavaScript rendering
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            DispatchQueue.main.async {
                if let htmlString = result as? String {
                    print("✅ WebView: Successfully extracted \(htmlString.count) characters of rendered HTML")
                    completion(.success(htmlString))
                } else if let error = error {
                    print("❌ WebView: Failed to extract HTML: \(error)")
                    completion(.failure(error))
                } else {
                    print("❌ WebView: Unknown error extracting HTML")
                    completion(.failure(WebViewExtractionError.unknownError))
                }
                
                self?.cleanup()
            }
        }
    }
    
    private func cleanup() {
        self.completion = nil
        self.webView?.navigationDelegate = nil
        self.webView?.stopLoading()
        self.webView = nil
        print("🧹 WebView: Cleaned up resources")
    }
}

// MARK: - WKNavigationDelegate

extension WebViewContentExtractor: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("🎯 WebView: Page finished loading, waiting for JavaScript to execute...")
        
        // Wait longer for dynamic content and check if content is still loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.waitForJavaScriptContent(webView, attempts: 0)
        }
    }
    
    private func waitForJavaScriptContent(_ webView: WKWebView, attempts: Int) {
        let maxAttempts = 5
        
        // Trigger any lazy loading by scrolling and dispatching events
        let triggerScript = """
        // Scroll to trigger lazy loading
        window.scrollTo(0, document.body.scrollHeight);
        window.scrollTo(0, 0);
        
        // Dispatch load events to trigger any remaining content
        window.dispatchEvent(new Event('load'));
        document.dispatchEvent(new Event('DOMContentLoaded'));
        
        // Return text length
        document.body.innerText.length;
        """
        
        // Execute the trigger script and check content length
        webView.evaluateJavaScript(triggerScript) { [weak self] result, error in
            DispatchQueue.main.async {
                if let textLength = result as? Int {
                    self?.log("🔍 WebView: Content check attempt \(attempts + 1), text length: \(textLength)")
                    
                    // If we have substantial content or reached max attempts, extract
                    if textLength > 500 || attempts >= maxAttempts {
                        self?.log("✅ WebView: Content ready with \(textLength) characters")
                        if self?.completion != nil {
                            self?.extractCurrentHTML()
                        }
                        return
                    }
                }
                
                // Wait a bit more and try again
                if attempts < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.waitForJavaScriptContent(webView, attempts: attempts + 1)
                    }
                } else {
                    self?.log("⏰ WebView: Max attempts reached, extracting current content")
                    if self?.completion != nil {
                        self?.extractCurrentHTML()
                    }
                }
            }
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ WebView: Navigation failed: \(error)")
        completion?(.failure(error))
        cleanup()
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("❌ WebView: Provisional navigation failed: \(error)")
        completion?(.failure(error))
        cleanup()
    }
}

// MARK: - Error Types

enum WebViewExtractionError: Error, LocalizedError {
    case unknownError
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .unknownError:
            return "Unknown error occurred during content extraction"
        case .timeout:
            return "Content extraction timed out"
        }
    }
}