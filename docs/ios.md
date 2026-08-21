# iOS

在 macOS 的 Xcode 中新建 iOS App 后，将 `ios/YNNuJwHelper` 内的 Swift 文件加入 target；最低目标建议 iOS 17。把 `YNNuJwHelperApp.swift` 设为入口，并把 `AppLockView.swift`、`WebContainer/`、`Networking/`、`Security/` 加入工程。部署前将 `your-domain.example` 替换为自己的 HTTPS Web App 域名。

将 `ios/YNNuJwHelper/Assets.xcassets` 整个目录加入 Xcode target，并在 Target → General → App Icons and Launch Screen 中选择 `AppIcon`。该资源目录包含航的助手统一应用图标。
