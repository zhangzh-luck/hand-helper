# 安全

- `.env`、`private/`、数据库和上传临时文件均不提交 Git。
- 后端不保存教务系统账号、密码、Cookie 或会话状态，也不主动访问教务系统。
- 课表与成绩导出文件只在请求内存中解析，确认入库后仅保存结构化课程或成绩数据。
- 管理员密码只从环境变量读取 Argon2id 哈希；应用没有用户表、注册、角色或权限管理功能。
- 登录成功会创建随机高熵 Session；浏览器仅持有 `HttpOnly`、`SameSite=Lax` Cookie，SQLite 仅保存 Session ID 的 HMAC 与过期时间。生产 HTTPS 必须启用 `SESSION_COOKIE_SECURE=true`。
- 所有非公开 API 通过统一 Session Middleware 保护。写操作在浏览器携带 Origin/Referer 时会校验可信来源；登录尝试按 IP + 用户名限为 5 次失败 / 5 分钟。
- 上传文件限制为 2 MB，后端校验扩展名、内容结构和必需表头；不接受任意本地路径。
- 可选模型服务的 API Key 由 `.env` 中的 `AI_CREDENTIAL_MASTER_KEY` 使用 Fernet 加密后保存，读取接口只显示末四位。模型分析不会发送原始上传文件、应用密码、教务凭据或登录令牌。
- 模型请求只在用户点击“生成分析”后发生；服务地址必须是 HTTPS，且拒绝本机或内网 IP 地址。设置页的“读取可用模型”只请求供应商的模型列表，“测试连接”仅发送固定短文本；两者都不发送成绩、不保存本次填写的密钥。APIKEY.FUN 预设使用其公开生产入口 `https://api.apikey.fun/v1`。
