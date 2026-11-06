# TensorDesk 商业化多租户管理平台设计

> 状态：方案讨论后定稿，待评审进入实现
> 代码仓库：管理平台 `https://github.com/powerfs/tensorManage.git`（独立私有）；客户端 `TensorDesk/TensorDesk`
> 日期：2026-11-06

***

## 0. 决策摘要

| 决策         | 结论                                                                                                             |
| ---------- | -------------------------------------------------------------------------------------------------------------- |
| 多租户隔离      | **共享 hbbs/hbbr 实例 + 协议级租户隔离**：不按租户起容器，同一实例内以 `(tenant_id, device_id)` 为内部键，注册/打洞/中继全链路校验租户                     |
| “用户私有 key” | **每用户接入令牌**（`td1_` 前缀的 Ed25519 签名令牌），服务器公钥全局共享                                                                 |
| 首发范围       | **M0 可运营**：注册验证、工作区/租户、接入令牌、设备绑定与在线列表、管理员封禁/修改、容器化部署；配额仅展示，不做硬限制                                               |
| 后续         | M1 中继硬计量 + 月配额 + 限速 + 套餐；M2 支付、SSO、自定义客户端构建、多地域                                                                |
| 后端/前端      | Rust + Axum + PostgreSQL + Redis；React 18 + TS + Vite + Ant Design 5 + ProComponents + ECharts，复用 powerfs 设计令牌 |
| 部署         | Docker Compose（M0）+ Helm（后续）；统一配置文件与启停脚本                                                                       |

不采用：每工作区独立 hbbs/hbbr 容器（成本与端口管理压力大）；仅账号层隔离的共享池（网络层跨租户风险不可接受）。

***

## 1. 现有能力与必须处理的问题

### 1.1 可直接复用的客户端能力

* 自定义客户端许可证 `CustomServer { key, host, api, relay }`（`src/custom_server.rs`），可写入 `key`（hbbs 公钥）、`host`、`api`、`relay`。

* `src/core_main.rs` 的 `--config` 分支会把许可证写入 `key`、`custom-rendezvous-server`、`api-server`、`relay-server`。

* `src/common.rs::get_api_server_` 优先用 `api-server`，否则从 `custom-rendezvous-server` 推导，最后回退公网 `admin.rustdesk.com`。**自定义客户端必须显式下发** **`api`。**

* `src/ui_interface.rs::deploy_device` 已实现 Bearer token → `/api/devices/deploy` → 绑定 `id/uuid/pk` 到账号，返回 `OK/NOT_ENABLED/INVALID_INPUT/ID_TAKEN`。这就是“填 key 归属到用户名下”的现成链路。

* 客户端已有的服务端 API 面：

  * `POST /api/heartbeat`（15s，上报 `id/uuid/ver/conns/modified_at`，接收 `sysinfo/disconnect/strategy/modified_at`）

  * `POST /api/sysinfo`、`GET /api/sysinfo_ver`

  * `POST /api/devices/deploy`、`POST /api/devices/cli`

  * `POST /api/currentUser`

  * `POST /api/ab/get`、`POST /api/ab`

  * `POST /api/audit/conn`、`POST /api/audit/file`、`POST /api/record`

  * `GET /api/login-options`、`POST /api/oidc/auth`、`GET /api/oidc/auth-query`

  * `POST /api/switch-grant`

### 1.2 必须修复/补齐的点

1. **改名后** **`is_custom_client()`** **全量为真**：`src/common.rs` 用 `get_app_name() != "RustDesk"` 判断，导致 TensorDesk 构建禁用自动更新、强制 `hide_cm`。必须改成显式构建标识。
2. **hbbs/hbbr 无租户概念**：设备 ID 全局唯一，跨账号可见/可尝试连接。需要服务端 fork。
3. **直连流量不可计量**：直连不经过服务器；免费套餐必须强制中继，否则月流量与限速无法执行。
4. **客户端无带宽硬上限**：`video_qos` 只有自适应码率；需要新增策略项钳制上限。
5. **AGPL-3.0**：客户端与修改后的 hbbs/hbbr 需提供源码；管理平台作为独立程序可保持私有。

***

## 2. 总体架构（共享实例 + 协议隔离）

