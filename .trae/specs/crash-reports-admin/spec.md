# 管理端崩溃报告查看与上报信息补全 Spec

> 目标仓库：客户端 `/home/portion/rustdesk`（本仓库）、管理平台 `/home/portion/tensorManage`（独立私有仓库）
> 前置已完成：`rustdesk` 提交 `7ea416aed`（panic + Flutter 异常上报）、`tensorManage` 提交 `e5cf572`（`POST /api/client/crash`、`crash_reports` 表）

## Why

客户端已能把 panic / Flutter 异常上报到控制平面，但管理端只能直接查库，没有任何界面；同时现有上报字段不足以稳定定位现场问题，且缺少防重复机制。

### 现有上报信息是否足够？（结论：不够）

当前一次上报包含：`kind`、`message`（panic 时带线程名与 `file:line`）、`backtrace`、`app_version`、`platform`（仅 `linux`/`windows` 这类 `std::env::consts::OS`）、`device_id`、`ip`、`ua`、`created_at`、`workspace_id`、`user_id`。

可直接定位的部分：

- panic 的 `message` 已包含 panic 位置（`file:line`）与线程名，多数情况足以定位到代码行。
- `workspace/user/device/ip/ua/version` 足以定位到具体租户、设备与版本。

缺口（按影响排序）：

1. **无崩溃前上下文**。只有调用栈和一句 panic 信息，没有崩溃前的日志，无法判断是哪个会话/操作触发的。
2. **系统信息过粗**。`platform` 只有 `linux`，缺少发行版/内核版本与 CPU 架构，而 RustDesk 的崩溃高度依赖 Wayland/X11、glibc、aarch64 等环境差异。
3. **release 二进制被 strip**（`Cargo.toml` `[profile.release] strip = true`），`std::backtrace` 往往只剩地址/`<unknown>`，调用栈价值有限。panic 位置仍可用，但调用路径基本丢失。
4. **Flutter 侧信息偏少**：只取了 `exceptionAsString` 与 stack，未带 `FlutterErrorDetails.context/library`。
5. **无防重复/限频**。`FlutterError.onError` 在同一进程内可被同一异常反复触发；panic 后若被守护进程循环拉起，会持续写入，批量重复把库和日志都打满。

### 本次决策

- 补全 1、2；3 不改（影响所有发行包体积与发布产物，单独决策，列入已知限制）；4 不改（`appType` 已通过 backtrace 前缀携带）。
- 针对 5 做**双层限频**：客户端进程内限频（上报端），服务端按设备固定窗口限频（防改包/循环重启绕过）。不做「相同崩溃聚合计数」（需要新增指纹与计数状态，超出本次范围，列入已知限制）。

## What Changes

客户端（`/home/portion/rustdesk`）：

- `src/crash_report.rs`
  - 上报体新增 `os_version`（发行版 + 系统长版本 + 内核版本）、`arch`（`std::env::consts::ARCH`）、`log_tail`（`Config::log_path()` 下最新日志文件末尾 8 KiB，UTF-8 lossy）。
  - 新增进程内限频：相同 `(kind, message)` 60 秒内只报一次；每进程 10 分钟内最多 10 条。panic 与 Flutter 异常共用同一限频入口，超限只 `log::trace!` 后跳过发送，不影响本地日志与崩溃处理。
  - 不改 `[profile.release]`，不改 panic hook 的既有本地日志行为。

管理平台（`/home/portion/tensorManage`）：

- 新迁移 `backend/migrations/20260101000027_crash_report_context.sql`：`crash_reports` 增加 `os_version TEXT`、`arch TEXT`、`log_tail TEXT`（`char_length <= 16000`）。
- `backend/src/routes/client.rs`
  - `CrashReportRequest` 接收并校验新字段（`os_version <= 128`、`arch <= 32`、`log_tail <= 16000`），写入 INSERT。
  - `report_crash` 入口做设备级限频：Redis 固定窗口，key=`crash:rl:{device_id 或 user_id}`，10 分钟最多 10 次，超限返回 `AppError::too_many`（429）；Redis 异常时 fail-open（记日志、放行），不因限流组件故障丢失崩溃信息。
- 新增 `backend/src/routes/crash_reports.rs`
  - `GET /api/v1/admin/crash-reports`：分页列表，过滤 `workspace_id`、`kind`，按 `created_at DESC`，JOIN `workspaces`/`users` 返回展示名；列表不返回 `backtrace` / `log_tail` / `ua`。
  - `GET /api/v1/admin/crash-reports/{id}`：详情，返回列表字段 + `backtrace` + `log_tail` + `ua`。
