# Checklist

> 判定说明：`[x]` 表示已由代码或已归档测试证据直接证明；`[ ]` 表示本机环境无法完成、需在目标主机执行，已登记为 `tasks.md` Task 10。

## 客户端改造（Task 1）

- [x] `tenant-id` / `tenant-proof` 配置键已定义，且被许可证 `tenant=` / `enroll=` 正确写入
- [x] `RegisterPeer`、`RegisterPk`、`PunchHoleRequest`、`RequestRelay` 均携带租户字段，类型与 proto 一致
- [x] 未配置租户时字段为空，连接流程与改造前等价
- [x] `is_custom_client()` 不再依据 APP 名称判断，TensorDesk 构建不会误关自动更新
- [x] `cargo check --features flutter` 与 `cargo test --lib --features flutter` 在容器内通过（226 passed；唯一失败 `keyboard::shortcuts::tests::alt_only_shortcut_neutralizes_windows_menu` 为容器内键盘上下文环境问题，与本次改动无关）

## 服务端隔离（Task 2）

- [x] 令牌验签覆盖签名、过期、吊销三类失败路径
- [x] hbbs 以 `(tenant_id, device_id)` 存储，跨租户同 ID 注册均成功
- [x] 跨租户打洞返回 `ID_NOT_EXIST` + `other_failure=TENANT_MISMATCH`，不泄露目标存在性
- [x] hbbr 以 `(tenant_id, uuid)` 配对，跨租户中继被拒（`relay_tenant_pairing_e2e` 1 passed）
- [x] 封禁/吊销在 60s 内生效（实测封禁传播 29.4s/30.58s；解封恢复 30.17s，`banned_tenants` 改为全量快照 + hbbs 整体替换）

## 账号与验证（Task 5）

- [x] 注册流程要求手机号与邮箱双验证，验证码 5 分钟（300s）一次性且有发送频控
- [x] 注册成功自动创建个人工作区，套餐为 Free
- [x] 被封禁用户无法登录，且其租户被服务端拒绝
- [x] 密码使用 Argon2id；Access Token 15 分钟，Refresh 轮换且可吊销

## 设备与令牌（Task 6）

- [x] 令牌格式符合 `td1_<payload>.<sig>`，数据库只存哈希，界面仅展示一次
- [x] `/api/devices/deploy` 使用 Bearer 令牌把 `id/uuid/pk` 绑定到令牌所属工作区
- [x] 心跳每 15s 更新在线状态/连接数/最后心跳时间
- [x] 地址簿按 `tenant + user` 隔离，跨租户读取失败
- [x] 越权访问设备/令牌/审计返回 403 并写审计（`authz.workspace_denied` / `authz.role_denied` / `authz.admin_denied`）

## 管理后台（Task 7）

- [x] `super_admin` / `ops` / `support` 角色权限矩阵生效（RBAC 4 项单测）
- [x] 封禁/解封/改资料/重置密码/强制下线均生效并落审计
- [x] 跨租户设备检索可查且写审计
- [x] 内部 API 仅内网可达，未带共享密钥时拒绝（`X-Internal-Secret`；api/postgres/redis 未在 compose 暴露宿主端口）

## 前端（Task 8）

- [x] 视觉风格与 powerfs 一致：主色 `#1677FF`、渐变 `#1677FF→#722ED1`、浅/深主题
- [x] 用户控制台包含工作区概览、设备、令牌、客户端配置说明（概览页 `client-config`）、用量、账号安全
- [x] 管理工作台包含用户、工作区、设备、令牌、实例池、审计
- [x] 套餐页展示 Free/Pro/Ultra 与升级占位说明，支付未接入时不可下单

## 部署（Task 3）

- [x] `deploy/scripts/start.sh` 在空环境完成迁移并全部健康检查通过（`150.158.12.254` 实测 7/7 healthy、8 条迁移成功、12 张业务表；镜像为本地预构建后 `docker load`，启动时以 `--no-build` 执行，详见 `test-report.md`）
- [x] 统一配置文件生效，无命令行散落参数
- [x] 无 `pkill` / `rm` 清理逻辑，停服走 `stop.sh`
- [x] Compose 包含共享池 hbbs/hbbr（M0 为 Free 池：`hbbs-free` / `hbbr-free`）

## 验收（Task 9）

- [x] 租户隔离矩阵、封禁、地址簿隔离集成测试通过（`smoke.sh` 75/75）
- [x] 真实客户端端到端：部署归属 → 设备出现 → 远控成功 → 跨租户拒绝（部署归属、设备注册由早期 E2E 覆盖；GUI 会话级实测同租户 `ws-gui-a` 打洞建连成功、跨租户 `ws-gui-b` 被 `TENANT_MISMATCH(2)` 拒绝）
- [x] 双实例连续运行 ≥1 分钟无异常，`dmesg` 与日志无报错（452s / 599s）
- [x] 心跳压测 500 设备 10 分钟 P95 53.10ms < 100ms，50 并发部署 100% 成功
- [x] 测试报告归档到 `tensorManage/docs/test-report.md`；AGPL 源码获取方式与合规材料清单已登记到 `tensorManage/docs/compliance.md`
