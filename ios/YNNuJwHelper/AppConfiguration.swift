import Foundation

enum AppConfiguration {
    /// 来自 Info.plist。通过 Xcode 的 HAND_HELPER_WEB_URL 构建设置注入，避免在 Swift 源码中写死服务地址。
    static var webURL: URL? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "HandHelperWebURL") as? String,
            let url = URL(string: value),
            url.scheme == "https",
            url.host != nil,
            !url.host!.hasSuffix("example.invalid")
        else {
            return nil
        }
        return url
    }
}