```
                     ┌──────────────────────────────┐
                     │ Web Console (React/AntD)      │
                     │ 用户控制台 / 管理工作台        │
                     └──────────────┬───────────────┘
                                    │ HTTPS / JWT
                     ┌──────────────▼───────────────┐
                     │ TensorManage API (Axum)      │
                     │ ├ 客户端兼容 API /api/*       │
                     │ ├ 管理 API /api/v1/*          │
                     │ ├ 租户/令牌/设备/审计          │
                     │ └ 内部 API（hbbs/hbbr 回调）   │
                     └───┬──────────┬──────────┬────┘
                         │          │          │
                ┌────────▼──┐ ┌─────▼───┐ ┌────▼─────────┐
                │PostgreSQL │ │ Redis   │ │ Object Store │
                └───────────┘ └─────────┘ └──────────────┘
                         │
      ┌──────────────────▼───────────────────────────────┐
      │ 每地域两套共享池（按套餐分配）                       │
      │  Free Pool:  hbbs-free + hbbr-free  (共享)        │
      │  Paid Pool:  hbbs-paid + hbbr-paid  (共享)        │
      │  实例内以 (tenant_id, device_id) 隔离              │
      └──────────────────────────────────────────────────┘
```

* **不为每个租户创建容器**。租户只存在于数据库与协议字段中。

* 每地域按套餐分两个池（Free / Paid），避免免费用户挤占付费用户的打洞与中继资源；同一池内多租户共享。

* 后续容量不足时按地域或按池水平扩展实例；租户固定到某地域/池，由管理平台分配。

* 内网部署：hbbs/hbbr 与管理 API 同 VPC；hbbs 通过内部 API 拉取封禁/吊销状态，带本地缓存，不暴露公网管理接口。

***

## 3. 租户协议隔离设计

### 3.1 协议字段（`libs/hbb_common/protos/rendezvous.proto`）

在现有消息上新增可选字段，缺省值兼容旧客户端：

| 消息                 | 现有字段                                                                                           | 新增                                                |
| ------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `RegisterPeer`     | `string id = 1; int32 serial = 2;`                                                             | `string tenant_id = 3; bytes tenant_proof = 4;`   |
| `RegisterPk`       | `string id = 1; bytes uuid = 2; bytes pk = 3; string old_id = 4; bool no_register_device = 5;` | `string tenant_id = 6; bytes tenant_proof = 7;`   |
| `PunchHoleRequest` | `string id = 1; ... string token = 5; ... bool force_relay = 8;`                               | `string tenant_id = 12; bytes tenant_proof = 13;` |
| `RequestRelay`     | `string id = 1; string uuid = 2; ... string token = 8; ...`                                    | `string tenant_id = 12; bytes tenant_proof = 13;` |

> 字段编号以实现时 proto 当前最大编号为准，避免与上游新增字段冲突；升级时先合并上游 proto 再追加。

`tenant_proof` 是接入令牌的原始字节（含签名），hbbs/hbbr 用管理平台公钥离线验签。`tenant_id` 与 proof 中的租户必须一致，否则拒绝。

### 3.2 hbbs（fork）行为

1. **注册**（`RegisterPeer` / `RegisterPk`）

   * 验签 `tenant_proof`（Ed25519，平台公钥内置于配置）。

   * 校验 `tenant_id`、`exp`、设备数配额（M0 仅记录，不做硬限制）。

   * 内部注册键改为 `(tenant_id, id)`：不同租户可拥有相同 9 位 ID；同租户内冲突沿用现有 `ID_EXISTS` 语义。

   * 缺失 `tenant_id` 的旧客户端进入 `legacy` 租户（仅用于内测过渡，公测前要求客户端全部升级）。

   * 每 30s 从管理 API 拉取封禁/吊销列表（本地缓存）；命中则拒绝注册或断开。
2. **打洞**（`PunchHoleRequest`）

   * 校验调用方 proof 与其 `tenant_id`。

   * 目标只能按 `(tenant_id, id)` 查找；跨租户直接拒绝，返回明确错误码（新增 `TENANT_MISMATCH` / `TENANT_INVALID` 到响应枚举）。
