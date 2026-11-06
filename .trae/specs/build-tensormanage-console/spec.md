# TensorDesk 商业化多租户管理平台 Spec

> 权威设计文档：[docs/tensordesk-design.md](../../../docs/tensordesk-design.md)（已评审定稿）
> 本 Spec 只描述本次交付的增量范围与验收口径，不重复设计细节；两者冲突时以设计文档为准。
> 目标仓库：管理平台 `https://github.com/powerfs/tensorManage.git`（独立私有）

## Why

TensorDesk 目前只有共享 hbbs/hbbr 单实例，设备 ID 全局唯一，没有账号体系、设备归属、租户隔离与运营后台，无法对外提供商业化服务。需要在 M0 交付一个可运营的多租户管理平台：用户自助注册并把自己的设备归属到自己名下，管理员可管理用户，免费/付费套餐与支付能力预留接口。

## What Changes

- 客户端（本仓库）：让 `tenant-id` / `tenant-proof` 随注册、打洞、中继消息上报；修复改名后 `is_custom_client()` 恒为真的缺陷。
- 共享 hb_common proto：四个 rendezvous 消息新增租户字段（**BREAKING**：hbbs/hbbr 与客户端必须同版本配套）。
- 服务端：hbbs/hbbr 租户化 fork，内部以 `(tenant_id, device_id)` 为键，跨租户一律拒绝。
- 新仓库 `powerfs/tensorManage`：Rust/Axum 后端、React/AntD 前端、PostgreSQL/Redis、Docker Compose、统一配置与启停脚本。
- M0 不做：流量硬配额与限速、支付对接、自定义客户端构建、SSO/多地域（按设计文档 M1/M2 推进）。

## Impact

- 影响能力：客户端接入协议、设备归属、会话隔离、账号与运营后台、部署形态。
- 影响代码：
  - 本仓库：`libs/hbb_common/protos/rendezvous.proto`、`src/common.rs`、`src/custom_server.rs`、`src/rendezvous_mediator.rs`、`src/client.rs`、`src/server.rs`、`src/ui_interface.rs`、`src/core_main.rs`、`libs/base/src/config/keys.rs`
  - 新仓库：`backend/`、`frontend/`、`server/`（hbbs/hbbr fork）、`deploy/`
- 不改动与本需求无关的既有传输/编码路径；`feature off`（无 tenant 配置）时保持旧行为。

## ADDED Requirements

### Requirement: 客户端携带租户标识
客户端 SHALL 从自定义许可证（`tenant=` / `enroll=`）读取租户 ID 与接入令牌，持久化到配置项 `tenant-id` / `tenant-proof`，并在 `RegisterPeer`、`RegisterPk`、`PunchHoleRequest`、`RequestRelay` 中携带；未配置时字段为空，保持与旧服务端兼容。

#### Scenario: 配置许可证后注册携带租户
- **WHEN** 客户端以 `host=...,tenant=ws_abc,enroll=td1_xxx` 启动
- **THEN** 注册与打洞消息中 `tenant_id=ws_abc`、`tenant_proof` 为令牌原始字节

#### Scenario: 未配置租户时行为不变
- **WHEN** 客户端未配置 `tenant-id`
- **THEN** 上报字段为空，连接流程与改造前一致

### Requirement: 服务端租户隔离
hbbs/hbbr SHALL 离线校验 `tenant_proof`（Ed25519、过期、吊销），内部注册键为 `(tenant_id, device_id)`；打洞与中继只允许同租户配对。

#### Scenario: 同租户连接成功
- **WHEN** 租户 ws_a 的客户端 A 连接 ws_a 的设备 B
- **THEN** 打洞或中继成功建立会话

#### Scenario: 跨租户被拒绝
- **WHEN** 租户 ws_a 的客户端知道 ws_b 的设备 ID 并发起连接
- **THEN** 服务端返回租户不匹配错误，不泄露 ws_b 设备信息

