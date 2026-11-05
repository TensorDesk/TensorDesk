# 客户端挂起 / 时断时通恢复 方案

> 作者：powerfs 分支维护者
> 状态：**待实施**
> 目标：当远程桌面会话对 viewer 不可见或用户不活跃时，服务端停止向其推送视频帧以节省中继流量；链路时断时通时客户端能自动恢复会话而非从头建。

---

## 1. 背景与问题

当前 RustDesk 视频流是 **encoder → 共享订阅者通道 → 所有 viewer 广播**：

- `VideoService::send_video_frame_shared`（`src/server/service.rs:235`）对 `HashMap<i32, T>` 里所有 Subscriber 调用 `s.send(msg.clone())`，**不区分 viewer 状态**。
- `VIDEO_QOS`（`src/server/video_qos.rs`）虽然维护了 per-user `custom_fps`/`fps_cap()`，但只参与 encoder 的全局 fps 计算（`min over all viewers`），**不参与 per-viewer send**。
- 客户端窗口最小化、失焦、App 退到后台时，仍持续接收完整帧序列——中继流量一分不少。
- 网络抖动（10% 丢包）场景下我们实测 TCP 会以重传补帧，帧间隔抖动翻倍（311ms → 637ms），但会话不会断。**真正断链时**（TCP 连续 30s 无接收 `SEC30`），客户端走 `handle_disconnected`（`src/client/io_loop.rs:466`）→ 走新的 `connection_round_state` → **从头建会话**，服务端重起 encoder 订阅者列表，客户端重登录、重新协商。

本方案同时解决两件事：

1. **节省流量**：viewer 自己能告诉服务端「我在低流量模式」，服务端跳过对它的视频推送；恢复时无需重建 encoder，只需让下一个 I 帧正常经过即可。
2. **恢复会话**：客户端侧网络瞬时断开自动重连时，复用服务端既有 encoder 状态和订阅者关系，避免全量重协商。

---

## 2. 目标与非目标

### 2.1 目标

| 场景 | 当前 | 目标 | 度量 |
|---|---|---|---|
| Desktop 窗口最小化 | 正常帧 | **仅保活 30s/次** | 帧流量降到 ~0 |
| Desktop 失焦 / Alt+Tab | 正常帧 | 低 fps（可配置，默认 1 fps） | 帧流量降到 ~1/30 |
| Mobile App 退到后台 | 正常帧 | **暂停视频，TestDelay 继续** | 帧流量 0，30s 心跳保持 |
| 用户连续 N 秒无输入（空闲） | 正常帧 | 进入低 fps | 与失焦同 |
| 链路闪断（< 30s） | 走 `on_close` → 重连 | 自动恢复，服务端复用 session_key（encoder 按连接重建，见 §10.5） | 端到端恢复时间 < 5s |
| 链路彻底断（> 30s） | 同当前 | 同当前（强制重连） | 不变 |

### 2.2 非目标

- 不新增协议消息类型——全部走现有 `OptionMessage.custom_fps` 字段；
- 不改动 encoder（仍按 QoS.fps() 全局编码）；
- 不做应用层 FEC——Phase 2 已归档，纯 TCP 路径下 FEC 无收益；
- 不改变 relay/hbbr 行为（只是 hbbr 转发的字节少了，hbbr 代码不动）；
- 服务端"挂起 viewer"不会影响其他 viewer——encoder 正常编码，只是该 viewer 不收到帧。

---

## 3. 架构方案

### 3.1 客户端状态机

桌面端与移动端统一，通过 `custom_fps` 向服务端表达"想要的接收频率"。新增 **ViewerActivity** 枚举和 Dart→Rust bridge：

```
enum ViewerActivity {
    foreground,      // 正常 custom_fps（默认 30 或用户设置）
    background,      // 失焦 / Alt+Tab：custom_fps = 低 fps（默认 5）
    suspended,       // 最小化 / App 后台：custom_fps = 1（仅保活）
    inactive,        // 空闲超时：同 background
}
```

触发源（已有的都有钩子，不用新发明）：

| 事件 | 位置 | 活动态 |
|---|---|---|
| `onWindowMinimize` | `remote_page.dart:616` | suspended |
| `onWindowRestore` / `onWindowMaximize` | `remote_page.dart:562,576` | foreground |
| `onWindowBlur`（Windows/macOS） | `remote_page.dart:481` | background |
| `onWindowFocus` | `remote_page.dart:512` | foreground |
| `AppLifecycleState.paused/detached`（Mobile） | `mobile/remote_page.dart:224` | suspended |
| `AppLifecycleState.resumed` | 同上 | foreground |
| 空闲计时器（N 秒无键盘/鼠标） | **新增** `_IdleWatcher` | inactive（timeout） / foreground（activity） |
| 用户手动"暂停视频"按钮 | UI | suspended |

空闲计时器在 remote_page.dart 里加一个 `Timer.periodic(Duration(seconds: IDLE_SECONDS))` + 每次 inputModel 事件（鼠标移动/按键）`_lastInput = now`，timer 回调判断 `now - _lastInput > IDLE_SECONDS` 触发 inactive。默认 `IDLE_SECONDS = 120`（可配）。

