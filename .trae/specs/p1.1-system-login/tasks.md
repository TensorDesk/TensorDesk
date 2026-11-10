# P1.1 系统账号登录 — 任务清单

**已取消（2026-11-10）**：产品改为「token 只看列表，连接用 RustDesk 原生远端密码框」，本机账号登录整体移除。
已完成的任务保留勾选作为历史记录；新增的移除任务见下方「取消清理」。

规格：[spec.md](./spec.md)

实现偏差（已记录）：`pam` crate 依赖 bindgen + libpam 头文件，本地与 CI 都会引入额外构建依赖，
不足以支撑“可复现构建”，因此改为 `libloading` 运行时 `dlopen("libpam.so.0")`，接口不变；
对应地不再需要 `libpam0g-dev`（D3 取消）。

## 取消清理

- [x] G1 删除 `tenant_login_page.dart` / `tenant_login_page_test.dart`、`src/system_auth.rs`
- [x] G2 删除 FFI `main_verify_system_credentials` / `main_get_system_username` 及 bridge 三处、web no-op
- [x] G3 删除 `Cargo.toml` 的 `libc`/`libloading` 目标依赖、`OPTION_TENANT_ENROLL_TOKEN`
- [x] G4 删除 `res/pam.d/tensordesk` 与 `build.py` 打包行
- [x] G5 桌面设备列表改为 `TenantDeviceList(compact: true, showActivation: true)`
- [x] G6 移除登录相关 lang key（54 个文件）

## 阶段 A：Rust 本机校验

- [x] A1 `Cargo.toml`：linux/macos 增加 `libc` + `libloading`（替代 `pam`）
- [x] A2 新增 `src/system_auth.rs`：`current_username()` / `verify()` / `pam_verify` / `win_verify` / `split_account` + `#[cfg(test)]`
- [x] A3 `src/lib.rs`：`mod system_auth;`
- [x] A4 `libs/base/src/config/keys.rs`：新增 `OPTION_TENANT_ENROLL_TOKEN`
- [x] A5 `src/flutter_ffi.rs`：`main_verify_system_credentials` / `main_get_system_username`
- [x] A6 `cargo test --lib system_auth` 通过（Linux）：2 passed

## 阶段 B：bridge 打通

- [x] B1 本地手改 `src/bridge_generated.rs`、`src/bridge_generated.io.rs`（不入库）
- [x] B2 本地手改 `flutter/lib/generated_bridge.dart`（不入库）
- [x] B3 `flutter/lib/web/bridge.dart` 加两个 no-op 方法（入库）

## 阶段 C：登录页与门禁

- [x] C1 新增 `flutter/lib/desktop/pages/tenant_login_page.dart`（`TenantLoginGate` + `TenantLoginPage`，依赖可注入）
- [x] C2 `flutter/lib/main.dart`：desktop home 改为 `TenantLoginGate(child: DesktopTabPage())`
- [x] C3 `src/lang/*.rs` + `template.rs`：补齐缺失 key（`it.rs` 全 `""`）

## 阶段 D：打包

- [x] D1 新增 `res/pam.d/tensordesk`
- [x] D2 `build.py` 的 flutter deb 打包安装到 `/etc/pam.d/tensordesk`
- [x] D3 取消：改用 `dlopen` 后无需 `libpam0g-dev` 构建依赖

## 阶段 E：验证

- [x] E1 新增 `flutter/test/tenant_login_page_test.dart`（5 条用例通过）
- [x] E2 `flutter analyze`（改动/新增文件无新增告警）
- [x] E3 `flutter test` 全量通过：150 passed / 1 skipped
- [x] E4 `cargo build --release --features flutter,linux-pkg-config`（托管 env）成功：6m32s，EXIT=0
- [x] E5 日志/选项/网络抽查：无密码泄漏（`system_auth.rs` 无日志调用，密码仅在 `CString`/PAM 响应中；登录页无 print）
- [ ] E6 Linux 真机手测：有 proof / 无 proof+令牌 / 无 proof 无令牌 三种路径（需图形会话，待用户点验）

## 阶段 F：文档与收尾

- [x] F1 更新 `tensorManage/docs/app-design.md`（§3.1/§3.2/§4.1/§5.1.1/§6/§7 + §10 验证记录）
- [x] F2 提交并推送 rustdesk（`6c0663265`）、tensorManage（`91a4b59`）
- [ ] F3 关闭 `TensorDesk#8`，回填验证结论（已回填 [comment](https://github.com/TensorDesk/TensorDesk/issues/8#issuecomment-6757772946)；因 E6 真机手测待确认，issue 暂不关闭）