3. **中继**（`RequestRelay`）

   * 同样校验 proof；`relay_server` 必须属于同租户所在池。

   * 将 `tenant_id` 随中继请求传递，hbbr 侧据此配对。
4. **密钥**：每个池一套 Ed25519 服务端密钥；租户不持有服务器私钥。客户端内 `key` 为池公钥。

### 3.3 hbbr（fork）行为

* 中继握手以 `(tenant_id, uuid)` 为配对键，禁止跨租户配对。

* 校验 `tenant_proof`（验签 + 过期 + 吊销）。

* 按会话记录上下行字节，为 M1 计量预留；M0 只记录不执行配额。

* 拒绝伪造/过期 proof，并记录风控事件。

### 3.4 接入令牌设计

格式：`td1_<base64url(payload)>.<base64url(signature)>`

```json
{
  "v": 1,
  "tenant": "ws_xxx",
  "user": "u_xxx",
  "scope": "enroll",
  "exp": 1790000000,
  "nonce": "random"
}
```

* 平台用 Ed25519 私钥签发；hbbs/hbbr 用公钥离线验签。

* 控制在台可签发“一次性 / 限时 / 长期”令牌；服务端存哈希用于吊销与使用次数统计。

* 设备首次 `/api/devices/deploy` 时绑定 `id/uuid/pk` 到用户；hbbs 注册时信任 proof 中的租户归属。

* 令牌泄露风险由短有效期 + 吊销列表 + 设备数上限控制；管理端可一键吊销并踢下线。

* 令牌刷新：心跳响应可下发新 proof；客户端持久化到本地配置。

### 3.5 与“每用户私有 key”的对应关系

* 用户看到的“私有 key”是 **接入令牌**（用于归属与鉴权）。

* 服务器公钥 `key` 属于池，不按用户生成；控制台展示当前池的公钥与地址，自定义客户端自动内置。

* 这样既满足“填 key 归属到用户名下”，又避免每用户一套服务端密钥带来的容器成本。

***

## 4. 客户端改造清单

> 独立小提交；先改 `hbb_common` 子模块 proto，再同步服务端 fork，最后客户端调用点。

| 文件                                        | 改动                                                                    | 阶段    |
| ----------------------------------------- | --------------------------------------------------------------------- | ----- |
| `src/common.rs`                           | `is_custom_client()` 改为显式构建标识，不再比较 APP\_NAME                          | M0    |
| `src/custom_server.rs`                    | `CustomServer` 增加 `#[serde(default)] enroll: String`、`tenant: String` | M0    |
| `libs/hbb_common/protos/rendezvous.proto` | 四个消息增加 `tenant_id` / `tenant_proof`                                   | M0    |
| `src/rendezvous_mediator.rs`              | 注册/打洞/中继填充租户字段；解析新增拒绝原因                                               | M0    |
| `libs/base/src/config/keys.rs`            | 新增 `tenant-id`、`tenant-proof`（M1 再加 `force-relay`、`max-bitrate-kbps`） | M0/M1 |
| `src/ui_interface.rs`                     | `deploy_device` 支持从许可证预填接入令牌；持久化 tenant 配置                            | M0    |
| `src/hbbs_http/sync.rs`                   | 心跳携带租户状态；解析 `quota`/`entitlement`（M0 忽略未启用字段）                         | M0/M1 |
| `src/server/video_qos.rs`                 | 钳制 `max-bitrate-kbps` 上限                                              | M1    |
| 连接路径                                      | `force-relay=Y` 时跳过打洞直接中继                                             | M1    |

兼容策略：服务端同时接受“无 tenant 的旧客户端”（归入 legacy 租户）和“带 proof 的新客户端”；公测前通过自定义客户端分发确保全部新客户端。

***

## 5. M0 功能范围（可运营）

### 5.1 用户控制台

* 注册/登录：手机号 + 邮箱验证（短信/邮件适配器）；图形验证码；频控。

* 工作区：自动创建个人租户；显示当前池的 `host/key/api/relay`。

* 设备：通过接入令牌部署后自动出现；列表展示 ID、名称、系统、版本、在线状态、最后心跳；支持重命名/分组/删除。

* 接入令牌：生成（一次性/限时/长期）、吊销、使用记录。

* 客户端下载：按工作区生成配置（M0 先提供“配置说明 + 标准客户端”，自定义安装包在 M2）。

