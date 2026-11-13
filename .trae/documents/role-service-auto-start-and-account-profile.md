# 设备角色服务自启动与账号资料补全

## Context

当前桌面客户端在 `stop-service=Y` 时必须手动点击“启动服务”，不符合设备角色定义；账号页只有本地激活邮箱和订阅信息，缺少可靠的账号名称、工作区资料。

已确认：

- `conn-type` 已支持 `incoming` / `outgoing` / `both`，桌面设置可修改，重启生效；`outgoing` 已在 `RendezvousMediator::start_all()` 中禁止被控注册。
- 现有 `start_service(true)` 会走各平台原有的权限检查和服务安装/启用路径，应复用，不能另写 systemctl、Windows Service 或 launchctl 逻辑。
- 客户端已有使用 `tenant-proof` Bearer 调用 `/api/client/*` 的通道。
- 新激活设备可以将凭证绑定到激活表单中已校验的工作区成员；旧设备无法可靠反查该成员，因此保留本地邮箱，不用激活码创建者冒充。

已确认的产品语义：

1. 升级后首次自动恢复 `incoming` / `both` 的被控服务；之后尊重用户手动停止，跨重启保持。
2. `outgoing` 不自动开启被控服务。
3. 新激活设备以激活时填写的账号为准；旧设备继续显示本地邮箱，重新激活后获得完整账号资料。

## 实施方案

### 1. 一次性按角色恢复服务

在 `flutter/lib/common.dart` 增加桌面端一次性启动辅助函数，并在 `desktop_home_page.dart` 首页首帧后调用：

- Web、`outgoing` 直接返回，不写任何配置。
- 使用本地配置标记 `role-service-default-v1=Y` 判断是否已执行；已执行则不再干预手动停止状态。标记存放在 `LocalConfig`，不参与后台服务整表 options 同步。
- 首次执行且 `stop-service=Y` 时，调用现有 `start_service(true)`，保留 macOS 权限检查及 Windows/Linux 安装、启用系统服务的既有行为。
- 将 `start_service()` 内现有的 `mainSetBoolOption()` 调用改为 `await`，确保调用方在配置写入完成后再判断结果。
- 仅当 `stop-service` 已变为非停止状态时写入完成标记；权限拒绝或启动失败则不写标记，下次启动可重试。Linux FFI 对该键直接读取真实 `Config`，避免 UI options 缓存与安装/提权结果不一致。
- 角色从 `outgoing` 切换到 `incoming` / `both` 后，由于此前未写标记，也能执行一次自动恢复；不增加运行时角色切换状态机。

不修改安装器、`RendezvousMediator`、系统服务脚本或服务安装/停止生命周期。

### 2. 新增设备账号聚合接口

在 tensorManage 的 `backend/src/routes/client.rs` 新增 `GET /api/client/account`，并在 `backend/src/routes/mod.rs` 注册到现有 `client_authed`：

- 沿用 `require_client_auth` 和 `tenant-proof`，不复用需要用户会话的 `/me`。
- 根据 `ClientIdentity.user_id` 查询 `users.email/display_name`，根据 `workspace_id` 查询当前工作区名称。
- 复用 `workspace_quota` 和现有设备计数方式，返回当前订阅字段：`plan/plan_name/device_limit/device_count/expires_at`。
- 响应只包含当前设备工作区所需的账号、工作区和订阅资料，不返回电话、其他工作区、凭证或管理信息。
- 保留原 `/api/client/subscription`，不改其响应和调用路径。

调整同文件 `enroll()`：将已经通过工作区成员校验的 `member` 用户 ID 传给 `issue_device_credential()`，替代激活码创建者 `identity.user_id`。只影响新签发/重新激活的凭证，旧凭证不变，无需数据库迁移。

### 3. 客户端账号页填齐

在 `flutter/lib/models/tenant_devices_model.dart`：

- 新增 `TenantAccount` 模型和 `fetchTenantAccount()`，复用现有 API Base、`tenant-proof` 和 HTTP helper。
- 模型解析账号邮箱、显示名称、工作区 ID/名称及订阅字段；未激活返回 `null`，HTTP/响应错误继续抛出给页面处理。

在 `desktop_setting_page.dart` 的 `_Account`：

- 用一次账号聚合请求替代该页的订阅请求，展示 `Display Name`、`Workspace`、邮箱、套餐、到期时间和设备额度。
- 本地 `tenant-username` 始终是旧设备邮箱的优先来源；只有 API 邮箱与本地邮箱一致时，才采用 API 的显示名称，避免旧设备错误展示激活码创建者资料。
- 工作区和订阅资料直接来自 API；加载失败保留本地邮箱和已有数据，显示错误，不再把未加载状态默认伪装成 `Free`。
- 复用已有 `Display Name` 翻译键；按 `src/lang` 规则为新增 `Workspace` 键追加模板及各语言条目，`en.rs` 无需添加，`it.rs` 保持空值。

## 验证

1. **后端**
   - 运行 tensorManage 后端格式化、测试和编译检查。
   - 使用设备 `tdk_` 验证 `/api/client/account` 返回 200 及当前工作区数据；无凭证/无效凭证返回 401；跨工作区数据不可见。
   - 验证新激活凭证绑定激活表单成员，旧 `/api/client/subscription` 响应不变。
2. **Dart**
   - 在 `flutter/test/tenant_devices_test.dart` 增加完整及缺字段账号响应解析测试。
   - 运行相关 `flutter test` 和静态检查。
3. **桌面端到端**
   - `incoming`、`both`：构造 `stop-service=Y` 且无迁移标记，首次启动无需点击即上线；启动失败后标记不完成。
   - 自动恢复后手动停止，再次启动 App 应保持停止。
   - `outgoing`：启动后不注册被控、不写迁移标记、不触发权限提示。
   - 账号页验证新激活资料、旧设备本地邮箱回退、接口失败状态。
   - 在本地 Ubuntu 验证后，再在 167 服务器复测服务恢复与手动停止语义。

## 回归范围

- 修改现有运行路径仅限：桌面首页首次启动检查、`start_service()` 的异步等待、Linux Flutter FFI 的 `stop-service` 读取、设置 Account 页、以及新激活凭证的用户绑定。
- 不改动现有系统服务安装/停止实现、角色判断、Rendezvous 循环、旧设备凭证、订阅接口及其他设置页。
- 部署/发布时必须先上线管理端 API，再发布客户端；旧客户端不调用新接口，行为不变。
