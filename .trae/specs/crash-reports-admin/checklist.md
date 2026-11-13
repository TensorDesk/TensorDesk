# Checklist

- [x] 客户端 `send()` 上报体包含 `os_version` / `arch` / `log_tail`，且新增字段在 proof 为空时仍不阻止原有逻辑
- [x] 客户端对同一 `(kind, message)` 60s 内只上报一次，进程内 10 分钟最多 10 条；超限仅 `trace!` 不阻塞
- [x] 客户端 `cargo check --features flutter,linux-pkg-config` 通过
- [x] 客户端限频与 `os_version` 单测通过（2 passed）
- [x] 迁移 `20260101000027_crash_report_context.sql` 在 API 启动时自动执行，`crash_reports` 存在 `os_version` / `arch` / `log_tail` 三列与 `log_tail` 长度约束
- [x] 服务端 `CrashReportRequest` 接受新旧两种请求体（新字段可选），旧请求仍返回 204
- [x] 服务端 `os_version` / `arch` / `log_tail` / `device_id` 有长度上限校验，超限返回 400
- [x] 服务端按 `device_id`（缺省 `user_id`）10 分钟限 10 次，第 11 次返回 429 `RATE_LIMITED`；Redis 异常 fail-open
- [x] 管理端 `GET /api/v1/admin/crash-reports` 支持 `workspace_id` / `kind` / `page` / `page_size`，返回 `items` 与 `total`
- [x] 管理端 `GET /api/v1/admin/crash-reports/{id}` 返回详情（含 `backtrace` / `log_tail` / `ua`），不存在返回 404
- [x] RBAC 新增 `ReadCrashReports`（`ALL` 27），`ops` / `support` 允许，普通用户 403
- [x] 管理端页面可按类型、工作区过滤，分页正常，详情抽屉展示 message / backtrace / log_tail 并可复制
- [x] 菜单「可用性 → 崩溃报告」入口存在，路由 `/admin/crash-reports` 可访问（启动 200）
- [x] 10 个语言文件补齐 `nav.crashReports` 与 `admin.crashReports.*`
- [x] 前端 `npm run build` 通过；重建 web 镜像后浏览器实测列表与详情抽屉正常
- [x] 回归：`/admin/feedback`、`/admin/issues`、`/admin/sessions` 均返回 200
- [x] 集成测试产生的崩溃记录、Redis 限频 key 与临时 TOTP 配置已清理/还原