- `backend/src/auth/rbac.rs`：新增 `AdminPermission::ReadCrashReports`（`ALL` 26 → 27），授予 `ops`、`support`（`super_admin` 天然全量）。
- `backend/src/routes/mod.rs`：注册 `mod crash_reports;` 与两条 admin 路由。
- 前端
  - `src/api/types.ts`：`CrashReportKind`、`CrashReport`、`CrashReportDetail`。
  - `src/api/client.ts`：`adminListCrashReports`、`adminGetCrashReport`。
  - `src/pages/admin/CrashReportsPage.tsx`：列表（时间、工作区、用户、设备、类型、版本、系统/架构、摘要）+ 过滤（类型、工作区）+ 详情 Drawer（元信息、message、backtrace、日志尾部，均可复制）。
  - `src/router.tsx`：`/admin/crash-reports`。
  - `src/layouts/AdminLayout.tsx`：`nav.groupUsability` 下新增入口（`WarningOutlined`）。
  - 10 个 i18n locale：新增 `nav.crashReports` 与 `admin.crashReports.*`。

## Impact

- 客户端既有行为：仅在已有的崩溃上报请求体中增加 3 个字段，并增加进程内限频；发送失败/超限不影响崩溃处理与退出流程。
- 控制平面既有行为：`POST /api/client/crash` 向后兼容（新字段均可选，旧客户端照常入库）；新增限频只影响短时间超量的上报。
- 管理端既有页面/路由不变，仅新增菜单项与路由；新增权限不改变已有角色的既有权限集合。
- 不涉及 hbbs/hbbr、协议、租户隔离与设备流程。

## ADDED Requirements

### Requirement: 崩溃上报限频

客户端 SHALL 在进程内对重复崩溃限频；服务端 SHALL 按设备对上报限频，超限返回 429。

#### Scenario: Flutter 异常循环

- **WHEN** 同一 Flutter 异常在 60 秒内被反复抛出
- **THEN** 只发送第一条，其余只记录 trace 日志，不产生新上报

#### Scenario: 进程被循环拉起

- **WHEN** 同一设备 10 分钟内上报超过 10 次（进程内计数已随重启清零）
- **THEN** 服务端返回 429，数据库不再增长；窗口结束后恢复接收

#### Scenario: Redis 不可用

- **WHEN** 限流所需的 Redis 调用失败
- **THEN** 上报仍被接收并入库，仅记录告警日志

### Requirement: 崩溃报告列表与详情

管理端 SHALL 提供崩溃报告分页列表与详情查看；列表支持按 `kind`、`workspace_id` 过滤并显示工作区/用户展示名；详情包含完整 `message`、`backtrace`、`log_tail`。

#### Scenario: 查看某工作区的 panic

- **WHEN** 管理员在崩溃报告页选择工作区并筛选 `panic`
- **THEN** 只显示该工作区的原生崩溃，按时间倒序分页，可打开详情看到调用栈与日志尾部

#### Scenario: 无权限角色访问

- **WHEN** 角色不是 `super_admin` / `ops` / `support` 的账号访问 `/admin/crash-reports` 接口
- **THEN** 返回 403，页面无该菜单项

### Requirement: 上报补充系统与上下文信息

客户端 SHALL 在崩溃上报中携带 `os_version`、`arch`、`log_tail`；服务端 SHALL 做长度校验并按列存储。

#### Scenario: 原生 panic 上报

- **WHEN** 受管客户端发生 panic 且已配置 tenant proof
- **THEN** 上报体包含发行版/内核、CPU 架构与崩溃前 8 KiB 日志，管理端详情可见

#### Scenario: 旧客户端上报

- **WHEN** 未携带新字段的旧客户端上报
- **THEN** 服务端接受并以 `NULL` 存储，列表/详情正常展示

## Verification

1. 后端：`cargo check --all-targets`；`cargo test`（rbac 断言）。
2. 迁移：重启本地 API 容器自动执行迁移；`\d crash_reports` 确认三列；重复启动无报错。
3. 前端：`npm run build`（tsc + vite）。
4. 客户端：`cargo check --features flutter,linux-pkg-config`；`cargo fmt --check`（仅触及文件）。
5. 限频：同一设备凭据连续 `POST /api/client/crash` 11 次，前 10 次 204、第 11 次 429；等待窗口或清理 Redis key 后恢复。模拟 `FlutterError.onError` 连续触发，确认客户端只发一次。
6. 运行时：用有效设备凭据 `curl` 新请求体 → 管理端列表/详情可见；再用不含新字段的请求验证兼容。
7. 回归面：`POST /api/client/crash` 旧请求体；`/admin/feedback`、`/admin/issues`、`/admin/sessions` 既有页面与权限矩阵。

## Known Limits

- release `strip = true` 未改，调用栈可能仍无符号；panic `message` 中的 `file:line` 与新增日志尾部作为主要定位手段。若后续需要可读栈，需单独决定 `strip = "debuginfo"` 或发布符号包。
- 未做相同崩溃聚合计数：批量重复被限频丢弃，管理端看到的是每个窗口内的前若干条，而不是「1 条 × N 次」。后续可加指纹列与 `occurrences`。
- 客户端限频状态只在进程内，跨重启依赖服务端限频。
- 日志尾部可能含租户/设备标识等运行信息，仅管理端可读；不做脱敏。

## Approval

以上范围（含新增 `ReadCrashReports` 权限、新增 3 个上报字段、双层限频、10 个语言文件补齐）需确认后实施。
