# 今日页迁移记录（第二阶段）

## Flutter 对照

| 区域或行为 | Flutter 来源 | 原生实现 |
| --- | --- | --- |
| 问候、姓名、日期、头像 | `flutter_client/lib/today_page.dart` `_Hero`；`main.dart` `greeting` | `TodayView.hero`，头像有基础预览 |
| 今日安排、课程状态、卡片 | `today_page.dart` `build`、`_EntryCard` | `TodayView`、`CourseCardView` |
| 自定义安排操作 | `today_page.dart` `_ScheduleCard` 左滑 | `ScheduleCardView` 使用系统 Context Menu，仅有编辑和删除；不再提供左滑操作层 |
| 课程来源 | `api.dart` `today()`：`GET /api/v1/timetable` | `DiskCourseRepository.refresh`，完整场次持久化并按本机日期筛选 |
| 本地手动课程 | `api.dart` `LocalManualCourse`、`_withLocalManualCourses` | `ManualCourseRule`、`expandedManualCourses`，共享给后续课程表页 |
| 自定义安排 | `api.dart` `LocalScheduleStore`、`saveSchedule`、`deleteSchedule` | `CourseRepository` 本机原子写入，负 ID；已有安排可编辑、删除 |
| 壁纸 | `api.dart` `Profile.home_wallpaper_data_url`；`today_page.dart` 背景遮罩 | `WallpaperStore` 和 `TodayView`；照片选择入口在顶部卡片长按菜单 |
| 课表和时间 | `timetable_page.dart` `weekNumber`；`today_page.dart` `coursesForDay` | `CourseScheduleCalculator`，固定时钟可测试 |

Flutter 今日页读取后端**已展开的场次**，因此按 `session_date` 筛选，不再对服务端课程重新解析单双周。只有本机手动课程使用 `weeks`、`weekday`、学期开始日期、节次时间展开。课程卡片只展示信息；原生版自定义安排长按后通过系统菜单编辑或删除。

## 数据与状态

- 后端：`/api/v1/auth/me` 验证会话；`/api/v1/timetable` 提供课程场次；`/api/v1/terms` 和 `/api/v1/settings/period-times` 提供本地手动课程展开依据；`/api/v1/custom-schedules` 仅在首次成功加载时导入既有安排。
- 本机：完整课程快照、手动课程规则、个人展示资料和壁纸图片按 API 地址与当前会话 Cookie 的 SHA-256 隔离；自定义安排按已验证的 `user:<小写用户名>` 归属，保存在 Application Support。Keychain 中仅有 Cookie 不构成已登录状态；必须在本次启动通过 `/api/v1/auth/me` 验证后，才能读取账号缓存和安排。请求失败不覆盖当前已验证账号的有效快照。401 与退出登录会立即隐藏私人数据。
- 内存：当前时间、错误、加载状态和照片选择状态。自定义安排不再维护侧滑展开状态。
- Flutter 和原生客户端的沙盒独立，原生客户端不会直接读取 Flutter 的缓存或壁纸。照片菜单是本阶段的原生设置入口；将来设置页迁移后应共用 `WallpaperStore`。

## 当前差异及待验证

- 原生客户端采用全屏认证入口。未登录显示独立登录根页面；Keychain 中有 Cookie 时先验证 `/api/v1/auth/me`，验证成功才创建四 Tab 主界面并刷新今日课程。网络异常时显示重试页，Keychain 清理失败时显示清理重试入口。未验证身份不能查看或修改课程及自定义安排。
- 访客模式已取消，不生成访客 ID，不允许匿名安排读写，也不把匿名或临时会话数据自动迁入账号。此前开发版可能写入的 `guest:`、`session:` 记录保留在原有 `local_schedules_*.json` 文件中，当前客户端不会读取、迁移或删除它们。不同真实账号的安排使用稳定的 Flutter 风格 `user:<小写用户名>` 归属；这一规则依赖后端用户名保持稳定。旧 Flutter App 与新原生 App 的沙盒独立，不自动共享本地安排。
- 顶部头像预览和添加安排使用原生 sheet，尚未复刻 Flutter 的容器变形动画。照片选择入口位于顶部卡片长按菜单，待设置页迁移时对照原有设置入口。
- 课程表页尚未迁移，因此手动课程规则有共享模型和持久化接口，但没有编辑界面。服务端 `MANUAL` 场次在没有对应本地规则时仍显示，避免迁移期间丢课。
- 登录界面、Keychain 存储、会话恢复、401 清理、退出及本地账号隔离已落地；视觉细节、动态字体、键盘、照片裁切和登录状态切换仍需 macOS CI、XCTest 与真机验证。Windows 无 Xcode，本文不代表 Swift 编译或真机验收结果。
