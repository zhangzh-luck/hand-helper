# API

所有 `/api/v1` 响应均为 `{success,data,error,request_id,server_time}`。除登录和健康检查外，API 均需浏览器携带 HttpOnly Session Cookie；前端不保存 Token。

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/v1/auth/login` | 应用管理员登录 |
| POST | `/api/v1/auth/logout` | 销毁当前服务端 Session 并清除 Cookie |
| GET | `/api/v1/auth/me` | 读取当前单用户登录状态 |
| GET | `/api/v1/terms` | 已由本地文件导入的学期 |
| POST | `/api/v1/timetable/import-file` | 导入打印 `.xls` 课表 |
| POST | `/api/v1/timetable/rebuild-sessions?term_id=` | 周次转日期 |
| POST | `/api/v1/grades/import-file?term_id=` | 识别成绩文件并返回预览 |
| POST | `/api/v1/grades/import-confirm` | 确认预览并覆盖该学期成绩缓存 |
| GET | `/api/v1/grades` / `/api/v1/grades/summary` | 读取成绩与分析汇总 |
| GET / PUT / DELETE | `/api/v1/ai/settings` | 单用户第三方模型配置（密钥不返回） |
| POST | `/api/v1/ai/settings/models` | 用本次填写的地址和密钥读取授权模型列表，不保存配置、不发送成绩 |
| POST | `/api/v1/ai/settings/test` | 用固定短文本测试模型连通性，不保存本次配置、不发送成绩 |
| POST | `/api/v1/grades/ai-analysis?term_id=` | 手动生成或读取成绩分析缓存 |

模型设置仅支持 HTTPS 的 OpenAI 兼容 Chat Completions 地址。`POST /api/v1/ai/settings/test` 只发送固定的“连接成功”测试文本，用于确认地址、模型 ID 与 API Key；`POST /api/v1/grades/ai-analysis` 只在用户主动点击后调用第三方服务；相同成绩快照优先返回缓存，可附加 `force_refresh=true` 重新生成。
