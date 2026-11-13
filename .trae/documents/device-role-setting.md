# 设备角色三档设置（桌面端）

## Context

TensorDesk 客户端目前只有安装期决定的本机角色：安装目录 `custom.txt` 顶层键 `conn-type` 被读入
`HARD_SETTINGS`，`is_incoming_only()` / `is_outgoing_only()` 只读这一处
（[config.rs#L2869-L2885](file:///home/portion/rustdesk/libs/hbb_common/src/config.rs#L2869-L2885)）。

“仅主控 / 仅被控”的行为其实已经实现并被 Flutter UI 全面适配：

- 仅被控：`client.rs` 主动连接直接 `bail!("Incoming only mode")`，但保留 switch-sides 回连
  （[client.rs#L434-L436](file:///home/portion/rustdesk/src/client.rs#L434-L436)）
- 仅主控：`start_all()` 直接进入空循环，不注册 peer、不启动直连/局域网监听
  （[rendezvous_mediator.rs#L274-L280](file:///home/portion/rustdesk/src/rendezvous_mediator.rs#L274-L280)）
- UI：首页隐藏连入面板或隐藏本机 ID/密码区，设置页隐藏对应 tab
  （[desktop_home_page.dart#L60-L96](file:///home/portion/rustdesk/flutter/lib/desktop/pages/desktop_home_page.dart#L60-L96)、
  [desktop_setting_page.dart#L66-L84](file:///home/portion/rustdesk/flutter/lib/desktop/pages/desktop_setting_page.dart#L66-L84)）

缺的只有两件事：本机设置里没有入口；`conn-type` 被当成不可变硬设置，无法用用户选项覆盖。

**目标**：桌面端设置里提供「双向 / 仅被控 / 仅主控」三档单选；安装包 `custom.txt` 仍是默认值；
用户选择写入普通配置项并覆盖默认；改动后重启生效。

## 已确认的取舍

| 项 | 决定 |
| --- | --- |
| 生效方式 | 保存后提示重启，不改造 `start_all()` / 监听生命周期 |
| 默认值来源 | 只用 `custom.txt` 顶层 `conn-type`；不扩展签名授权串 |
| 覆盖端 | 仅桌面（Win/macOS/Linux）；移动端与 Web 不动 |

## 改动一：角色解析下沉到 `base`（新增逻辑唯一落点）

`libs/base` 是客户端专用 crate，且已依赖 `hbb_common`；`hbb_common` 是与服务端共享的子模块，
按 AGENTS.md 不在此改。

文件：[libs/base/src/config/mod.rs](file:///home/portion/rustdesk/libs/base/src/config/mod.rs)

```rust
use hbb_common::config::{Config, HARD_SETTINGS};

fn resolve_conn_type(user: &str, hard: &str) -> String {
    if user.is_empty() { hard.to_owned() } else { user.to_owned() }
}

pub fn conn_type() -> String {
    let user = Config::get_option("conn-type");
    let hard = HARD_SETTINGS.read().unwrap().get("conn-type").cloned().unwrap_or_default();
    resolve_conn_type(&user, &hard)
}

pub fn is_incoming_only() -> bool { conn_type() == "incoming" }
pub fn is_outgoing_only() -> bool { conn_type() == "outgoing" }
```

要点：

- `Config::get_option` 的优先级已是 `override-settings > 用户配置 > 默认值`，所以安装包若把
  `conn-type` 放进 `override-settings` 仍然自动锁定（`is_option_fixed` + 不可保存）。
- 用户未设置时返回 `""` → 回落到 `HARD_SETTINGS`，行为与现在完全一致。
- 用户显式选“双向”时存字符串 `"both"`（非空即覆盖），否则无法覆盖 `incoming`/`outgoing` 的安装默认。
- 新增 `#[cfg(test)]` 测试只测纯函数 `resolve_conn_type`：user 空 → hard；user 非空 → user；
  两者皆空 → 空串。

## 改动二：现有角色判断改用 base 版本

仅替换函数路径，不改逻辑。调用点（共 9 处）：

| 文件 | 行 |
| --- | --- |
| [src/client.rs](file:///home/portion/rustdesk/src/client.rs#L434) | 434、4697 |
| [src/rendezvous_mediator.rs](file:///home/portion/rustdesk/src/rendezvous_mediator.rs#L276) | 276 |
| [src/core_main.rs](file:///home/portion/rustdesk/src/core_main.rs#L639) | 639 |
| [src/flutter_ffi.rs](file:///home/portion/rustdesk/src/flutter_ffi.rs#L2576-L2581) | 2577、2581 |
| [src/ui.rs](file:///home/portion/rustdesk/src/ui.rs#L291-L297) | 292、296（legacy Sciter） |
| [src/platform/windows.rs](file:///home/portion/rustdesk/src/platform/windows.rs#L1743) | 1743、4056、4075 |

写法：`base::config::is_incoming_only()` / `base::config::is_outgoing_only()` 全限定调用，
不新增 import 块，保持逐行最小替换。

## 改动三：桌面设置项（Flutter）

文件：[flutter/lib/desktop/pages/desktop_setting_page.dart](file:///home/portion/rustdesk/flutter/lib/desktop/pages/desktop_setting_page.dart)

- 在 `_GeneralState` 增加 `bool _roleChanged = false;`
- 在 `_General.build` 的 `theme()` 之后插入 `deviceRole()`
- 复用现有 `_Card` + `_Radio<String>`（与 `theme()` 完全同构，[L469-L494](file:///home/portion/rustdesk/flutter/lib/desktop/pages/desktop_setting_page.dart#L469-L494)）

```dart
String _currentRole() {
  final v = bind.mainGetOption(key: 'conn-type');
  if (v.isNotEmpty) return v;
  final h = bind.mainGetHardOption(key: 'conn-type');
  return h.isEmpty ? 'both' : h;
}

Widget deviceRole() {
  final current = _currentRole();
  final fixed = isOptionFixed('conn-type');
  void onChanged(String value) async {
    await bind.mainSetOption(key: 'conn-type', value: value);
    setState(() => _roleChanged = true);
    reloadAllWindows();
  }
  return _Card(title: 'Device role', children: [
    _Radio<String>(context, value: 'both', groupValue: current,
        label: 'Both', onChanged: fixed ? null : onChanged),
    _Radio<String>(context, value: 'incoming', groupValue: current,
        label: 'Incoming only', onChanged: fixed ? null : onChanged),
    _Radio<String>(context, value: 'outgoing', groupValue: current,
        label: 'Outgoing only', onChanged: fixed ? null : onChanged),
    if (_roleChanged)
      Text(translate('Changes to device role take effect after restart.')),
  ]);
}
```

`mainSetOption` 走现有 `ipc::set_option` → 服务端持久化 + UI 本地持久化，无需新 FFI。

## 改动四：i18n

新增 5 个 key（sentence case，key 即英文文案，无需 en.rs 条目）：

```
Device role
Both
Incoming only
Outgoing only
Changes to device role take effect after restart.
```

按 AGENTS.md：追加到 `src/lang/template.rs` 与所有 `src/lang/*.rs`；`cn.rs` 给中文
（设备角色 / 双向 / 仅被控 / 仅主控 / 更改设备角色后需重启生效），`it.rs` 一律 `""`，其余语言留 `""`。

## 不做

- 不改 `start_all()`、直连/局域网监听的生命周期（热切换需要重构既有启动路径）
- 不扩展签名授权串结构
- 不改移动端 `flutter/lib/mobile/`、Web `flutter/lib/web/`
- 不改打包脚本；`custom.txt` 与 MSI `--conn-type` 的一致性由打包侧保证

## 回归面

- 未设置用户选项时：`conn_type()` 返回 `HARD_SETTINGS` 值，所有既有分支行为不变。
- 9 个调用点只换命名空间；`HARD_SETTINGS` 读取次数不变（多一次用户配置读）。
- `start_all()`、`client.rs` 连接逻辑、服务安装判断均无结构性修改。
- 移动端/Web 完全零 diff。

## 验证

1. `cargo test -p base`（新增解析测试）
2. `cargo check -p rustdesk`（确认 9 处替换编译通过）
3. `cd flutter && flutter analyze`（仅确认无新增告警）
4. 手动矩阵（本地构建，`custom.txt` 分别放 `{"conn-type":"incoming"}` / `{}`）：
   - 默认空 + 未选 → 双向：首页同时有 ID/密码区与连接输入框
   - 安装默认 incoming → 设置显示「仅被控」，首页隐藏连接输入框；主动连接报 “Incoming only mode”
   - 选择「仅主控」→ 重启 → 首页隐藏 ID/密码区，服务不注册 peer
   - 选择「双向」覆盖 incoming 默认 → 重启 → 连接输入框恢复
   - 在 `custom.txt` 用 `override-settings` 锁定 `conn-type` → 三个单选项置灰
