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
| 链路闪断（< 30s） | 走 `on_close` → 重连 | 自动恢复，**服务端不重建 encoder** | 端到端恢复时间 < 5s |
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

**改动点**：在 `VideoService::send_video_frame_shared` 里，遍历 Subscriber 时查该 viewer 的"想要接收频率"，决定这帧发不发。

实现方式：给 ServiceInner 的 HashMap 里每个 Subscriber 加一份 **per-subscriber drop 状态**。但 Subscriber 泛型是 `T: Subscriber + From<ConnInner>`，VideoService 用的是哪种 T？

查代码（`src/server/service.rs:43`）：`GenericService = ServiceTmpl<ConnInner>`，ConnInner 同时是多个 service 的 Subscriber。所以 **不能在 ConnInner 上加视频专属字段**——会污染 audio/clipboard 等其他 service。

**最终方案**：VideoService 改用 **包一层的 Subscriber**：

```rust
// src/server/video_service/video_sub.rs（新建）
#[derive(Clone, Default)]
pub struct VideoSubscriber {
    pub inner: ConnInner,
    pub drop_state: AtomicU32, // 帧跳过计数器，用 fetch_add 原子访问
}
impl Subscriber for VideoSubscriber {
    fn id(&self) -> i32 { self.inner.id() }
    fn send(&mut self, msg: Arc<Message>) { self.inner.send(msg) }
}
impl From<ConnInner> for VideoSubscriber {
    fn from(inner: ConnInner) -> Self { Self { inner, drop_state: 0.into() } }
}
```

然后 `send_video_frame_shared` 改：

```rust
pub fn send_video_frame_shared(&self, msg: Arc<Message>) -> HashSet<i32> {
    let mut conn_ids = HashSet::new();
    let mut lock = self.0.write().unwrap();
    let encoder_fps = VIDEO_QOS.fps(); // 快照，不要多次 lock
    for sub in lock.subscribes.values_mut() {
        let id = sub.inner.id();
        let viewer_fps = VIDEO_QOS.user_fps_target(id); // 新增：per-user 自定义 target
        if viewer_fps == 0 || viewer_fps < encoder_fps {
            // drop_state 每过 encoder_fps / max(1, viewer_fps) 次才真正发一次
            let skip_period = encoder_fps.max(1) / viewer_fps.max(1);
            let prev = sub.drop_state.fetch_add(1, Ordering::Relaxed);
            if prev % skip_period != 0 {
                continue;
            }
        }
        sub.send(msg.clone());
        conn_ids.insert(id);
    }
    conn_ids
}
```

**保留路径**：没有任何 viewer 显式设置 custom_fps 时，所有 viewer 的 viewer_fps 为 0 → 全部帧正常发送，与现状一致。

### 3.4 `user_fps_target` 与 QoS 的融合

VideoQoS 新增 per-user 的 **显式目标 fps**（与 QoS 内部自适应 fps 解耦）：

```rust
// video_qos.rs 中 UserData 加一个字段：
struct UserData {
    explicit_fps: Option<u32>,  // 客户端显式请求（挂起/失焦/空闲）
    // ... 原有字段不变
}
```

- `user_custom_fps(id, fps)` 改为：当 fps > 0 时设置 `explicit_fps = Some(fps)`；当 fps == 0 时**保留**现有逻辑（UI reset 时的语义），但本次 viewer suspend 不使用 fps=0——使用 fps=1 表示"显式停帧"，fps=0 继续表示"恢复默认"。
- `fps_cap()`（QoS 自适应上限）**不变**。
- 新增 `user_fps_target(id)`：返回 `explicit_fps.unwrap_or(0)`——0 表示"按 encoder fps 来"，>0 表示 viewer 主动想要该 fps。

这样，**QoS 自适应降 fps（弱网场景）和 viewer 显式降 fps（挂起/失焦）互不干扰**。QoS 仍管 encoder 全局 fps，per-viewer drop 只管 viewer 自己的接收频率。

### 3.5 TestDelay / keepalive

- viewer 挂起期间仍按 SEC30（30s）发送一次 TestDelay——由服务端 timer 驱动，与视频无关。
- 客户端收到 TestDelay 仍 reply，保持 `last_recv_time` 刷新——不会触发 SEC30 disconnect。
- 如果中继 hbbr 也会在挂起期间转发 TestDelay，那 hbbr 流量也降下来了（TestDelay 是小消息）。

### 3.6 恢复时的强制 I 帧

viewer 从挂起恢复（custom_fps → 正常值）时，**必须立即给该 viewer 一个强制 I 帧**，避免花屏或需要等待不定长的 keyframe 周期。

#### 3.6.1 编码器接口

`scrap` crate 里 `VpxEncoder::encode` 当前 flags 参数传 `0`（`/home/portion/rustdesk/libs/scrap/src/common/vpxcodec.rs:266-273`）：

