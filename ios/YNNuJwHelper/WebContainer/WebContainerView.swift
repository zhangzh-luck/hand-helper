import SwiftUI
import WebKit
struct WebContainerView: UIViewRepresentable { let url: URL
 func makeCoordinator()->Coordinator { Coordinator(self) }
 func makeUIView(context:Context)->WKWebView { let controller=WKUserContentController();controller.add(context.coordinator,name:"ynnuNative");let config=WKWebViewConfiguration();config.userContentController=controller;let web=WKWebView(frame:.zero,configuration:config);web.navigationDelegate=context.coordinator;web.load(URLRequest(url:url));return web }
 func updateUIView(_ webView:WKWebView,context:Context){}
 final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler { let parent:WebContainerView;init(_ p:WebContainerView){parent=p};func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){ /* 仅处理白名单桥接消息，令牌不注入 JS */ }
 func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){guard let host=action.request.url?.host else{return decisionHandler(.cancel)};let allowed=[parent.url.host,"jwmis.ynnu.edu.cn"].compactMap{$0};decisionHandler(allowed.contains(host) ? .allow:.cancel)} }
}