### 3.2 客户端→服务端消息

复用 `OptionMessage.custom_fps`。**改动点：放开 `custom_fps < 5 => 30` 的钳制**（`src/client/io_loop.rs:1560`），允许 `0` 和 `1..4`。

- `custom_fps = 0`：保留，语义是「恢复到用户原始设置」（UI 层 reset 时用）。
- `custom_fps = 1..4`：新语义，低 fps / 保活模式。
- `custom_fps = suspended_value`：建议用 `custom_fps = 0` 当"完全停止"（帧停），`custom_fps = 1` 当"保活模式"（偶尔来一帧）。但这要和服务端达成一致。这里选 **`custom_fps = 0 → 停帧`，`custom_fps = 1 → 保活（每 N 帧发 1 帧）`**。

客户端桥（`src/flutter_ffi.rs:579`）已有 `session_set_custom_fps`，直接调用：

```dart
FFI.instance.sessionSetCustomFps(sessionId, 0); // 停帧
FFI.instance.sessionSetCustomFps(sessionId, 1); // 保活
FFI.instance.sessionSetCustomFps(sessionId, 30); // 恢复
```

### 3.3 服务端 per-viewer 丢帧

服务端收到 `custom_fps > 0` 后已喂入 `VIDEO_QOS.user_custom_fps(id, fps)`（`connection.rs:4949`）。问题是 **VIDEO_QOS.fps() 取所有 viewer 的最小值**，如果一个 viewer 设成 1，encoder 就真的以 1fps 编码——其他 viewer 也受害。

所以把「per-user custom_fps」拆成两部分：

1. **QoS 部分**（留给 congestion 自适应）：per-user 的 fps 调整仍通过 `user_delay_response_elapsed` → `user_network_delay` → `fps_cap()` → `highest_fps()`；
2. **Viewer 显式请求部分**（本次新增）：通过 Viewer 的 custom_fps 控制 send 频率，不影响 encoder fps。

**改动点**：在视频帧发送处按订阅者过滤，跳过已挂起的 viewer。

**实现（已落地，与初版草稿不同）**：不做「每 N 帧发一帧」的抽稀。已编码的 P 帧互相引用前一张参考帧，被丢帧的 viewer 会丢失参考链，后续 P 帧无法正确解码。因此挂起语义是**二进制**的：挂起期间一帧都不发，恢复时由编码器强制一个 I 帧重建参考链（§3.6）。这样既没有解码错误，也不需要 per-subscriber 的计数器状态。

也没有新建 `VideoSubscriber` 包装类型——它会让 video service 的泛型类型扩散到 `for_each_subscribe_mut` 等已有接口。改法是给 `ServiceTmpl` 加一个通用的只读遍历钩子，video service 在自己的发送函数里拿订阅 id 集合、查 `VIDEO_QOS.user_fps_target()`、自行决定丢弃：

```rust
// src/server/service.rs —— 唯一的共享改动，纯新增
pub fn for_each_subscribe_mut<F>(&self, mut f: F)
where F: FnMut(i32, &mut T) {
    let mut lock = self.0.write().unwrap();
    for (id, s) in lock.subscribes.iter_mut() { f(*id, s); }
}

// src/server/video_service.rs
fn send_video_frame_to_subscribers(sp: &GenericService, msg: Message) -> HashSet<i32> {
    // 先取 id 列表，再查 QoS：QoS 锁与服务锁不嵌套
    let ids: Vec<i32> = { ... sp.for_each_subscribe_mut(|id, _| v.push(id)) ... };
    let suspended: HashSet<i32> = {
        let qos = VIDEO_QOS.lock().unwrap();
        ids.iter().copied().filter(|id| qos.user_fps_target(*id) > 0).collect()
    };
    let msg = Arc::new(msg);
    let mut sent = HashSet::new();
    sp.for_each_subscribe_mut(|id, sub| {
        if suspended.contains(&id) { return; }
        sub.send(msg.clone());
        sent.insert(id);
    });
    sent
}
```

**保留路径**：没有任何 viewer 显式设置 custom_fps 时，`user_fps_target()` 全为 0 → 全部帧照常发送，与现状一致。

### 3.4 `user_fps_target` 与 QoS 的融合

VideoQoS 新增 per-user 的 **显式目标 fps**（与 QoS 内部自适应 fps 解耦）：

```rust
// video_qos.rs 中 UserData 加一个字段：
struct UserData {
    explicit_fps: Option<u32>,  // 客户端显式请求（挂起/失焦/空闲）
    // ... 原有字段不变
}
```

- `user_custom_fps(id, fps)` **保持原语义不变**（用户设置的 fps 上限，参与 QoS 全局计算），只由 `custom_fps >= 5` 调用。
- 新增 `user_explicit_fps(id, fps)`：`fps == 0` 清除 `explicit_fps`，非 0 设置。**非零即挂起**，不解释具体数值——挂起期间服务端本来就不发任何帧。
- `fps_cap()`（QoS 自适应上限）**不变**。
- 新增 `user_fps_target(id)`：返回 `explicit_fps.unwrap_or(0)`——0 表示"按 encoder fps 来"，>0 表示该 viewer 当前挂起。

