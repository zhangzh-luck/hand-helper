# 部署

## 上线前配置

在项目根目录创建 `.env`（不要提交），至少配置：

- `CORS_ORIGINS=https://你的域名`
- `APP_ADMIN_PASSWORD_HASH`：真实 bcrypt 哈希
- `JWT_SECRET`：至少 32 字符的随机密钥

## 启动容器

```bash
cd /opt/hand-helper/deploy
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:8000/health
```

公网只开放 Nginx 的 80 和 443。上传的课程表与成绩文件最大 2 MB，解析后不会持久化原文件。

## 迁移说明

执行 `alembic upgrade head` 会应用已登记的数据库迁移；课程、成绩、个人资料和自定义安排不受影响。

## 备份与恢复

SQLite 位于 Docker Volume `jw-data`。备份前建议停止写入服务；恢复前停止服务并替换数据库文件后重新启动。不要执行全局 Docker 清理命令。
