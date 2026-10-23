# 航的助手原生 iOS 客户端：第一阶段

这是独立 SwiftUI iOS 工程。Flutter 客户端继续服务 Android；本工程只共享后端 API。

## 生成与运行

- XcodeGen 固定为 **2.44.1**。在 macOS 安装该版本后执行 `cd native_ios && xcodegen generate --spec project.yml`，打开 `HandHelperNative.xcodeproj`。
- GitHub Actions 从 XcodeGen 2.44.1 官方 release 下载二进制，并在 macOS 生成工程、编译及测试。生成的 `.xcodeproj` 不纳入 Git。
- Bundle ID：`com.zhangzh.hangassistant.native.dev`；最低系统：iOS 17；目标设备：iPhone、iPad。
- 默认 API 地址：`https://hand.zhangzh.cc`，与 `flutter_client/lib/api.dart` 的 `API_BASE_URL` 默认值一致。后续环境切换通过注入 `APIConfiguration` 实现。

## 本阶段实现范围

- SwiftUI `@main` 与 `AppState`；UIKit `UITabBarController` 持有四个独立 SwiftUI 页面。系统 TabBar 使用 `house`、`calendar`、`chart.bar`、`gearshape`，无可见文字，保留辅助功能名称。四个页面目前均为明确标注的开发期占位页面。
- 控制器不随标签切换重新创建。`AppState.isDetailPresented` 为后续详情页隐藏 TabBar 留接口；键盘遮挡底部时也隐藏 TabBar。首页图标可通过 `AppState.homeAvatar` 更换，后续提供头像裁剪和数据加载。
- `AppearanceMode` 支持系统、浅色、深色并用 `UserDefaults` 保存；`SessionStore` 抽象由 Keychain 实现，支持注入内存测试替身。
- `APIClient` 使用 `URLSession`、20 秒超时、JSON 解码、Cookie、非 GET 请求的 `Origin` 头、401 和服务端错误映射。`MockAPIClient` 用于无账号测试。当前**没有**完整认证、缓存、课程、成绩或导入逻辑。
- Assets 中 AppIcon 与 BrandMark 从现有 Flutter 素材复制，避免开发期重新设计品牌图像。

## 从 Flutter 提取的基础设计参数

| 参数 | 当前值 | 来源 |
|---|---|---|
| 主蓝色 | `#007AFF`，操作蓝 `#2563EB` | `flutter_client/lib/main.dart`、`analysis_page.dart`、`settings_page.dart` |
| 页面背景 | 浅色 `#F4F7FB`，深色黑色 | `settings_page.dart`、`analysis_page.dart` |
| 卡片基色 | 浅色白，深色 `#141416` | `analysis_page.dart`；设置页另有透明度 |
| 主文字 | 浅色 `#172033`，深色白 | `today_page.dart` |
| 次文字 | 浅色 `#64748B`，深色 `#A1A1A6` | `today_page.dart`、`settings_page.dart` |
| 标题/正文/辅助字号 | 27 / 15 / 12 pt；标题常用粗体 800 | `settings_page.dart`、`analysis_page.dart` |
| 卡片圆角 | 常用 18 pt；今日主卡 24 pt | `settings_page.dart`、`analysis_page.dart`、`today_page.dart` |
| 页面水平间距 | 18 pt；业务页将逐页核对 | `today_page.dart` 的 `EdgeInsets.fromLTRB(18, 26, 18, 0)`；`settings_page.dart` 的列表边距 |
| 阴影 | 如 `#0F172A` 约 6% 不透明度、9–10 pt 模糊 | `settings_page.dart`、`analysis_page.dart` |
| 动画 | TabBar 显隐 200 ms；常用 220 / 260 ms，`easeOutCubic` | `SceneDelegate.swift`、`main.dart`、`today_page.dart` |
| 图标 | `house`、`calendar`、`chart.bar`、`gearshape` | `flutter_client/ios/Runner/SceneDelegate.swift` |

壁纸裁切、阴影的最终视觉、iPad 尺寸和动态头像实际效果需与 Flutter 真机截图对照；本阶段没有凭空补充业务卡片。现有 Flutter 的今日、课程表、分析、设置、登录页面及动画尚未迁移。

## 后端协议依据

`flutter_client/lib/api.dart` 的 `_request` 使用 `{success, data, error: {message}}`；`GET /api/v1/auth/me` 的身份字段为 `username`。模型中学期使用 `id`、`source_term_id`、`display_name`、`start_date`、`is_current`，节次使用 `period_number`、`start_time`、`end_time`。本阶段只建立这些已确认字段，不主动请求真实账号数据。401 默认清除 Cookie；现有 Flutter 对“当前密码错误”的重新校验有保留会话例外，API 客户端通过显式参数保留该机制。

## 验证边界

Windows 本地可检查文件、JSON、YAML、受限路径和 Git 差异，无法编译 SwiftUI 或运行 XCTest。首次 macOS CI 需要核验工程生成、Swift 编译、模拟器运行、设备 Release 构建和无签名 IPA 内容。无签名 IPA 仅是构建产物，不能当作正式可安装包。