`connection.rs` 里 `custom_fps` 的分派（按取值范围区分三种语义）：

| 取值 | 语义 |
|---|---|
| `>= 5` | 用户设置的 fps 上限：走 `user_custom_fps`；若此前处于挂起，同时清除挂起并强制 I 帧 |
| `1..=4` | viewer 挂起（瞬态，不写配置） |
| `-1` | viewer 恢复：清除挂起并强制下一帧为 I 帧 |
| `0` | 不处理（保持现状） |

这样，**QoS 自适应降 fps（弱网场景）和 viewer 显式降 fps（挂起/失焦）互不干扰**。QoS 仍管 encoder 全局 fps，per-viewer drop 只管 viewer 自己的接收频率。

### 3.5 TestDelay / keepalive

- viewer 挂起期间仍按 SEC30（30s）发送一次 TestDelay——由服务端 timer 驱动，与视频无关。
- 客户端收到 TestDelay 仍 reply，保持 `last_recv_time` 刷新——不会触发 SEC30 disconnect。
- 如果中继 hbbr 也会在挂起期间转发 TestDelay，那 hbbr 流量也降下来了（TestDelay 是小消息）。

### 3.6 恢复时的强制 I 帧

viewer 从挂起恢复（custom_fps → 正常值）时，**必须立即给该 viewer 一个强制 I 帧**，避免花屏或需要等待不定长的 keyframe 周期。

#### 3.6.1 编码器接口

**实现（已落地）**：给 `EncoderApi::encode_to_message` 增加一个 `force_keyframe: bool` 参数（唯一一个需要改签名的 trait 方法，调用点只有 video_service 一处），各编码器内部：

- `VpxEncoder` / `AomEncoder`：抽出 `encode_with_flags(..., flags)`，`encode` 传 0，`encode_keyframe` 传 `VPX_EFLAG_FORCE_KF` / `AOM_EFLAG_FORCE_KF`；`encode_to_message` 按 `force_keyframe` 选择其一。
- `HwRamEncoder`（hwcodec）/ `VRamEncoder`：签名接受该参数但暂不强制 IDR（FFmpeg / 硬件编码路径的强制关键帧接口不同，见 §3.6.3）。

#### 3.6.2 触发路径

`video_service.rs` 里加一个进程级一次性标记：

```rust
pub static ref FORCE_KEYFRAME: AtomicBool = AtomicBool::new(false);
```

`connection.rs` 在「挂起 → 恢复」时置位：

```rust
let mut qos = video_service::VIDEO_QOS.lock().unwrap();
if qos.user_fps_target(id) > 0 {
    qos.user_explicit_fps(id, 0);
    video_service::FORCE_KEYFRAME.store(true, Ordering::Relaxed);
}
```

编码循环在 `encode_to_message` 之前用 `compare_exchange(true, false)` 读取并清除，只有紧随其后的那一帧被强制成 I 帧，后续帧恢复普通编码。

#### 3.6.3 注意

- 强制 I 帧是**全局 encoder 行为**——会让 encoder 给**所有 viewer** 都产出一个 I 帧（encoder 是全局单例），这是可以接受的（一帧 I 帧额外带宽 ~几百 KB，一次恢复只触发一次）；
- 如果想更精细（只给一个 viewer 强制 I 帧），需要在 viewer 恢复时给它单独建一个"丢 P 帧直到下一个 I 帧"的状态，更复杂。**本次不做**；
- HW codecs（H264/H265）强制 I 帧接口不同——NVENC 是 `NvEncEncodePicture(..., NVENC_PIC_PARAMS_FORCE_IDR)`。本次先只给 VPX/AOM 加，HW codecs 后续跟进。

### 3.7 连接状态机现状与新增字段

#### 3.7.1 现有状态机清单

**客户端侧**（`src/ui_session_interface.rs:101-153`）：

```rust
enum ConnectionState { Connecting, Connected, Disconnected }
pub struct ConnectionRoundState { round: u32, state: ConnectionState }
```

这是客户端**唯一**的连接状态。三个状态互斥；Flutter 层监听后决定 UI——`Connected` 显示视频，`Disconnected` 弹重连对话框。中间没有任何中间状态。

**服务端侧**（`src/server/connection.rs:358-468`）：

`Connection` struct **不是 enum 状态机**，而是一篮子布尔标志 + 计数器（约 60 个字段）：

| 字段 | 性质 | 含义 |
|---|---|---|
| `authorized: bool` | 布尔 | 登录通过 |
| `awaiting_2fa: bool` | 布尔 | 等 TOTP / trusted device |
| `closed: bool` | 布尔 | 已 on_close |
| `last_test_delay: Option<Instant>` | 时间戳 | TestDelay probe outstanding |
| `network_delay: u32` | 数值 | 最近一次队列延迟采样 |
| `auto_disconnect_timer: Option<(Instant, u64)>` | 可选定时 | 空闲自动断开 |
| `services_subed: bool` | 布尔 | 已 subscribe 到所有 service |
| `auth_conn_type: AuthConnType`（server 层）| 枚举 | Remote / FileTransfer / PortForward / ViewCamera / Terminal |
| ~30 个 bool 字段 | 能力标志 | `keyboard` / `clipboard` / `audio` / `block_input` / `privacy_mode` / `disable_clipboard` ... |