#### Scenario: 同 ID 跨租户共存
- **WHEN** ws_a 与 ws_b 都注册了 9 位 ID `123456789`
- **THEN** 两次注册均成功，互不冲突

### Requirement: 接入令牌
平台 SHALL 签发 `td1_<base64url(payload)>.<base64url(sig)>` 格式令牌，payload 含 `v/tenant/user/scope/exp/nonce`；只存哈希，支持一次性/限时/长期、吊销与使用次数上限。

#### Scenario: 令牌部署设备
- **WHEN** 客户端用有效令牌调用 `/api/devices/deploy`
- **THEN** 设备绑定到令牌所属用户的工作区，并在控制台设备列表出现

#### Scenario: 吊销后拒绝
- **WHEN** 管理员吊销令牌后客户端再次注册
- **THEN** hbbs 在下一个缓存周期内拒绝该令牌

### Requirement: 账号体系与自助注册
平台 SHALL 提供注册、登录、手机号与邮箱验证、密码重置，验证码 5 分钟一次性并做频控；被封禁账号无法登录且其租户被服务端拒绝。

#### Scenario: 注册并验证
- **WHEN** 新用户提交邮箱与手机号并完成两次验证码校验
- **THEN** 账号状态为 active，系统自动创建个人工作区（Free 套餐）

#### Scenario: 管理员封禁
- **WHEN** 管理员封禁某用户并填写原因
- **THEN** 该用户无法登录，其租户在 60s 内被 hbbs 拒绝注册/连接，操作写入审计

### Requirement: 设备归属与在线列表
平台 SHALL 通过心跳维护设备在线状态与连接数，设备列表按工作区隔离展示。

#### Scenario: 心跳上线
- **WHEN** 已绑定设备每 15s 上报 `/api/heartbeat`
- **THEN** 列表中该设备显示在线、最后心跳时间、连接数

### Requirement: 管理工作台
平台 SHALL 提供 `super_admin` / `ops` / `support` 角色，支持用户管理（封禁、解封、改资料、重置密码、强制下线）、跨租户设备检索、令牌吊销、实例池只读状态与审计查询。

#### Scenario: 越权访问被拒
- **WHEN** 普通用户请求 `/api/v1/admin/*`
- **THEN** 返回 403 并记录审计

### Requirement: 容器化部署
交付物 SHALL 通过 Docker Compose 一键启动 `web`、`api`、`worker`、`postgres`、`redis`、`caddy` 与共享 hbbs/hbbr 池，使用统一配置文件与启停脚本，不使用 `pkill`/`rm` 清理。

#### Scenario: 全新环境启动
- **WHEN** 在空主机执行 `deploy/scripts/start.sh`
- **THEN** 迁移自动执行，控制台可访问，健康检查全部通过

### Requirement: 套餐与商业化预留
平台 SHALL 定义 Free / Pro / Ultra 套餐字段（设备数、并发、月流量、速率）并在控制台展示当前套餐与用量；M0 只展示不强制，支付与权益下发仅保留接口占位。

#### Scenario: 查看套餐与用量
- **WHEN** 用户打开用量页面
- **THEN** 显示当前套餐、设备数/并发/月流量上限与当前值，M1 未接入的流量显示为“待接入”

## MODIFIED Requirements

### Requirement: 自定义客户端判定
`is_custom_client()` 从“APP 名称不等于 RustDesk”改为显式构建标识（编译期 `TENSORDESK_MANAGED_CLIENT` 或 Windows 许可证文件名），避免 TensorDesk 构建被误判为定制客户端而关闭自动更新。

## REMOVED Requirements

### Requirement: 每工作区独立 hbbs/hbbr 实例
**Reason**: 容器与端口成本高，运维复杂度不可接受。
**Migration**: 采用共享实例 + 协议级租户隔离；租户只存在于数据库与协议字段中。
