# iOS 构建与 IPA 发布

`ios/YNNuJwHelper.xcodeproj` 是航的助手的 SwiftUI + WKWebView 工程，包名为 `com.zhangzh.hangassistant`，最低 iOS 版本为 17。它加载已部署的 HTTPS Web 服务；不会把课程、成绩、API Key 或登录密码打包进 App。

## 本地 Xcode 构建

1. 在 macOS 安装 Xcode 后，打开 `ios/YNNuJwHelper.xcodeproj`。
2. 在 Target → Signing & Capabilities 中选择自己的 Team。
3. 在 Target → Build Settings 中把 `HAND_HELPER_WEB_URL` 设置为已部署的 HTTPS 服务地址。
4. 连接已开启开发者模式的 iPhone，选择设备后点击 Run，可安装调试版。
5. 需要 IPA 时选择 Product → Archive → Distribute App，再选择 Development、Ad Hoc 或 App Store Connect / TestFlight。

不要把证书、描述文件或任何账户密钥提交到 Git。

## GitHub Actions 编译

仓库内包含两个工作流：

- `.github/workflows/ios-build.yml`：无需签名，只验证 iOS Simulator 可以编译；产物是模拟器 `.app`，不能安装到真实 iPhone。
- `.github/workflows/ios-release.yml`：手动触发，导出可安装的签名 IPA。
- `.github/workflows/ios-unsigned-ipa.yml`：无需 Apple 证书，导出供本机签名工具处理的未签名设备 IPA。

若只需临时测试，可运行 **Build unsigned iOS IPA**。它不会保存或使用 Apple ID、证书、描述文件；下载产物后，需在本机使用你自己的签名工具签名，才能安装到 iPhone。

要运行签名 IPA 工作流，在 GitHub 仓库 Settings → Secrets and variables → Actions 中添加以下 **Repository secrets**（只添加，不要把值发给任何人）：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_BASE64` | 发布/开发证书 `.p12` 的 Base64 内容 |
| `IOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `IOS_PROVISIONING_PROFILE_BASE64` | 对应 `.mobileprovision` 的 Base64 内容 |
| `IOS_PROVISIONING_PROFILE_NAME` | 描述文件名称，不是文件名 |
| `IOS_TEAM_ID` | Apple Developer Team ID |

随后进入 Actions → **Export signed iOS IPA** → Run workflow：

1. `distribution` 选择 `development`、`ad-hoc` 或 `app-store-connect`；
2. 填入已部署的 HTTPS 服务地址；
3. 成功后从该工作流的 Artifacts 下载 `.ipa`。

`development` 一般用于已注册的测试设备；`ad-hoc` 也需要设备 UDID 在描述文件中；如果目标是个人 iPhone 的长期测试，通常更建议走 App Store Connect 后的 TestFlight。

## 命令行验证（macOS）

```bash
xcodebuild \
  -project ios/YNNuJwHelper.xcodeproj \
  -scheme YNNuJwHelper \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Windows 无法运行 Xcode 或签名 iOS IPA；可提交代码并由 GitHub 的 macOS Runner 执行上述工作流。