**Subscriber 层**（`src/server/service.rs:20-44`）：

```rust
pub trait Subscriber: Default + Send + Sync + 'static {
    fn id(&self) -> i32;
    fn send(&mut self, msg: Arc<Message>);
}
```

**没有 suspend / idle 状态**。`send_video_frame_shared` 对 HashMap 里所有 Subscriber 广播——不查状态，不丢帧。

**QoS 层**（`src/server/video_qos.rs:261-282`）：

```rust
struct UserData {
    auto_adjust_fps: Option<u32>,
    custom_fps: Option<u32>,
    delay: UserDelay,
    record: bool,
}
```

`custom_fps` 参与全局 encoder fps 计算（取所有 viewer 最小值），**不 per-viewer drop**。

#### 3.7.2 现有状态机的缺口

| 本次需求 | 缺口 |
|---|---|
| Viewer 挂起（最小化 / 后台 / 失焦）| 没有字段存"这个 viewer 显式说自己挂起了"；QoS.custom_fps 语义是"我想要的正常 fps 上限"，不是"我现在要低流量模式" |
| 增量重连 | `ConnectionRoundState` 只有 `Disconnected`，不知道"这个断链是闪断还是彻底断"；服务端 `Session` 只存 last_recv_time + 密码 |
| 恢复时强制 I 帧 | 没有"刚恢复需要一个 I 帧"的标记位 |
| 弱网判定 | 没有 per-Connection 的弱网状态；`network_delay` 只是采样，不决定策略 |

#### 3.7.3 本次新增字段

**不引入 enum 大状态机**——Connection 是"一篮子字段"风格，保持一致。弱网 / 挂起 / 增量重连是**正交维度**（一个 Connection 可以同时是弱网 + 挂起 + 增量重连尝试中），enum 表达不了组合态。

服务端 `Connection` 新增（`src/server/connection.rs`）：

```rust
/// viewer 显式请求的接收 fps；None 表示 viewer 没有显式请求（走 encoder 全局 fps）
/// 1 = 保活；0 = reset；>1 = 想要的接收 fps
explicit_fps: Option<u32>,

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum ViewerActivity {
    Foreground,   // 正常窗口
    Blurred,      // 失焦 / Alt+Tab
    Suspended,    // 窗口最小化 / Mobile App 后台
    Inactive,     // 用户连续 N 秒无输入（空闲超时）
}
viewer_activity: ViewerActivity,

/// 这个 viewer 是否在 HIBERNATE_BUFFER 窗口内断线（用于增量重连）
/// None = 正常连接；Some(deadline) = 断线，deadline 前仍可 resume
buffer_reconnect_until: Option<Instant>,
```

客户端 `ConnectionRoundState` 新增（`src/ui_session_interface.rs:107`）：

```rust
pub struct ConnectionRoundState {
    round: u32,
    state: ConnectionState,
    // === 本次新增 ===
    session_key: Option<String>,
    disconnected_at: Option<Instant>,
    viewer_activity: ViewerActivity,
}
```

Flutter 层 `RemotePage` 新增（`flutter/lib/desktop/pages/remote_page.dart`）：

```dart
enum ViewerActivity { foreground, blurred, suspended, inactive }
ViewerActivity _activity = ViewerActivity.foreground;
DateTime? _lastInputAt;
Timer? _idleTimer;
```

#### 3.7.4 状态转移规则

**ViewerActivity 转移**：

| 触发条件 | viewer_activity 变化 | explicit_fps 变化 | 备注 |
|---|---|---|---|
| 用户手动最小化 / Mobile 后台 | → Suspended | → 1（保活） | |
| 用户恢复窗口 / App 前台 | → Foreground | → 用户原始设置 | **此处触发 force_keyframe** |
| Alt+Tab / 失焦 > Ns | → Blurred | → `suspend-blur-fps`（默认 5）| |
| 鼠标不动 > `suspend-idle-seconds` | → Inactive | → `suspend-blur-fps` | |
| 有鼠标/键盘输入 | → Foreground | → 用户原始设置 | |
| 链路闪断（TCP 断，< buffer）| 不变 | 不变 | 客户端等同一 session_key 重连 |
| 链路彻底断（> buffer）| 不变 | 不变 | 客户端弹重连 UI，新 round |

**服务端行为矩阵**（VideoService 对每个 Subscriber）：

| viewer_activity | explicit_fps | VideoService.send_video_frame_shared 行为 |
|---|---|---|
| Foreground | `None`（默认） | 每帧都 send（现状） |
| Foreground | `Some(30)` | 每帧都 send（fps 不低于 encoder fps 就没 drop） |
| Blurred / Inactive | `Some(5)` | 每 encoder_fps / 5 帧 send 一次 |
| Suspended | `Some(1)` | 每 encoder_fps 帧 send 一次（约 1fps 保活） |
| 任意 | `Some(0)` | reset → 清 explicit_fps → 按 Foreground 走 |

