import LocalAuthentication
import SwiftUI

struct AppLockView: View {
    @State private var unlocked = false
    @State private var authenticationFailed = false
    @State private var webLoadError: String?

    var body: some View {
        Group {
            if unlocked, let url = AppConfiguration.webURL {
                if let webLoadError {
                    WebLoadErrorView(message: webLoadError) {
                        self.webLoadError = nil
                    }
                } else {
                    WebContainerView(url: url) { message in
                        webLoadError = message
                    }
                }
            } else if unlocked {
                ConfigurationErrorView()
            } else {
                lockScreen
            }
        }
        .task {
            authenticate()
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("航的助手")
                .font(.title2.weight(.semibold))
            Text(authenticationFailed ? "无法完成验证，请重试。" : "请使用 Face ID 或设备密码解锁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("解锁", action: authenticate)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 没有设备锁屏密码时无法启用生物认证，仍允许本人在设备上打开应用。
            unlocked = true
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "保护航的助手中的个人数据"
        ) { success, _ in
            DispatchQueue.main.async {
                unlocked = success
                authenticationFailed = !success
            }
        }
    }
}

private struct ConfigurationErrorView: View {
    var body: some View {
        ContentUnavailableView(
            "尚未配置服务地址",
            systemImage: "network.slash",
            description: Text("请在 Xcode 构建设置中设置 HAND_HELPER_WEB_URL 为你的 HTTPS 服务地址，然后重新构建应用。")
        )
        .padding(24)
    }
}

private struct WebLoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                "无法打开航的助手",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
