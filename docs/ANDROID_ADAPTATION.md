# Android（Capacitor）适配说明

## 方案

Web 端继续以 Vite 构建、Nginx 同源代理 `/api`；Android 使用 Capacitor 7 将 `web/dist` 打包进 APK。未配置 `server.url`，应用不会远程加载网页。

- 应用名：航的助手
- 包名：`com.zhangzh.hangassistant`
- Android `versionName`：`0.1.0`
- Android `versionCode`：`1`
- 最低 SDK：23
- 编译/目标 SDK：36
- Android API：`https://jw.zhangzh.cc`（可用 `VITE_ANDROID_API_URL` 覆盖）

## 认证与网络

前端请求集中在 `web/src/api.ts`。浏览器继续使用空基地址访问同源 `/api`；原生 WebView 由 `web/src/app-config.ts` 使用独立 HTTPS API 地址。

认证继续采用现有 Bearer Access Token 与 Refresh Token 机制，没有改动后端登录流程。当前令牌仍由既有前端逻辑保存在 WebView 的 localStorage；第一版没有把教务密码写入 APK 或页面代码。

后端 CORS 增加了严格的 `https://localhost` 与 `http://localhost` 来源，以兼容 Capacitor WebView，未启用通配符。

2026-07-17 已将该 CORS 兼容改动部署到腾讯云的 Hand Helper 后端容器。部署后已验证：后端与 Web 容器健康，`Origin: https://localhost` 对会话接口可获得 CORS 响应；未认证时返回 `401` 属预期认证行为。

## Android 原生适配

- 仅声明 `android.permission.INTERNET`；禁止明文 HTTP。
- 原生状态栏会随应用浅色/深色模式更新。
- 键盘使用 `adjustResize` 与 Capacitor body resize，避免遮挡输入框。
- Android 返回键优先关闭弹窗，其次回退页面；位于首页时弹出退出确认。
- Web 使用 `online/offline` 事件提示离线状态。
- Web/PWA 仍保持原样工作。

## 所需本机环境

安装 Android Studio（包含 Android SDK Platform 36、Build-Tools、Platform-Tools/adb）和 JDK 21 后，设置：

```powershell
$env:JAVA_HOME = '你的 JDK 21 目录'
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"
```

验证：

```powershell
java -version
adb devices
```

手机应显示为 `device`；若显示 `unauthorized`，在手机上确认 USB 调试授权。

## 构建 APK

在 `web` 目录执行：

```powershell
pnpm install --frozen-lockfile
pnpm run build
pnpm run cap:sync
pnpm run android:debug
```

生成的 APK：

```text
web/android/app/build/outputs/apk/debug/app-debug.apk
```

校验 SHA-256：

```powershell
Get-FileHash .\android\app\build\outputs\apk\debug\app-debug.apk -Algorithm SHA256
```

## 真机安装与日志

```powershell
adb devices
adb install -r .\android\app\build\outputs\apk\debug\app-debug.apk
adb shell monkey -p com.zhangzh.hangassistant 1
adb logcat -c
adb logcat | Select-String 'chromium|Capacitor|AndroidRuntime|hangassistant'
```

重点验证：管理员登录、课程表、成绩分析、深色模式、网络断开提示、弹窗返回与首页退出确认。

## 已知事项

- APK 已通过本机构建；真机安装仍等待 USB 调试授权。
- Android 的 HTTPS API 地址可通过 `web/.env.android.local` 的 `VITE_ANDROID_API_URL` 覆盖；该本地配置已忽略，不应写入敏感信息。
- 正式发布前应创建专用签名密钥；当前仅构建 debug APK。

## 本机验证记录（2026-07-17）

- 已安装 Android Studio Quail 2 2026.1.2，内置 OpenJDK 21。
- 已安装 Android SDK、Build-Tools 36、Platform 36.1 与 Platform-Tools；`adb` 已可用。
- Windows 工作区路径含中文，已在 `web/android/gradle.properties` 添加
  `android.overridePathCheck=true`，用于绕过 Android Gradle Plugin 的路径检查。
- 已生成 Debug APK：`web/android/app/build/outputs/apk/debug/app-debug.apk`。
- iQOO 已完成 USB 调试授权并显示为 `device`；后续可使用 `adb install -r` 覆盖安装。

## Debug APK 验证结果

- 构建命令：`gradlew.bat --no-daemon --console=plain assembleDebug`
- 产物：`web/android/app/build/outputs/apk/debug/app-debug.apk`
- 大小：4,285,087 bytes
- SHA-256：`411D0E5CC956049800DAE929859E85CC9D9EAB264342A4A6A818C68BD789D99B`
- 已通过 `adb install -r` 安装至 iQOO；启动后前台 Activity 为
  `com.zhangzh.hangassistant/.MainActivity`。
- 已检查应用进程日志，未发现 `AndroidRuntime`、`FATAL EXCEPTION`、未处理 Promise
  或 `net::ERR`。