**断线 buffer 窗口**：

| buffer_reconnect_until | 服务端行为 |
|---|---|
| `None` | 正常连接，正常 on_close |
| `Some(deadline)` 且 deadline > now | Connection 保留，session_key 仍有效；encoder 的 HIBERNATE_BUFFER 内保留最后一个订阅者状态；客户端带 session_key 来直接 resume，**不触发 encoder 重置** |
| `Some(deadline)` 且 deadline <= now | 走正常 on_close；encoder 被允许停掉；客户端必须重新登录 |

**弱网判定**：不加单独字段。VideoQoS 现有的 `avg_delay`（超出基线的队列延迟）已能驱动 fps 自适应；弱网时 encoder fps 自然下降，viewer 的显式 suspend/blur 状态仍按 viewer_activity 独立生效。

---

## 4. 断线重连路径分析

### 4.1 当前行为

链路闪断时：

1. 服务端 TCP 连接断开 → `on_close("...", true)`（connection.rs）→ **encoder 从 subscribes 移除该 viewer**。
2. 客户端 io_loop 读 socket 报错 → `handle_disconnected(round)` → `set_disconnected(round)`。
3. Flutter 层 `ConnectionManager` 监听 round_state → UI 重新走登录/协商 → **新的 Subscribe 建立**。

**问题**：encoder 被强行取消订阅 → 订阅清单里少一个 viewer → `ServiceTmpl::on_unsubscribe` 里如果是最后一个订阅者，会触发 encoder 重置（`display_service.rs:709-727` 附近的 subscribe 检测）。闪断 → 重新 subscribe → encoder 被重置再启动，有明显冷启动延迟。

### 4.2 增量恢复方案

> 本节为设计草稿，未被采纳：实际实现只复用 `session_key`，encoder 按连接重建
> （见 §10.1 第 7 条 / §10.5）。

**核心观察**：服务端有 `session_key`（`connection.rs:277 Session`），客户端重连时可以带着 session_key 来——告诉服务端"我是刚才那个断的，别重启 encoder"。

增量恢复需要改 3 处：

| 位置 | 改动 |
|---|---|
| `src/client/io_loop.rs` | 断链重连时（同一个 round_id + session_key）走「快速登录」分支，跳过完整的 `subscribe` 重置 encoder 逻辑 |
| `src/server/connection.rs` | `on_close` 时如果 session_key 在「最近断开（< DISCONNECT_BUFFER_SECONDS）」表中，把 session_key→encoder_state 暂存；客户端带着同一个 session_key 再来时直接 resume，不触发 encoder 重置 |
| `src/server/service.rs` | `on_unsubscribe` 里给最后一个订阅者断开加一个 buffer（`ServiceTmpl::hibernate_timeout = 30s` 已存在 `HIBERNATE_TIMEOUT`），期间再有 subscribe 直接恢复 encoder 线程 |

**已发现的现成机制**：`service.rs:44` 有 `HIBERNATE_TIMEOUT = 30` 字段但未被 VideoService 主动利用；`ServiceTmpl::run` 里 encoder loop 已经支持空订阅者（`sp.active()` → `sp.has_subscribes()` 检查后才调 callback）——encoder 线程不会凭空跑，也不会凭空停。

**最小 diff 方案**：**先用客户端侧快速重连 + 让服务端 encoder buffer 最后一个订阅者断开 30s**。客户端 `handle_disconnected` 后，如果是同 session_key 且在 30s 内，走「快速登录」跳过完整握手。这能把闪断恢复时间从 ~20s 降到 ~3s。

**超过 30s 的断链**：encoder 被允许停掉——此时恢复和当前行为一样（从头起），因为用户端到端体验已经差到需要重登界面了。

### 4.3 客户端 round_state 增量恢复

`src/client/io_loop.rs` 里 `connection_round_state.set_disconnected(round)` 后，Flutter 层监听 round 变化重新拉起 connection。增量恢复需要：

- `round_state` 额外存 `session_key` 和 `timestamp`；
- Flutter 层收到 disconnected → 如果同 session_key 且 < RECONNECT_BUFFER_SECONDS → 不弹重连对话框 → 直接走隐式 reconnect。

---

## 5. 配置开关

在 `libs/base/src/config/keys.rs` 新增：

| 键 | 默认 | 语义 |
|---|---|---|
| `enable-viewer-suspend` | `true` | 总开关；false 时完全不发送挂起信号，服务端行为不变 |
| `suspend-on-minimize` | `true` | 窗口最小化时挂起 |
| `suspend-on-background` | `true` | App 后台时挂起（Mobile） |
| `suspend-on-blur` | `true` | 失焦 / Alt+Tab 时挂起 |
| `suspend-idle-enable` | `false` | 空闲挂起开关；默认关闭，因为被动观看也会被判定为空闲 |

挂起是二进制的（停发全部帧），因此不提供「失焦 / 最小化时的接收 fps」键；空闲阈值当前固定为 120s（含桌面与 Mobile）。这四个键曾经加入过，但没有任何读取方，实施时已删除。