* 账号安全：修改密码、2FA（可选）、登录设备记录。

* 用量：先展示心跳上报的连接数与会话时长；流量数值 M1 接入。

### 5.2 管理工作台

* 角色：`super_admin`、`ops`、`support`、`finance`（M0 先 super\_admin/ops/support）。

* 用户管理：列表、搜索、封禁/解封（原因、期限）、修改资料、重置密码、强制下线。

* 工作区/租户：查看所属池、设备数、状态；手工调整套餐标记。

* 设备：跨租户检索（写审计）、踢下线、解绑。

* 令牌：查看/吊销。

* 实例池：Free/Paid 池的健康状态、在线设备数、连接数（只读）。

* 审计：登录、封禁、令牌、管理写操作。

### 5.3 M0 明确不做

* 流量硬配额、限速、套餐计费（M1）。

* 支付、发票、退款（M2）。

* 自定义客户端构建与签名更新通道（M2）。

* SSO/OIDC、多地域调度（M2）。

* 每租户独立实例（已明确不采用）。

***

## 6. API 契约

### 6.1 客户端兼容 API（M0 必做）

| 方法   | 路径                                  | 说明                                   |
| ---- | ----------------------------------- | ------------------------------------ |
| POST | `/api/heartbeat`                    | 在线状态、连接数、策略；响应预留 `quota/entitlement` |
| POST | `/api/sysinfo`                      | 系统信息入库                               |
| GET  | `/api/sysinfo_ver`                  | 版本比对                                 |
| POST | `/api/devices/deploy`               | Bearer 接入令牌绑定设备                      |
| POST | `/api/currentUser`                  | 当前账号                                 |
| POST | `/api/ab/get`、`/api/ab`             | 地址簿按 `tenant + user` 命名空间            |
| POST | `/api/audit/conn`、`/api/audit/file` | 审计（M0 可只入库）                          |

错误格式保持客户端判断：`{"result":"OK|NOT_ENABLED|INVALID_INPUT|ID_TAKEN"}`，其他错误 `{"error":"..."}`。

### 6.2 管理 API（`/api/v1`）

```
POST /auth/register | login | refresh | logout
POST /auth/verify/phone/send | verify
POST /auth/verify/email/send | verify
POST /auth/password/reset
GET  /me
GET  /workspaces
GET  /workspaces/{id}/devices
POST /workspaces/{id}/devices/{device}/rename | groups | unbind
GET  /workspaces/{id}/enroll-tokens
POST /workspaces/{id}/enroll-tokens
DELETE /workspaces/{id}/enroll-tokens/{id}
GET  /admin/users
PATCH /admin/users/{id}          # 封禁/解封/改资料/重置密码/强制下线
GET  /admin/workspaces
GET  /admin/instances
GET  /admin/audit-logs
```

### 6.3 内部 API（仅内网，hbbs/hbbr 调用）

```
GET  /internal/tenants/{id}/status     # 封禁、配额、池归属（30s 缓存）
GET  /internal/revocations?since=...   # 令牌/设备吊销增量
GET  /internal/enroll/verify?token=... # 可选在线二次校验
```

M0 内网接口用 mTLS 或固定内网 IP + 共享密钥保护，不暴露公网。

***

## 7. 数据模型（M0）

| 表                    | 关键字段                                                                                                                          |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `users`              | id, email, phone\_enc, password\_hash(argon2id), status(active/banned/unverified), role, locale, created\_at, last\_login\_at |
| `user_verifications` | user\_id, type(phone/email), target\_hash, code\_hash, expires\_at, consumed\_at                                              |
| `workspaces`         | id(tenant\_id), owner\_user\_id, name, pool(free/paid), plan\_code(free/pro/ultra), region, status                            |
| `memberships`        | workspace\_id, user\_id, role(owner/admin/member)                                                                             |
| `server_pools`       | id, region, tier(free/paid), hbbs\_addr, hbbs\_pubkey, hbbr\_addr, api\_base, status, health\_at                              |
| `devices`            | id, workspace\_id, rustdesk\_id, uuid, pk, name, os, version, group\_id, online, last\_heartbeat\_at, bound\_by\_token\_id    |
| `device_groups`      | id, workspace\_id, name                                                                                                       |
| `enroll_tokens`      | id, workspace\_id, token\_hash, payload\_json, scope, expires\_at, max\_uses, used\_count, revoked\_at, created\_by           |
| `audit_logs`         | id, actor, action, target\_type, target\_id, ip, ua, detail\_json, created\_at（只追加）                                           |
| `notifications`      | id, user\_id, type, payload\_json, read\_at                                                                                   |