```rust
call_vpx!(vpx_codec_encode(&mut self.ctx, &image, pts as _, 1, 0 /* Flags */, VPX_DL_REALTIME as _));
```

VPX 要强制输出 keyframe 需要传 `VPX_EFLAG_FORCE_KF`（value = 1）。新增一个**重载**，不改现有 encode 签名（保持最小 diff）：

```rust
// vpxcodec.rs 中新增：
pub fn encode_keyframe<'a>(&'a mut self, pts: i64, data: &[u8], stride_align: usize)
    -> Result<EncodeFrames<'a>> {
    // ... 图像封装同 encode ...
    call_vpx!(vpx_codec_encode(&mut self.ctx, &image, pts as _, 1,
        1 /* VPX_EFLAG_FORCE_KF */, VPX_DL_REALTIME as _));
    Ok(EncodeFrames { ctx: &mut self.ctx, iter: ptr::null() })
}
```

AomEncoder / HwRamEncoder / VRamEncoder 同理加 `encode_keyframe` 重载；**但 encoder trait（`EncoderApi`）不加新方法**——trait 改动会牵动所有实现，本次让调用侧直接调具体 encoder 的扩展方法。

#### 3.6.2 触发路径

VideoFrameController（`src/server/video_service.rs:176`）加一个原子标记：

```rust
struct VideoFrameController {
    display_idx: usize,
    cur: Instant,
    send_conn_ids: HashSet<i32>,
    force_keyframe: AtomicBool,    // 新增
}
```

当 viewer 从挂起恢复（`user_custom_fps(id, fps)` 里新 fps > `suspend_minimize_fps` 且旧 fps ≤ 该值）时：

```rust
VideoFrameController::global().force_keyframe.store(true, Ordering::Relaxed);
```

下一个 encoder encode call 在 encode loop 开头检查这个 flag——如果 true，走 `encode_keyframe` 重载并清 flag。这样只影响下**一帧**编码，不是一直强制 I 帧。

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
| `suspend-on-blur` | `true` | 失焦 / Alt+Tab 时降 fps（不是停帧） |
| `suspend-blur-fps` | `5` | 失焦时的接收 fps |
| `suspend-idle-enable` | `true` | 空闲挂起总开关 |
| `suspend-idle-seconds` | `120` | 空闲判定秒数 |
| `suspend-minimize-fps` | `1` | 最小化时的接收 fps（0=完全停帧，1=保活） |
| `reconnect-buffer-seconds` | `30` | 客户端侧断链后仍尝试增量重连的窗口 |

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

### 7.1 单元测试（Rust）

| 测试 | 位置 | 通过条件 |
|---|---|---|
| VideoQoS.user_fps_target 与 fps_cap 分离 | `video_qos/tests/viewer_fps.rs` | explicit_fps 设置后 user_fps_target 返回该值，fps_cap 不受影响 |
| send_video_frame_shared per-subscriber drop | `video_service/tests/drop.rs` | encoder_fps=30，viewer1 explicit_fps=1，viewer2 explicit_fps=30 → viewer1 平均 1fps 收到帧 |
| 多个 viewer 混合 QoS congestion + viewer suspend | `video_qos/tests/viewer_fps.rs` | viewer1 QoS 自适应降到 10，viewer2 explicit_fps=1 → 各自独立生效 |

### 7.2 集成测试（双机 .165/.167）

| 场景 | 操作 | 预期 |
|---|---|---|
| Desktop 最小化 → 恢复 | 最小化 RustDesk 窗口 30s → 恢复 | 这 30s 内 viewer 收到 0 帧（或 30 帧当保活），恢复后立即正常 |
| Mobile 后台 → 前台 | App 切后台 30s → 回前台 | 同 |
| Alt+Tab 失焦 1min | 切换到其他窗口 1min | viewer 接收 ~5fps |
| 空闲挂起 | 鼠标不动 120s → 移动鼠标 | 进入挂起 → 恢复平滑 |
| 闪断恢复（< 30s） | `iptables -I OUTPUT -p tcp --dport 21118 -j DROP` 10s 后删 | 客户端不弹重连 UI，自动恢复；服务端 encoder 不重建（可通过 md5 / pid 验证） |
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
| Viewer suspend 影响其他 viewer | VideoService 错误地把 explicit_fps 纳入 encoder fps 计算 | explicit_fps 只参与 per-subscriber drop，不参与 QoS 全局 fps；单元测试覆盖 |
| 恢复体验差（黑屏直到下一个 I 帧） | encoder keyframe refresh 间隔长 | 加「恢复时强制 I 帧」功能作为 follow-up；简化方案先不测 |
| ServiceTmpl<VideoSubscriber> 替换 GenericService 后破坏 audio/clipboard | 如果 video_service 里 audio/clipboard 也用了 VideoSubscriber | VideoSubscriber 只在 `send_video_frame_shared` 里用；audio/clipboard 继续走 ConnInner |
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