---

## 6. 改动清单（预计 11 个文件，~350 行）

### 6.1 协议 / 消息层
- **无需改动**——全部复用 `OptionMessage.custom_fps`。

### 6.2 Dart 侧（Flutter desktop + mobile）
| 文件 | 改动 | 行数 |
|---|---|---|
| `flutter/lib/desktop/pages/remote_page.dart` | 加 `_setViewerActivity(ViewerActivity)` + bridge 调用 + 空闲 watcher | ~80 |
| `flutter/lib/mobile/pages/remote_page.dart` | 同（Mobile 版 remote_page） | ~40 |
| `flutter/lib/generated_bridge.dart` | 不手改（CI 生成），但 `session_set_custom_fps` 已存在 | 0 |

### 6.3 Rust 侧（客户端）
| 文件 | 改动 | 行数 |
|---|---|---|
| `src/client/io_loop.rs:1560` | 放开 `custom_fps < 5 => 30` 钳制，允许 0/1/2/3/4 | ~5 |
| `src/client/client.rs` | 可选：让 `set_custom_fps(0)` 语义更清晰 | 0（或微调） |
| `src/client/io_loop.rs` | `handle_disconnected` 增量恢复分支 | ~30 |

### 6.4 Rust 侧（服务端）
| 文件 | 改动 | 行数 |
|---|---|---|
| `src/server/video_service/video_sub.rs` | **新建** `VideoSubscriber { inner, drop_state }` | ~25 |
| `src/server/video_service.rs` | `send_video_frame_shared` 遍历 subscriber 时查 fps target | ~25 |
| `src/server/video_qos.rs` | `UserData` 加 `explicit_fps`；新增 `user_fps_target(id)`；`user_custom_fps` 改语义 | ~40 |
| `src/server/connection.rs` | 收到 `custom_fps` 时喂给 QoS；`on_close` session_key buffer；快速登录分支 | ~40 |
| `src/server/service.rs` | 复用 `HIBERNATE_TIMEOUT`；给 VideoService subscriber 断开加 buffer | ~15 |

### 6.5 配置键
| 文件 | 改动 | 行数 |
|---|---|---|
| `libs/base/src/config/keys.rs` | 新增 9 个键 | ~9 |
| `src/lang/template.rs` + `src/lang/*.rs` | 追加 9 个 key（翻译项） | 自动 |

---

## 7. 验证计划

### 7.1 单元测试（Rust，已落地）

| 测试 | 位置 | 通过条件 |
|---|---|---|
| explicit_fps 设置/清除 | `src/server/video_qos.rs` 内联测试 | `user_explicit_fps(id, 1)` → `user_fps_target(id) == 1`；`user_explicit_fps(id, 0)` → 0 |
| explicit_fps 与 QoS 全局 fps 正交 | `src/server/video_qos.rs` | 设置 explicit_fps 不改变 QoS 采集的 `fps_cap()` |
| 用户 custom_fps 与挂起并存 | `src/server/video_qos.rs` | `user_custom_fps(5)` + `user_explicit_fps(1)` 两者独立保留 |
| 增量重连判定 | `src/client.rs` `#[cfg(test)] mod tests` | 成功连接 + 断线窗口内 → true；未连接过 / 超窗口 / `clear_session()` 后 → false |

「按订阅者丢弃帧」的发送路径与 Flutter 空闲状态机没有单测，依赖集成测试（§7.2）。

### 7.2 集成测试（双机 .165/.167）

| 场景 | 操作 | 预期 |
|---|---|---|
| Desktop 最小化 → 恢复 | 最小化 RustDesk 窗口 30s → 恢复 | 这 30s 内 viewer 收到 0 帧，恢复后首帧为 I 帧并立即正常 |
| Mobile 后台 → 前台 | App 切后台 30s → 回前台 | 同 |
| Alt+Tab 失焦 1min | 切换到其他窗口 1min | viewer 收到 0 帧，回到该窗口后恢复 |
| 空闲挂起 | 鼠标不动 120s → 移动鼠标 | 进入挂起 → 恢复平滑 |
| 闪断恢复（< 30s） | `iptables -I OUTPUT -p tcp --dport 21118 -j DROP` 10s 后删 | 客户端不弹重连 UI，自动恢复；encoder 按连接重建（见 §10.5），恢复延迟实测 <1s |
| 彻底断（> 30s） | DROP 60s | 客户端弹重连 UI，服务端 encoder 重建（与当前一致） |

### 7.3 中继流量计量

用 parse_pcap.py 抓 3 档：
- 正常 foreground 10min：`X kbps`
- 全部窗口最小化 10min：**< X/50**（目标）
- 混合 1 foreground + 1 background：foreground 不受影响，background 流量降

---

## 8. 风险与退化面