约束与索引：

* `devices (workspace_id, rustdesk_id)` 唯一；`devices (uuid)` 唯一。

* `enroll_tokens (token_hash)` 唯一。

* 所有用户侧查询强制带 `workspace_id`；启用 PostgreSQL RLS 兜底。

* 手机号/邮箱加密存储；日志脱敏。

***

## 8. M0 部署方案

### 8.1 组件

`web`、`api`、`worker`、`postgres`、`redis`、`caddy`、`hbbs-free`、`hbbr-free`、`hbbs-paid`、`hbbr-paid`（后四个为共享池，M0 可先只起 free 池）。

### 8.2 配置与脚本

* 统一配置：`deploy/config/tensormanage.toml`（数据库、Redis、JWT、池地址与公钥、短信/邮件、内部 API 密钥、端口区间）。

* 启停：`deploy/scripts/start.sh`、`stop.sh`、`migrate.sh`；不使用 `pkill`、`rm` 清理。

* 反向代理：Caddy 终止 TLS，暴露 `https://console.<domain>` 与 `https://api.<domain>`；hbbs/hbbr 端口按池固定。

* 客户端配置：自定义客户端/控制台下发 `host`、`key`（池公钥）、`api`、`relay`。

* 备份：PostgreSQL 每日全量 + WAL 归档；恢复演练纳入验收。

### 8.3 环境

* M0 复用现有腾讯云 `150.158.12.254` 作为 staging/prod 起点；hbbs/hbbr 改为容器由 Compose 管理，逐步替换现有 systemd 实例。

* 生产扩容：增加地域/池；租户按 region+pool 固定，不做自动迁移。

***

## 9. M0 测试与验收

### 9.1 功能验收

1. 注册 → 手机/邮箱验证 → 创建工作区 → 签发接入令牌。
2. 客户端填令牌 → `/api/devices/deploy` → 设备出现在控制台 → 心跳在线。
3. 管理员封禁用户 → 60s 内 hbbs 拒绝该租户注册/连接，控制台显示原因。
4. A 租户知道 B 租户设备 ID 时，打洞/中继均被拒绝；A 无法读取 B 地址簿。
5. 不同租户可使用相同 9 位设备 ID，互不冲突。
6. 管理端改资料/重置密码/强制下线生效并留审计。

### 9.2 测试层次

* 单元：令牌签发/验签/过期/吊销；RBAC；密码哈希；心跳序列化。

* 集成（Compose）：租户隔离矩阵、封禁生效、地址簿隔离、令牌使用次数。

* 端到端（真实客户端 + 共享 hbbs/hbbr）：部署归属、远控、跨租户拒绝、双实例连续运行 ≥ 1 分钟并检查日志。

* 压测（M0 最低要求）：500 设备心跳持续 10 分钟，P95 < 100ms；50 并发会话注册/打洞无错误。

### 9.3 代码验证命令（客户端）

容器 `rustdesk-builder-bullseye` 内：

```bash
cargo check --features flutter
cargo test --lib --features flutter
```

服务端 fork 与 tensorManage 各自 CI。

***

## 10. M1 / M2 规划

### 10.1 M1 可收费

* hbbr 计量：按 `(tenant, device, session)` 统计上下行字节，Redis Stream → `usage_records`（月分区）→ `usage_monthly`。

* 免费套餐强制中继：客户端新增 `force-relay`，策略由心跳下发；Paid 池允许 P2P。

* 限速：客户端 `max-bitrate-kbps` 硬上限 + 网关每会话令牌桶。

* 套餐：Free / Pro / Ultra，含设备数、并发、月流量、速率、审计保留、自定义客户端权限。

* 配额耗尽拒绝新中继会话，已建立会话自然结束；80%/100% 通知。

* 手工开通与管理员配额覆盖。

