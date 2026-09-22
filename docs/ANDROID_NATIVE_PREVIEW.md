# Android 原生预览说明

## 当前方案

Android 模块已从 Capacitor `BridgeActivity` 迁移为 Kotlin + Jetpack Compose 原生界面。应用不启动 WebView、不使用 `server.url`，也不再把 Web 构建产物作为运行界面。

- 应用名：航的助手
- 包名：`com.zhangzh.hangassistant`
- 当前原生预览版：`0.2.0`（versionCode `3`）
- 最低 SDK：23；编译与目标 SDK：35
- 仅声明权限：`android.permission.INTERNET`
- API 基地址：`https://hand.zhangzh.cc`（BuildConfig，不含秘密值）
- 当前构建：`HAND_HELPER_USE_LOCAL_PREVIEW=true`，页面不会发起 API 请求；`HandHelperApi` 仍保留为后续统一接入层。

Web/PWA、iOS 工程与线上后端没有被此迁移修改。

## 已实现的原生部分

- 原生登录表单，调用现有 `/api/v1/auth/login`；
- Android 通过 Keystore 加密存储服务端 Session Cookie，不保存账号密码；
- 今日、课程表、成绩分析、设置四个并列原生导航页；
- 原生课程表：具备切换学期、前后翻周，以及展示时间、教室、教师与周次的本地预览界面；
- 原生成绩：具备切换学期、成绩概览与课程卡片的本地预览界面；
- 返回逻辑：底部四个一级栏目互为同级，按返回均二次确认退出；以后进入二级页或弹窗时将优先关闭/返回二级状态；
- Material 3 浅色/深色外观、全面屏 Insets 和键盘 `adjustResize`；
- 使用无效测试账户验证 HTTPS 登录路由返回 `401`，说明路由可达。

当前阶段已切换为本地预览数据源：今日、课程表、成绩分析、设置均可独立验证原生布局和主要交互，不会读写真实数据。完成全部页面设计后，再将保留的 `HandHelperApi` 统一接回各页面。

成绩文件导入、AI 分析、课程表手动编辑、头像和设置保存仍将作为下一阶段原生界面迁移；现阶段不会回退到网页容器。

## 本地构建

```powershell
cd H:\教务助手\web\android
$env:JAVA_HOME = 'C:\Users\用户\tools\jdk-21.0.12.1+1'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
.\gradlew.bat assembleDebug --no-daemon --console=plain
```

APK 位于：

```text
H:\教务助手\web\android\app\build\outputs\apk\debug\app-debug.apk
```

## MuMu / adb 安装

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb devices
& $adb -s emulator-5556 install -r H:\教务助手\web\android\app\build\outputs\apk\debug\app-debug.apk
& $adb -s emulator-5556 shell monkey -p com.zhangzh.hangassistant 1
```

若出现 `offline`，请确认 MuMu ADB 端口已开启并重启 adb 服务；不要卸载应用，以免清除本地令牌。

## 2026-08-22 构建记录

- `assembleDebug`：通过；
- APK 大小：24,460,192 bytes；
- SHA-256：`BD932BDBB54E123149C7AEBE82BCA494377CEBA0B9C853DE15EDBEDE7F792A95`；
- 已在 MuMu `emulator-5556` 使用 `adb install -r` 覆盖安装并启动；
- `logcat` 未发现 `AndroidRuntime` 或 `FATAL EXCEPTION`。