| 风险 | 触发条件 | 缓解 |
|---|---|---|
| Viewer suspend 影响其他 viewer | 把 explicit_fps 纳入 encoder fps 计算 | explicit_fps 只参与按订阅者丢弃，不进入 QoS 全局 fps；`fps_cap()` 未改 |
| 恢复体验差（黑屏直到下一个 I 帧） | VPX/AOM 强制关键帧已实现；HW 编码器未强制 IDR | 软编路径恢复即出 I 帧；HW 编码器见 §10.5 已知限制 |
| `for_each_subscribe_mut` 影响其他 service | 它是纯新增方法，`send_shared` / `send_video_frame` 未改 | audio/clipboard 仍走原路径 |
| 断链 buffer 30s 里如果同一个 viewer 真的换了机器重连 | session_key 被复用 | session_key 是每次新登录生成的 UUID；buffer 期间同 IP 同 ID 才算复用 |
| iOS 后台限制 | iOS App 后台后 socket 会被系统掐 | 用 `AppLifecycleState.paused` 立即 suspend；TestDelay 也停，30s 后强制断链（这是 iOS 系统行为，不是我们代码） |

**退化面最小化**：
- 关闭所有新键（enable-viewer-suspend=false）后，行为与当前完全一致——不发送任何 custom_fps 变更，QoS.user_fps_target 返回 0 → 全部帧正常发送。
- 断链 buffer 默认 30s，HIBERNATE_TIMEOUT 本来就是 30——没改 encoder 逻辑，只改客户端 reconnect 分支。

---

## 9. 不做什么（Corner case）

- **不做 per-subscriber 视频独立编码**：encoder 全局，per-viewer 只 drop；
- **不做 viewer priority（VIP viewer 永远不挂起）**：配置复杂，以后需要再加；
- **不做中继 hbbr 端的转发优化**：hbbr 转发的字节是固定 1:1，我们发少了 hbbr 自然少发；
- **不做 WebRTC SFU 级别的单独编码路径**：当前 WebRTC 不是默认通道；
- **不做 iOS 后台保活 socket**：iOS 系统行为，规避成本高。

---

## 10. 实施记录（2026-11）

### 10.1 与方案草稿的偏差

1. **per-viewer 丢帧改为二进制挂起**（§3.3）：已编码的 P 帧互相引用，抽稀会让 viewer 丢失参考链；挂起期间一帧不发，恢复时强制 I 帧。
2. **不新建 `VideoSubscriber`**：改用 `ServiceTmpl::for_each_subscribe_mut` 一个只读遍历钩子，video service 自行按 `user_fps_target()` 过滤。
3. **强制 I 帧**：`EncoderApi::encode_to_message` 增加 `force_keyframe: bool`（调用点只有 video_service 一处），VPX/AOM 走 `encode_with_flags`；进程级一次性 `FORCE_KEYFRAME` 原子标记由 `compare_exchange` 读取并清除。
4. **`custom_fps` 复用为三种语义**：`>=5` 是原有的用户 fps 上限，`1..=4` 是挂起，`-1` 是恢复。挂起/恢复是瞬态信号，不写 peer 配置（`Session::set_custom_fps` 里 `custom_fps < 5` 直接发 Message，不落盘）。
5. **`get_toggle_option` 是硬编码白名单**：新增开关必须在 `src/client.rs` 显式列出，否则永远返回 false。`suspend-idle-enable` 默认 false（被动观看也会被判空闲）。
6. **删除无读取方的配置键**：`suspend-blur-fps` / `suspend-minimize-fps` / `suspend-idle-seconds` / `reconnect-buffer-seconds`；空闲阈值固定 120s，重连窗口固定 30s（Dart 常量）。
7. **增量重连不保留 encoder**：设计草稿曾计划在 `HIBERNATE_TIMEOUT` 内保留 `VideoService` / encoder，实际实现只复用 `session_key`，新连接按 `video_service::new` 重建 encoder（见 §10.5）。

### 10.2 空闲检测

`InputModel.lastInputAt` 在鼠标（`handleMouse` / `_sendMouseUnchecked` / `scroll`）、键盘（`handleKeyEvent` / `handleRawKeyEvent` / `inputKey`）入口更新。桌面与 Mobile 的空闲 watcher 每秒读取它：无输入满 120s → `inactive`（挂起）；出现新输入且当前是 `inactive` → 回到 `foreground`。这样空闲恢复不依赖窗口事件，避免「悬停 2 分钟后画面冻结且无法自动恢复」。

### 10.3 断线增量重连

- 服务端零改动：`SessionKey` 保留、`session_reconnected()`、`check_remove_session()`、`HIBERNATE_TIMEOUT` 均已存在。
- 客户端 `ConnectionRoundState` 新增「已成功连接」标记与 `disconnected_at`，`can_incremental_reconnect(buffer_sec)` 判定「曾经成功连接 + 断线发生在窗口内」；`clear_session()` 用于彻底断开时重置。服务端的 SessionKey 由 LoginRequest 里的 `my_id` / `my_name` / `session_id` 组成，而重连复用同一个 `session_id`，因此服务端天然把两次连接认作同一会话，客户端不需要携带额外 key。
- Flutter `handleMsgBox` 在弹出 "Connection Error" 前先尝试静默重连：最多 2 次，`sessionCanIncrementalReconnectSync`（同步 FFI）→ `sessionReconnect`；Web 侧该探针恒为 false。
- 恢复后首帧由服务端强制 I 帧，不需要额外协议。

