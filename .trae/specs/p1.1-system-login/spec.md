# P1.1 系统账号登录 — 实施规格

状态：**已取消（2026-11-10）**
前置：P1（`tdk_` 落地、bootstrap 刷新、401 回退）已实现并验证；P2 设备列表已完成。
设计依据：`/home/portion/tensorManage/docs/app-design.md` §4.1、§5.1.1、§6、§7。

> 取消原因：本机系统账号只适合做设备本地的 UI 门禁，而产品要求是「填 token 即可看到设备列表，点设备连接时才需要密码，且密码由远端校验」。因此本机 PAM/`LogonUserW` 登录、`TenantDeviceGate`、相关 FFI/bridge、`res/pam.d/tensordesk` 与 `tenant-enroll-token` 键均已移除；连接复用 RustDesk 原生远端密码框。下文保留为历史设计记录。

## 1. 目标与边界

托管桌面客户端在**打开设备列表**时才要求用本机系统账号密码登录（启动、显示本机 ID/密码、被远程控制都不要求）：

1. 密码只在本机校验（Linux/macOS PAM，Windows `LogonUserW`），不上传、不落盘、不进日志。
2. 登录成功后只解锁本次运行内的设备列表；关闭 app 后失效。
3. 登录只做身份校验，不决定凭证：列表区在没有 `tenant-proof` 时显示 `td1_` 激活入口。
4. 被控端（本机暴露服务）通过 `td1_` 激活（设置页「Activate TensorDesk」或列表入口），不需要系统登录。

边界（明确不做）：

- 启动不拦截；被控端未激活也能看到本机 ID。
- 桌面端为系统账号登录；移动端 / Web 端以 `td1_` 激活入口进入，可查看并连接同一 workspace 的设备（见后续「多端设备列表与连接」变更）。
- 只做本地 UI 门禁：不改变服务进程、hbbs 注册、远端连接、bootstrap 周期刷新。
- 不做系统会话监控（注销/切换用户自动回登录页）；由 OS 锁屏承担，写入设计文档「已知限制」。
- 登录状态不持久化；不做「记住登录」。
- 不新增 `os-user` 持久化；`os_user` 上报属于 P3，届时用 `current_username()` 取值。
- 不建控制面登录会话，控制面仍只认 `tdk_`。

## 2. Rust 侧改动

### 2.1 依赖

`Cargo.toml` 新增：

```toml
[target.'cfg(any(target_os = "linux", target_os = "macos"))'.dependencies]
pam = "0.8"
```

Windows 复用已有 `windows = "0.61"`（`Win32_Foundation`、`Win32_Security` 已启用）。
实施时确认 `pam-sys` 的 `build.rs` 同时支持 Linux/macOS；若不支持 macOS，则 macOS 分支改用
`libloading` 运行时 `dlopen` 调用 `pam_start`/`pam_authenticate`，接口保持不变，并在 PR 说明原因。

### 2.2 新文件 `src/system_auth.rs`

公开接口：

- `pub fn current_username() -> String` — 直接复用 `crate::common::username()`（`src/common.rs:926`）。
- `pub fn verify(username: &str, password: &str) -> bool`
  - `trim()` 用户名；用户名或密码为空 → `false`。
  - 不区分「账号不存在 / 密码错误」，统一返回 `false`（防枚举）。
  - 秘钥材料只用局部变量，不 `log`、不写入任何结构体字段。

平台实现：

| 平台 | 实现 |
|---|---|
| Linux/macOS | `pam_verify`：依次尝试服务名 `tensordesk`（`/etc/pam.d/tensordesk` 存在才试）、`login`；`Authenticator::with_password(service)` + `set_credentials(user, password)` + `authenticate()`；任一成功即 `true` |
| Windows | `win_verify`：`split_account` 拆分 `DOMAIN\user` / `user@domain`（UPN 原样作用户名、域传 `.`），`LogonUserW(LOGON32_LOGON_NETWORK, LOGON32_PROVIDER_DEFAULT)`；成功后 `CloseHandle`；失败 `false` |
| 其它（Android/iOS） | `false` |

