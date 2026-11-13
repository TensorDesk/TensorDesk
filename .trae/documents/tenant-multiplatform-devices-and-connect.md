# 移动端 / Web 端设备列表与远程连接

## Context

P1.1 把桌面端门禁改成系统账号登录，原边界「仅桌面端生效；移动端、Web 端行为不变」不再成立。新需求：

1. 移动端（Android/iOS）和 Web 端只填一个 token 就能看到设备列表——token 复用现有部署码 `td1_`，走 `activateTenant()`。
2. 列表项可点击发起远程连接，走标准 RustDesk 流程（不做到免密，属 P3/P4）。
3. 桌面端与 Web 端可同时连接多个远程桌面；移动端只允许一个，已有会话时点击其它设备提示先关闭。

已确认的决策：token 用 `td1_`；Web 连接接现有 JS bridge，多会话用**新浏览器标签页**；移动端单会话用提示而非替换；连接认证走标准流程。

## 方案

### 1. 列表组件：空态入口 + 可点击

`flutter/lib/common/widgets/tenant_device_list.dart`

- 构造新增 `this.showActivation = false`（桌面端不传，行为不变）。
- `build()` 中 `tenant-proof` 为空时：`showActivation ? _buildNotActivated(context) : SizedBox.shrink()`。
  - `_buildNotActivated`：图标 + `translate('Activate TensorDesk')` + `translate('Enter the activation code from the console')` + `TextButton`，
    点击 `showActivationDialog(gFFI.dialogManager, _load)`（复用 `flutter/lib/mobile/widgets/dialog.dart` 现有入口与已有文案 key）。
- `_buildDevice` 的 `ListTile` 加 `onTap: () => openTenantDeviceSession(context, device.rustdeskId)`。

### 2. 点击设备的分平台行为（条件导入，共享代码不出现 `isWeb` 分支）

新建两个同 API 的小文件，由 `tenant_device_list.dart` 条件导入：

- `flutter/lib/models/tenant_session.dart`（原生）
  ```dart
  void openTenantDeviceSession(BuildContext context, String id) {
    if (id.isEmpty) return;
    if (isMobile && !stateGlobal.isInMainPage) {
      showToast(translate('Please close the current remote desktop first'));
      return;
    }
    connect(context, id);
  }
  ```
  复用 `connect()`（`flutter/lib/common.dart:2582`）与 `stateGlobal.isInMainPage`（`flutter/lib/models/state_model.dart:23`，
  `connect()` 置 false、`closeConnection()` 置 true，无需新增状态）。桌面端多会话由 `connect()` 既有主窗口/子窗口分流承担。
- `flutter/lib/web/tenant_session_web.dart`（Web）
  ```dart
  void openTenantDeviceSession(BuildContext context, String id) {
    if (id.isEmpty) return;
    final base = html.window.location.href.split('#').first;
    html.window.open('$base#/connect/$id', '_blank');
  }
  ```
  依据：`WebHomePage.handleUnilink`（`flutter/lib/mobile/pages/home_page.dart:180-258`）解析 `#/connect/<id>` →
  `tensordesk://connect/<id>` → `urlLinkToCmdArgs`（`common.dart:2466-2470`）→ `connect()`；每个标签一个会话，满足“Web 多会话”。

导入写法：
```dart
import '../models/tenant_session.dart'
    if (dart.library.html) '../web/tenant_session_web.dart';
```

### 3. 移动端入口

`flutter/lib/mobile/pages/device_page.dart`：`TenantDeviceList(showActivation: true)`。
tab 的注册条件（`mobile/pages/home_page.dart:55-57` 的 `bind.isCustomClient()`）保持不变——移动端仍只在托管构建出现该 tab。

### 4. Web 端入口

`flutter/lib/mobile/pages/home_page.dart` 的 `WebHomePage`：`appBar.actions` 增加一个 `IconButton`（`Icons.devices`，tooltip/文案 `translate('Devices')`），
点击 `Navigator.push` 一个 `Scaffold(appBar: AppBar(title: Text(translate('Devices'))), body: const DevicesPage())`。
不加 `isCustomClient()` 判断（Web bridge 的 `isCustomClient()` 恒为 false，见 `flutter/lib/web/bridge.dart:1721`）。

### 5. 激活对话框适配移动端

`flutter/lib/mobile/widgets/dialog.dart`：`showActivationDialog` 的 `BoxConstraints(minWidth: 500, ...)` 改为桌面 500 / 非桌面 0，避免手机溢出。

### 6. 文案

新增 1 个 key：`Please close the current remote desktop first`，追加到 `src/lang/template.rs` 与全部 `src/lang/*.rs` 末尾（`it.rs` 一律 `""`，`cn`/`tw` 给出翻译）。
其余复用已有 key：`Devices`、`No devices`、`Activate TensorDesk`、`Enter the activation code from the console`。

### 7. 文档

- `.trae/specs/p1.1-system-login/spec.md` 第 18 行边界改为「桌面端为系统账号登录；移动端/Web 端以 `td1_` 激活入口进入，同一 workspace 列表可连接」。
- `tensorManage/docs/app-design.md`：§3.1 设备列表能力补「移动端/Web 端可激活并连接」；§3.2 缺口更新；§6 增加该能力；§7 边界调整（Web 多会话=多标签、移动端单会话）；§10 追加验证记录。

## 回归面

- 桌面端：`DesktopHomePage` 的 `TenantDeviceList(compact: true, showActivation: true)` 与移动/Web 一致，不再有本机登录门禁。
- `connect()` / `closeConnection()` / `stateGlobal.isInMainPage` 写入点零改动。
- Rust 侧零改动（无新 FFI、无新 option）。
- Web bridge 零改动（只在 Web 目录新增一个使用 `dart:html` 的辅助文件）。
- 移动端非托管构建：不出现 Devices tab，行为不变。

## 验证

1. `cd flutter && flutter test test/tenant_device_list_test.dart`（新增：`showActivation: true` 时显示激活入口；桌面 `compact` 且未激活时不显示）。
2. `cd flutter && flutter test`、`flutter analyze`（新增文件 0 告警）。
3. 桌面托管 release 构建回归：`TENSORDESK_MANAGED_CLIENT=1 TENSORDESK_HIDE_SERVER_SETTINGS=1 cargo build --release --features flutter,linux-pkg-config`。
4. Web 构建需 `--dart-define=TENSORDESK_API_BASE=https://api.tensordesk.org`，且该域需允许站点 origin 的 CORS（跨端手测前提）。
5. 手测：Android/iOS 新装 → Devices tab 显示激活入口 → 填 `td1_` → 列表出现 → 点击设备进入标准连接 → 会话中再点其它设备应提示先关闭；Web → appBar Devices → 激活 → 列表 → 点击在新标签打开连接 → 再点另一台得到第二个标签；桌面回归点击列表项应开新窗口且不影响登录门禁。

## 已知限制

- Web 连接依赖不在本仓库的 `flutter/web/js` 客户端；本仓库只能保证列表、激活与连接 URL 生成正确，端到端需在含 JS 构建的环境中验证。
- Web 上激活会写 JS 侧 option，传输配置可能需要刷新页面后才完全生效（取决于 JS 实现）。
- Web 的 `mainGetPk()` 返回空串，enroll 请求的 `pk` 为空，需要服务端接受（与桌面激活的差异点，手测确认）。
- 移动端单会话依据 `stateGlobal.isInMainPage`；若出现其它把该标志置 false 的路径，会一并阻止新建会话（当前只有 `connect()` 与 `WebHomePage`）。