### 10.4 验证状态

- `cargo check -p rustdesk --lib --features flutter` 通过（含 `flutter_ffi.rs`）。
- `cargo test --lib --features flutter`：226 passed / 1 failed（失败项
  `keyboard::shortcuts::tests::alt_only_shortcut_neutralizes_windows_menu` 报 `kbd context error`，
  是容器缺键盘上下文的既有环境失败，与本方案无关）。
- `automatic_fps_never_requests_a_suspended_viewer`：解码 5fps 时自动档位被钳到 5，
  证明弱机不会被误判为挂起（P0 缺陷回归）。
- 本地 hbbs 双实例集成（2026-11-05，Flutter B 侧）：
  - 悬停噪声 10s 发送 1,039,175 B（基线），挂起后 10s 仅 +198 B；
  - 空闲 120s → `custom_fps: 1`，之后无 `custom_fps: 30` 覆盖（Fix A 生效）；
  - 恢复（`custom_fps: -1`）后 3.2s +203,721 B，画面立即恢复；
  - 最小化挂起保持，窗口恢复触发 `custom_fps: -1`（Fix B 生效），5s +341,917 B；
  - `enable-viewer-suspend=false` 零回归：最小化不发送 `custom_fps: 1`，5s +299,971 B；
  - 闪断 <30s：`ss -K` 杀会话后 1s 内重新打洞，无弹框；断链 >30s：先静默重连 2 次，
    离线自动重试到 30s 上限耗尽后停止重试，弹框停留等待用户。
- 闪断后服务端 `session_key` 复用，但 encoder 按连接重建（见 §10.5）。
- Flutter 侧桥接（`sessionCanIncrementalReconnectSync`）已按 AGENTS.md 手工补齐
  `src/bridge_generated.rs` / `src/bridge_generated.io.rs` / `flutter/lib/generated_bridge.dart`
  三处（均为 gitignored 本地构建产物），`flutter build bundle --debug` 与
  `flutter build linux --debug` 均通过；CI 重新 codegen 后等价。

### 10.5 已知限制

- 所有 viewer 都挂起时编码器仍在产帧：带宽为零，但 CPU 照常消耗；不做编码器暂停。
- 强制 I 帧是进程级一次性标记，会给所有 viewer 同时产出一帧 I 帧（一次恢复可接受）。
- HW 编码器（hwcodec / vram）接受 `force_keyframe` 参数但暂不强制 IDR，恢复后可能等自然关键帧。
- 空闲判定依赖输入模型埋点；未经过这些入口的输入路径不会被计入。
- **强制 I 帧无日志可观测**：只能从 `handle_one_frame` 的 `force_kf` 代码路径与恢复后
  字节突增（3.2s +203,721 B）间接验证，socket 计数无法区分 I/P 帧。
- **闪断重连会重建 encoder**：`video_service::new` 按连接创建 encoder，新 socket 即新
  service；`session_key` 复用但 encoder 不跨连接保留。恢复仍 <1s，不影响可用性。
  服务端 `check_remove_session` 在唯一 remote 连接关闭时立即删除 session
  （`is_remote || !another_remote` 分支），不保留 30s buffer；与客户端 30s
  静默重连窗口不冲突。
- **移动端 suspend 未做端到端验证**：`flutter/lib/mobile/pages/remote_page.dart` 的
  `AppLifecycleState` 钩子只做了代码级修改与 `flutter build bundle` 编译验证。
- 「按订阅者丢弃帧」发送路径、Flutter 空闲状态机、断线静默重连均无自动化测试，
  仅 `ConnectionRoundState` 的窗口判定有 Rust 单测。

### 10.6 本地 Flutter 构建阻塞与修复（已解决）

- 现象：`flutter build bundle --debug` 的首个 kernel 错误是 `lib/models/model.dart:1007`
  调用 `sessionCanIncrementalReconnectSync` 未定义——`flutter/lib/generated_bridge.dart`
  停留在 2026-11-02 21:54，早于 `src/flutter_ffi.rs` 新增
  `session_can_incremental_reconnect_sync`（同步 `SyncReturn<bool>`）。
- 约束：`generated_bridge.dart`、`bridge_generated.rs`、`bridge_generated.io.rs` 都是
  gitignored 的 codegen 产物，AGENTS.md 明确本地不跑 `flutter_rust_bridge_codegen`。
- 修复（仅本地构建用，CI 重新生成后等价）：手工补 Rust 侧 `*_impl` 与 `#[no_mangle]`
  导出、Dart 侧 abstract 声明 / `RustdeskImpl` 实现 / `RustdeskWire` 的 `_lookup` 三处，
  照 `sessionGetEnableTrustedDevices` 的模式写。
- 结果：`nm -D` 有 `wire_session_can_incremental_reconnect_sync` 符号，
  `flutter build bundle --debug` 无 kernel 错误，`flutter build linux --debug` 产出
  `flutter/build/linux/x64/debug/bundle/`，容器内 `flutter build linux` 的
  `invalid-type` 未复现。