模块内 `#[cfg(test)]`：

- `split_account`：`DOMAIN\user` → `("user","DOMAIN")`；`user@domain` → 原样 + `.`；`user` → `("user",".")`。
- `verify("", "x") == false`、`verify("user", "") == false`。

### 2.3 选项常量

`libs/base/src/config/keys.rs` 在 `OPTION_TENANT_PROOF`（L80）后新增：

```rust
pub const OPTION_TENANT_ENROLL_TOKEN: &str = "tenant-enroll-token";
```

### 2.4 FFI（`src/flutter_ffi.rs`，放在 `main_peer_has_password`（L1494）附近）

```rust
pub fn main_verify_system_credentials(username: String, password: String) -> bool {
    crate::system_auth::verify(&username, &password)
}

pub fn main_get_system_username() -> String {
    crate::system_auth::current_username()
}
```

不加 `cfg`，保证所有目标生成的 bridge 都包含这两个方法（移动端实现返回 `false`/用户名）。
`src/lib.rs` 增加 `mod system_auth;`。

### 2.5 生成代码（不入库，本地手改以便测试）

按 `main_peer_has_password` 的模式手工补齐：

- `src/bridge_generated.rs`：两个 `wire_main_*` 函数（`port_` + `FLUTTER_RUST_BRIDGE_HANDLER.wrap` + `Wire2Api`）。
- `src/bridge_generated.io.rs`：两个 `wire_main_*` 薄封装。
- `flutter/lib/generated_bridge.dart`：抽象声明、实现类、内部 FFI 三处（`Future<bool>` / `Future<String>`）。

### 2.6 PAM 服务文件与打包

新增 `res/pam.d/tensordesk`：

```
auth      required   pam_unix.so
account   required   pam_unix.so
```

- 安装到 `/etc/pam.d/tensordesk`（deb/AppImage 打包脚本按现有 `res/` 安装模式落地）。
- `.github/workflows/flutter-build.yml`：在构建 Linux 客户端的 job 的 apt 依赖里加 `libpam0g-dev`。
- 目标机缺该文件时自动回退 `login` 服务，不阻塞功能。

## 3. Flutter 侧改动

### 3.1 新文件 `flutter/lib/desktop/pages/tenant_login_page.dart`

**`TenantDeviceGate extends StatefulWidget`**（桌面设备列表入口）

- 构造：`const TenantDeviceGate({this.compact = true})`。
- `build`：
  - `!bind.isCustomClient()` → 直接 `TenantDeviceList(compact: ...)`，非托管构建行为不变。
  - 本次运行已解锁 → `TenantDeviceList(compact: ..., showActivation: true)`。
  - 未解锁 → 锁图标 + 「Login」，点击 push `TenantLoginPage`。
- 解锁状态只在该 State 中，关闭 app 后失效；启动、本机 ID/密码展示、被远程控制都不经过门禁。

**`TenantLoginPage extends StatefulWidget`**

- 可注入依赖以便测试：
  - `Future<bool> Function(String username, String password)? verify`
  - `Future<String> Function()? loadUsername`
  - `VoidCallback onUnlocked`
- `initState`：`loadUsername`（默认 `bind.mainGetSystemUsername()`）填入用户名输入框。
- UI：AppBar（可返回）、系统账号登录提示、用户名字段、密码字段（`obscureText`）、登录按钮与 loading 态、错误文案。
- 提交逻辑：
  1. 空用户名/密码 → 错误文案，不调用 FFI。
  2. `verified = await verify(u, p)`；无论结果，**立即清空密码控件**（`passwordController.clear()`）。
  3. `false` → 统一错误「用户名或密码错误」。
  4. `true` → `onUnlocked()`。凭证读取与激活不在登录页处理。

### 3.2 接入门禁（`flutter/lib/desktop/pages/desktop_home_page.dart` 的 `buildDeviceList`）

```dart
child: const TenantDeviceGate(),
```

启动入口（`flutter/lib/main.dart`）仍为 `DesktopTabPage()`，不做启动门禁。

