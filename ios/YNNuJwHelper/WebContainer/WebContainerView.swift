import SwiftUI
import WebKit

struct WebContainerView: UIViewRepresentable {
    let url: URL
    let onLoadFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedHost: url.host, onLoadFailure: onLoadFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "handHelperNative")
        // WKWebView 不会匹配 PWA 的 standalone display-mode。页面据此采用
        // 原生容器专用的安全区布局，而不依赖 User-Agent 等不稳定的环境判断。
        controller.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('webview-native');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let allowedHost: String?
        private let onLoadFailure: (String) -> Void

        init(allowedHost: String?, onLoadFailure: @escaping (String) -> Void) {
            self.allowedHost = allowedHost
            self.onLoadFailure = onLoadFailure
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // 仅保留已注册桥接通道；不得向 JavaScript 注入账户、密码或令牌。
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard
                let targetURL = action.request.url,
                targetURL.scheme == "https",
                targetURL.host == allowedHost
            else {
                reportFailure("应用只能打开已配置的安全服务地址。")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            reportFailure("无法连接到服务，请检查网络或稍后重试。")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            reportFailure("页面加载中断，请重试。")
        }

        private func reportFailure(_ message: String) {
            DispatchQueue.main.async { [onLoadFailure] in
                onLoadFailure(message)
            }
        }
    }
}