### 10.2 M2 商业化完善

* 支付宝/微信：订单状态机、回调验签、幂等、退款、对账；资质未到前保留手工开通。

* 权益签名下发，客户端离线校验。

* 自定义客户端构建：按工作区注入品牌与服务器配置，Windows/macOS/Linux 签名安装包。

* 自有更新通道（替代已禁用的上游自动更新）。

* SSO/OIDC、多地域、审计报表、SLA。

***

## 11. 安全与合规

### 11.1 平台安全

* Argon2id 密码；登录限流/锁定；验证码 5 分钟一次性；可选 TOTP 2FA。

* Access Token 15 分钟 + Refresh 轮换（Redis 吊销列表）。

* 管理端强制 2FA；所有管理写操作审计；审计表只追加。

* 租户隔离中间件：服务端从会话解析 `user/workspace`，不信任前端传入的 `workspace_id`。

* IDOR 回归测试覆盖设备、令牌、地址簿、审计。

* 敏感字段加密；日志脱敏；内部接口 mTLS/共享密钥。

* PII：提供注销、数据导出；明确留存周期。

### 11.2 服务端与分发

* 池私钥加密存储（KMS/age），仅注入 hbbs/hbbr 挂载卷；控制台只展示公钥。

* 接入令牌只存哈希及必要明文 payload；展示一次。

* Windows Authenticode、macOS Developer ID + 公证、Linux 包签名（M2）。

* 更新清单签名校验，禁止降级。

### 11.3 合规

* 境内：ICP 备案、等保 2.0（建议二级起）、PIPL/数据安全法/网络安全法、隐私政策与用户协议、手机号实名。

* AGPL-3.0：TensorDesk 客户端与修改后的 hbbs/hbbr 提供源码获取方式；管理平台保持独立程序。

* 不使用 RustDesk 名称/Logo/域名。

***

## 12. 风险与待办

### 12.1 风险

1. **协议升级窗口**：`hbb_common` 是客户端与服务端共享子模块，proto 变更必须客户端、hbbs、hbbr 同版本配套；旧客户端归入 `legacy` 租户，公测前必须完成全量升级。
2. **hbbs/hbbr fork 维护成本**：需跟随上游 proto 与安全修复；建立固定同步节奏与回归脚本。
3. **ID 冲突语义变化**：租户内唯一、跨租户可重复；控制台展示与客服排查需按“租户+ID”定位。
4. **令牌泄露**：短有效期 + 吊销列表 + 设备上限；M1 增加绑定设备指纹。
5. **免费池噪声**：Free/Paid 分池；M1 再引入网关限速与配额。
6. **短信/邮箱成本与滥用**：图形验证码、频控、域名黑名单、短信风控。
7. **AGPL 义务**：修改后的 hbbs/hbbr 作为网络服务需提供源码；上线前准备源码与说明。
8. **改名缺陷未修前不可公测**：`is_custom_client` 误判会关闭自动更新，必须在 M0 首批修复。

### 12.2 已定与待确认

* [x] M0 先上单 Free 池（`docker-compose.yml` 仅含 `hbbs-free`/`hbbr-free`）；Free/Paid 双池在 M1 随计量与限速一起上线。

* [ ] M1 免费套餐默认额度：3 设备 / 1 并发 / 20GB / 2Mbps 是否接受？（当前代码只展示上限，不做硬限制）

* [ ] 短信服务商（阿里云/腾讯云）与发送配额；当前未配置供应商时验证码写入日志（仅开发/内测可用）。

* [ ] 自定义客户端签名证书采购时间（Windows EV、Apple Developer）。

* [ ] 是否需要企业 SSO 提前到 M1（当前排在 M2）。

***

## 13. 交付物

1. `powerfs/tensorManage`：后端、前端、Compose/Helm、迁移、部署与运营文档。
2. `powerfs/tensor-server`（或 tensorManage 内 `server/`）：hbbs/hbbr 的租户化 fork，AGPL 源码可获取。
3. TensorDesk 客户端 M0 改动：proto、租户配置、令牌部署、`is_custom_client` 修复，附回归测试。
4. 测试报告：租户隔离矩阵、封禁、跨租户拒绝、心跳压测。
5. 合规材料清单。