### 3.3 Web bridge（`flutter/lib/web/bridge.dart`，L1721 `isCustomClient` 附近）

```dart
Future<bool> mainVerifySystemCredentials(
        {required String username, required String password, dynamic hint}) async =>
    false;

Future<String> mainGetSystemUsername({dynamic hint}) async => '';
```

### 3.4 文案（`src/lang/*.rs`）

优先复用已有 key（`Username`、`Password`、`Login`、`Cancel` 等，实施时 grep 确认）。
仅新增缺失 key，按 AGENTS 规则**追加到 `template.rs` 与所有 `src/lang/*.rs` 末尾**，`it.rs` 一律 `""`，
`cn/tw` 给出翻译，`en.rs` 仅在展示文案与 key 不同时添加：

- `Sign in`
- `Incorrect username or password`
- `This device is not provisioned. Please contact your administrator.`
- `Use an activation code`

## 4. 测试与验证

| # | 项 | 命令/方式 | 通过标准 |
|---|---|---|---|
| 1 | Rust 单测 | `cargo test --lib system_auth` | 新增用例全过 |
| 2 | 发布构建 | `TENSORDESK_MANAGED_CLIENT=1 TENSORDESK_HIDE_SERVER_SETTINGS=1 cargo build --release --features flutter,linux-pkg-config` | 构建成功 |
| 3 | 静态分析 | `flutter analyze`（改动/新增文件） | 无新增告警 |
| 4 | Dart 单测 | `flutter test` | 原有 145 passed / 1 skipped + 新增用例通过 |
| 5 | 新增 widget 测试 | `flutter/test/tenant_login_page_test.dart` | 见 §4.1 |
| 6 | 密码不外泄 | `grep` 全仓 `password` 日志点 + 运行时日志抽查 | 无密码出现在日志/选项/网络请求 |
| 7 | 真机手测（Linux） | 托管构建启动 | 启动直接进首页并显示本机 ID；点击设备列表区的登录入口并输入本机账号密码后才显示列表；无 proof 时列表区显示 `td1_` 激活入口 |

### 4.1 widget 测试用例（注入回调，不依赖真实 PAM）

1. `verify=false` → 显示统一错误，密码字段已清空。
2. `verify=true` → `onUnlocked` 被调用。
3. 空密码 → 不调用 `verify`。
4. 托管构建未解锁 → 只显示登录入口、不构建设备列表；非托管构建 → 直接显示设备列表。

## 5. 回归面（必须逐项确认未被改动）

- `src/server/*`、`src/service.rs`、`src/rendezvous_mediator.rs`、`src/tenant_bootstrap.rs`：**零改动**。
- 移动端 `flutter/lib/mobile/**`：仅 `dialog.dart` 宽度与设备页激活入口，无门禁。
- Web：`flutter/lib/web/bridge.dart` 仅加两个 no-op 方法。
- `desktop_home_page.dart`：仅 `buildDeviceList` 换成 `TenantDeviceGate`。
- `main.dart`：`home` 为 `DesktopTabPage()`，没有启动门禁。
- 现有 `activateTenant` / `setServerConfig` 逻辑：零改动，仅被设置页与设备列表入口调用。

## 6. 文档与收尾

- `tensorManage/docs/app-design.md`：§3.1/§3.2、§4.1、§5.1.1 去掉「待实现」，§6 P1.1 标为已实现，
  §7 增补「不做系统会话监控，依赖 OS 锁屏」，新增 §10 P1.1 验证记录。
- 提交：rustdesk 一次提交；tensorManage 文档一次提交；两仓均推送。
- 关闭 GitHub issue `TensorDesk#8`，附验证结论。

## 7. 已知限制（写入 PR/文档，不在本阶段修）

- 登录状态只在本次运行内有效，关闭 app 后重新登录；不做系统会话监控。
- 密码在 Dart 字符串中无法安全清零（只能 `clear()` 控件），仅保证不使用、不传输、不落盘。
- 用户名为空或含未知格式时按失败处理；Linux/macOS 非 root 只能校验当前登录用户。
