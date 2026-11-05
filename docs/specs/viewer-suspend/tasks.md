# Viewer Suspend 本地双实例集成测试 — 任务清单

> 关联规格：[spec.md](./spec.md)（§7 验证计划、§8 风险与退化面、§10 实施记录）
> 本文件是执行清单：本地 hbbs/hbbr + 单宿主机双实例，替代 spec §7.2 的 .165/.167 双机环境。

## 1. 目标与范围

用自建 hbbs/hbbr 打通两个 RustDesk 实例的完整会话，然后按 spec §7.2 验证 Phase 5。
本文件同时记录已经验证可行的环境事实、一个必须先修的回归缺陷、以及当前二进制无法覆盖的部分。

## 2. 已确认的环境事实

| 项 | 结论 |
|---|---|
| hbbs | 源码已编译：`/home/portion/rustdesk-server/target/release/hbbs`；`hbbs -p 21116` 监听 tcp/udp 21116、tcp 21115、ws 21118。公钥 `BrNjs3ETbiqJ+3YhXac+3vX8M0JE6O6IkN4PUr0e7e8=` |
| hbbr | 容器内 `cargo build --bin hbbr` 失败（依赖 revision 缺失 + SSL error），**未产出**；直连打洞成功的情况下不是必需 |
| 客户端二进制 | `/home/portion/rustdesk/target-bullseye/release/rustdesk`（Sciter UI），同目录自带 `libsciter-gtk.so`；**未启用 `inline` 资源**，运行时从 `<exe目录>/src/ui/*.html|.tis|.css` 读盘 |
| 可写运行目录 | 容器内 `cp rustdesk libsciter-gtk.so` 到 `/opt/rd2/`，`docker cp src/ui rd-b:/opt/rd2/src/ui`；只读挂载的 `/opt/rd` 会让 Sciter 报 `failed to load ".../remote.html"` |
| X11 | 容器内自起 Xvfb 失败；必须宿主起 `Xvfb` + 容器 `--network host` + `DISPLAY=:99`（`:99` → TCP 6099）；DAMAGE / XFIXES / XTEST 均可用 |
| 配置路径 | **`$HOME/.config/rustdesk/`（全小写）**：`RustDesk.toml`（id / password）与 `RustDesk2.toml`（`[options]`）；写成 `RustDesk`（大写）不生效，实例会回落到 `rs-ny.rustdesk.com` 并生成随机 id |
| 日志路径 | `$HOME/.local/share/logs/RustDesk/rustdesk_rCURRENT.log`；`--connect` 一侧写在 `logs/RustDesk/connect/` 子目录 |
| `--noinstall` | 服务端实例需要（跳过安装检查）；**它会清空后续参数**，所以 `--connect` 那一侧不能带 |
| `--password` / `--option` | 走已安装环境的 IPC，容器内未安装不可用；密码改写 `RustDesk.toml` 的 `password`（明文可被接受） |
| 宿主工具 | `xdotool` / `xwd` / `xsetroot` / `xeyes` / `tcpdump` 可用；`convert`、`ffmpeg` 不可用，系统 Pillow 缺 `_imaging` 无法转图 |

**阻塞项**：挂起信号（`session_set_custom_fps`）与增量重连 UI 都在 Flutter Dart
（`flutter/lib/desktop/pages/remote_page.dart`、`flutter/lib/models/model.dart`）；
宿主机没有 Flutter SDK，Sciter 构建不包含这两块。因此 §5 的 B/C 阶段无法用当前
Sciter 二进制端到端验证，只有 A 阶段（连通性）与 Rust 服务端行为可验证。

## 3. 环境拓扑

```
宿主
├─ Xvfb :99  (TCP 6099) ── 容器 A（被控），HOME=/tmp/rd-hbbs/home-a
├─ Xvfb :100 (TCP 6100) ── 容器 B（控制），HOME=/tmp/rd-hbbs/home-b
├─ hbbs  tcp/udp 21116, tcp 21115, ws 21118   (cwd /tmp/rd-hbbs/data)
└─ hbbr  tcp 21117                            (cwd /tmp/rd-hbbs/data)
```

两个实例分开容器是为了隔离 `/tmp/RustDesk-0/ipc` 与日志；两条 X display 是为了让
“被控屏幕”只包含 A 自己的窗口，避免把 B 的窗口也采集进去。

## 4. A 阶段：打通本地 hbbs 双实例（可立即执行）

### A1 启动两条 Xvfb（宿主）

- [x] 两条 Xvfb 在 LISTEN（`:99` → TCP 6099，`:100` → TCP 6100）

```bash
nohup Xvfb :99  -screen 0 1280x720x24 -listen tcp -ac > /tmp/rd-hbbs/xvfb-99.log  2>&1 &
nohup Xvfb :100 -screen 0 1280x720x24 -listen tcp -ac > /tmp/rd-hbbs/xvfb-100.log 2>&1 &
ss -tlnp | grep -E '6099|6100'      # 验收：两条都在 LISTEN
```

### A2 启动 hbbs（宿主，cwd 固定）

- [x] hbbs 监听 tcp/udp 21116、tcp 21115、ws 21118；公钥已记录

```bash
mkdir -p /tmp/rd-hbbs/data
cd /tmp/rd-hbbs/data
nohup /home/portion/rustdesk-server/target/release/hbbs -p 21116 > /tmp/rd-hbbs/hbbs.log 2>&1 &
cat /tmp/rd-hbbs/data/id_ed25519.pub    # 验收：输出 base64 公钥，记作 <HBBS_KEY>
```

### A3 编译并启动 hbbr（兜底 relay）— 阻塞，非必需

- [ ] hbbr 未产出（`rustdesk-server` 依赖拉取失败：`revision 83db9ec... not found` + `SSL error`）
- [x] 双实例直连打洞成功，因此本轮不依赖 hbbr；只需在需要 relay 兜底的场景再补

```bash
docker run --rm --entrypoint bash -e VCPKG_ROOT=/vcpkg -e VCPKG_FORCE_SYSTEM_BINARIES=1 \
  -v /home/portion/rustdesk-server:/src -w /src rustdesk-builder-bullseye:latest \
  -lc 'cargo build --bin hbbr --release'
cd /tmp/rd-hbbs/data
nohup /home/portion/rustdesk-server/target/release/hbbr -p 21117 > /tmp/rd-hbbs/hbbr.log 2>&1 &
```

### A4 预写两个实例的配置

- [x] 两个实例的 id / password / rendezvous / relay / key 均生效（hbbs 日志有 `update_pk 111111111`、`update_pk 222222222`）

**目录必须是 `$HOME/.config/rustdesk/`（小写）。**

`/tmp/rd-hbbs/home-a/.config/rustdesk/RustDesk.toml`：

```toml
id = '111111111'
password = 'rdtest123'
```

`/tmp/rd-hbbs/home-a/.config/rustdesk/RustDesk2.toml`：

```toml
[options]
custom-rendezvous-server = "127.0.0.1"
relay-server = "127.0.0.1"
key = "<HBBS_KEY>"
```

`/tmp/rd-hbbs/home-b/.config/rustdesk/RustDesk.toml`：

```toml
id = '222222222'
```

`/tmp/rd-hbbs/home-b/.config/rustdesk/RustDesk2.toml`：同上（同一份 `[options]`）。

固定 ID 让脚本无需解析日志；`key` 显式写入避免 UI 弹“服务器密钥变更”确认框。

### A5 起两个容器

- [x] `rd-a` / `rd-b` 以 `--network host` 运行，`DISPLAY=:99` / `:100`，`HOME=/root` 挂载各自目录
- [x] `rd-b` 使用可写副本 `/opt/rd2`（二进制 + `libsciter-gtk.so` + `src/ui` 资源）

```bash
for n in a b; do
  docker run -d --name rd-$n --network host --entrypoint bash \
    -e DISPLAY=:$([ $n = a ] && echo 99 || echo 100) -e HOME=/root \
    -v /tmp/rd-hbbs/home-$n:/root \
    -v /home/portion/rustdesk/target-bullseye/release:/opt/rd:ro \
    rustdesk-builder-bullseye:latest -c 'sleep infinity'
done
# Sciter 资源不在二进制里，必须给 connect 一侧一个可写目录
docker exec rd-b bash -lc 'mkdir -p /opt/rd2 && cp /opt/rd/rustdesk /opt/rd/libsciter-gtk.so /opt/rd2/'
docker cp /home/portion/rustdesk/src/ui rd-b:/opt/rd2/src/ui
```

### A6 启动两个实例

- [x] A 注册到本地 hbbs，日志为 `start rendezvous mediator of 127.0.0.1`（不是 `rs-ny.rustdesk.com`）
- [x] `ss -tunp` 有两条到 `127.0.0.1:21116` 的会话

```bash
docker exec -d rd-a bash -lc 'cd /opt/rd && ./rustdesk --noinstall'
sleep 8
docker exec -d rd-b bash -lc 'cd /opt/rd2 && ./rustdesk --noinstall'
```

验收（全部满足才继续）：

1. `/tmp/rd-hbbs/hbbs.log` 出现 111111111、222222222 的注册（`update_pk`）；
2. `rd-a` 日志 `~/.local/share/logs/RustDesk/*.log` 出现
   `start rendezvous mediator of 127.0.0.1`（不是 `rs-ny.rustdesk.com`）；
3. `ss -tnp | grep 21116` 能看到两条到 127.0.0.1:21116 的连接（或 UDP 端口）。

### A7 B 发起连接

- [x] B 日志 `TCP Hole Punched 111111111 = 127.0.0.1:36005`；A 日志 `#1819 Connection opened from 127.0.0.1:40509`
- [x] 会话 `127.0.0.1:36005 ↔ 127.0.0.1:40509` ESTAB；B 收到 PeerInfo（1280x720）
- [x] A 创建 `AOM` 编码器（1280x720），B 创建 AV1 decoder 并 `[video] VIDEO_STARTED`
- [x] 视频帧确实在传：把 `:99` 整屏由白切黑后，会话 socket `bytes_sent` 从 9888 → 18552（+8.6 KB）；
  小幅改动（指针/小窗口动画）只产生几十字节，是 Phase 3.1.6 小改动节流 + 静态画面低帧率的预期结果
- [x] 备注：Sciter 用 GL 渲染视频区，`xwd -id <B窗口>` 抓不到画面内容（白切黑前后 md5 不变），
  因此只能以上述字节计数、而不能用截图判定

```bash
docker exec -d rd-b bash -lc 'cd /opt/rd2 && ./rustdesk --connect 111111111'
# 密码框由 xdotool 输入（Sciter 无 --password 连接参数）
sleep 50                      # 窗口起来后才好聚焦，太早会输入到空 window
DISPLAY=:100 xdotool search --name rustdesk windowfocus
DISPLAY=:100 xdotool type 'rdtest123'
DISPLAY=:100 xdotool key --clearmodifiers Return
```

### A8 基线计量（已测，但只说明管线不是静默）

- [x] 静态 8s：`bytes_sent` +192 B（≈24 B/s，TestDelay + 光标消息）
- [x] 连续整屏换色 8 次 / 9.6s：`bytes_sent` +240 B（≈25 B/s）；单次全屏白→黑引发首帧（keyframe）时是 +8.6 KB
- [x] 有意义的视频带宽基线：Xvfb 纯色画面经 AV1 增量编码后只有几十字节/帧，改用随机 XBM
  高熵图案（`/tmp/rd-hbbs/noise1.xbm` / `noise2.xbm`，1280x720，`xsetroot -bitmap` 交替）
  后，前台 10s 发送 1,039,175 B；与挂起后 10s +198 B 形成有效对比（见 §5.4）
- [x] 计量方式：直接读会话 socket 的 `bytes_sent`（`ss -tni`），比 `tcpdump -c N` 稳定
  （后者在未达包数时会被 `timeout` 掐断而无输出）

```bash
# 计量模板：读两次 socket 计数，差值即窗口内发送量
ss -tni | grep -A1 '127.0.0.1:36005' | grep -o 'bytes_sent:[0-9]*' | head -n1
# 拟真刺激：装上带画面的应用（如 xterm + 滚动输出）后再测
```

**A 阶段结论**：双实例经本地 hbbs 直连打洞、密码认证、PeerInfo、编码器/解码器均已打通；
会话 socket 的 `bytes_sent` 在静态 Xvfb 桌面上几乎不增长（QoS 把静态画面压到极低帧率），
属于预期行为，不阻塞 A 阶段验收。

## 5. B/C 阶段：挂起/恢复与断链重连（走 B1：Flutter bundle）

| 场景（spec §7.2） | 验证方式 | 判定依据 |
|---|---|---|
| 最小化 / 失焦 / 后台 → 0 帧 | B1：实际操作 Flutter 窗口 | 挂起窗口内被控端会话 `bytes_sent` 只增 TestDelay（≈24 B/s） |
| 空闲 120s 挂起 / 移动鼠标恢复 | B1 | 同上 |
| 恢复强制 I 帧 | B1 + 服务端日志 | 恢复瞬间 `bytes_sent` 出现数 KB 突发；`FORCE_KEYFRAME` 被消费 |
| 闪断 <30s 静默重连 | B1 | 不弹 "Connection Error"，会话恢复（encoder 按连接重建，见 §5.7） |
| 断链 >30s 弹框 | B1 | 弹框出现 |
| 关闭开关零回归 | B1（`enable-viewer-suspend=false`） | 最小化后仍有帧，字节曲线与开挂起前一致 |

### 5.1 构建环境（已就绪）

- Flutter 3.24.5 / Dart 3.5.4（`/home/portion/tools/flutter`），与 CI `FLUTTER_VERSION` 同版本。
- `flutter pub get` 成功，`Changed 197 dependencies!`：`github.com` 直连超时，但
  `url.git@github.com:.insteadOf` 改写 + GitHub SSH 认证可用，git 依赖全部解析成功。
- `cargo build --lib --features flutter` 在 builder 容器内成功，`target/debug/liblibrustdesk.so`
  520 MB（含本方案改动）。

### 5.2 阻塞点（2026-11-05 已定位，可修复）

`flutter build bundle --debug` 的首个 kernel 错误：

```
lib/models/model.dart:1007:15: Error: The method 'sessionCanIncrementalReconnectSync'
isn't defined for the class 'RustdeskImpl'.
```

原因：`src/flutter_ffi.rs` 已新增 `session_can_incremental_reconnect_sync`（同步
`SyncReturn<bool>`）且 `model.dart` 已调用，但 codegen 产物
（`flutter/lib/generated_bridge.dart`、`src/bridge_generated.rs`、`src/bridge_generated.io.rs`，
均 gitignored，本地停留在 11-02 21:54）没有对应桥接代码。

按 AGENTS.md（本地不跑 `flutter_rust_bridge_codegen`，新增 FFI 手写 Dart 包装）需补三处：

1. `src/bridge_generated.rs`：在现有 `*_impl` 区块新增
   `wire_session_can_incremental_reconnect_sync_impl(session_id: impl Wire2Api<Uuid>, buffer_sec: impl Wire2Api<u64>)`，
   用 `FLUTTER_RUST_BRIDGE_HANDLER.wrap_sync(WrapInfo { debug_name: "session_can_incremental_reconnect_sync", port: None, mode: FfiCallMode::Sync }, ...)`
   调用 `session_can_incremental_reconnect_sync(...)`。
2. `src/bridge_generated.io.rs`：新增
   `#[no_mangle] pub extern "C" fn wire_session_can_incremental_reconnect_sync(session_id: *mut wire_uint_8_list, buffer_sec: u64) -> support::WireSyncReturn`。
3. `flutter/lib/generated_bridge.dart`（照 `sessionGetEnableTrustedDevices` 的生成模式）：
   - `abstract class Rustdesk` 增加
     `bool sessionCanIncrementalReconnectSync({required UuidValue sessionId, required int bufferSec, dynamic hint});`
     与 `kSessionCanIncrementalReconnectSyncConstMeta`；
   - `RustdeskImpl` 用 `_platform.api2wire_Uuid` + `_platform.executeSync(FlutterRustBridgeSyncTask(... parseSuccessData: _wire2api_bool ...))`；
   - `RustdeskWire` 增加 `_lookup` / `asFunction` / 公有方法
     `wire_session_can_incremental_reconnect_sync`。

验收：

- [x] `nm -D target/debug/liblibrustdesk.so | grep wire_session_can_incremental_reconnect_sync` 有符号
- [x] `flutter build bundle --debug` 无 kernel 错误
- [x] `flutter build linux --debug` 产出 `flutter/build/linux/x64/debug/bundle/`（B 侧以该 bundle 运行）

> 补充：一次容器内 `flutter build linux` 曾在 `generated_bridge.dart` 与 `lib/native/win32.dart`
> 报 `invalid-type`（`WireSyncReturn` / `win32.OSVERSIONINFOEX`），宿主 `flutter build bundle`
> 未复现。补完桥接代码后先复核；若仍出现，按 §5.3 的降级路径处理。

### 5.3 构建失败时的降级路径（不改仓库代码）

- 只在宿主跑 Dart 侧：`flutter build bundle --debug`（不依赖 CMake/GTK）。
- 真实会话的挂起/恢复计量：临时（**不提交**，验证后 `git checkout` 恢复）在 viewer 侧按
  时间线注入 `custom_fps=2` → `-1`，测被控端会话 `bytes_sent` 的三段斜率，用于证明
  「挂起 0 帧 / 恢复 keyframe」；这只是 B1 的替代证据，不替代窗口事件触发。

### 5.4 本轮 A 阶段实测（Sciter 被控端 + 真实帧流）

- [x] A 容器改为 `--ipc host`：容器与宿主 IPC namespace 隔离会让 MIT-SHM 抓屏失效
      （`xcb_shm_get_image` 恒返回同一缓冲 → `would_block_if_equal` 永远 WouldBlock → 只发首帧）。
      同命名空间后 A 立即恢复发帧，噪声刺激 10s 发送 448 KB。
- [x] 基线：静态 10s +220 B；前台 + 25 次整屏高熵翻转 10s +448,392 B。
- [x] 空闲挂起（首次）：`custom_fps: 1` 后 10s 噪声仅 +110 B。
- [x] 恢复：`custom_fps: -1` 后 3s +66 B（静态画面无突发，见 §10.5 已知限制）。
- [x] 发现 P0：空闲挂起发出 `custom_fps: 1` 后约 170ms，客户端 `fps_control` 自动下发
      `custom_fps: 30`，服务端 `>=5` 分支清除了挂起，随后 5s 噪声发送 +257,775 B。
      **空闲挂起当前无法保持**。

### 5.5 两个根因缺陷与修复（重测前必须完成）

1. **服务端 `>=5` 分支不应代表 viewer 重新可见**
   - 位置：[src/server/connection.rs](../../../src/server/connection.rs) `custom_fps` 分支。
   - 机制：`fps_control` 周期性发送 `custom_fps: auto_fps(>=5)`；服务端 `>=5` 分支发现该
     viewer 有 `explicit_fps` 就清除挂起并置 `FORCE_KEYFRAME`，空闲挂起会被自动帧率取消。
   - 修复：`>=5` 只更新 `user_custom_fps`，不再清除 `explicit_fps`；恢复只由 `custom_fps < 0` 触发。
   - [x] 代码已改
   - [x] `cargo check -p rustdesk --lib --features flutter` 通过
2. **`_markInput` 排除 `suspended`，最小化 / 后台恢复不会恢复视频**
   - 位置：`flutter/lib/desktop/pages/remote_page.dart`、`flutter/lib/mobile/pages/remote_page.dart`。
   - 机制：窗口恢复、`AppLifecycleState.resumed` 都会调用 `_markInput()`，但该函数在
     `suspended` 状态下不回到 `foreground`，因此不会发送 `custom_fps: -1`。
   - 修复：去掉 `&& _viewerActivity != ViewerActivity.suspended`，任何真实输入 / 恢复事件
     都把活动态拉回 `foreground`。
   - [x] 代码已改
   - [x] `flutter build bundle --debug` 通过

### 5.6 复测清单（修复后）

- [x] 空闲 120s → 噪声 10s 仅 +~100–220 B，且日志不再出现 `custom_fps: 30` 覆盖挂起
      （实测：登录 17:22:18 → 17:24:18 发出 `custom_fps: 1`；之后无 `custom_fps: 30`
      清挂起；10s 高熵噪声仅 +198 B）
- [x] 挂起期间改变画面 → 鼠标恢复 → 出现数 KB I 帧突发且画面更新
      （实测：`custom_fps: -1` 后 3.2s 噪声 +203,721 B，恢复即恢复发帧。
      强制 I 帧由 `handle_one_frame` 的 `force_kf` 路径保证，socket 计数无法区分 I/P 帧）
- [x] 闪断 <30s 静默重连；断链 >30s 弹框
      （<30s：`ss -K` 杀会话后 B 1s 内重新打洞、无弹框；>30s：冻结 A 端进程 30s 以上，
      B 先做 2 次静默重连（17:39:36 / 17:39:37），随后离线自动重试至 30s 上限
      （17:40:07）耗尽，之后 44s 无任何重连尝试 = 弹框停留等待用户）
- [x] `enable-viewer-suspend=false` 零回归
      （最小化后 **未** 发送 `custom_fps: 1`；5s 噪声 +299,971 B，与开关开启前基线
      329,328 B 同量级）

### 5.7 本轮遗留结论

1. **闪断重连必然重建 encoder**：`video_service::new`（`src/server/connection.rs` 的
   `add_service` 调用点）按连接创建 encoder，新 socket 就是新 service。`SessionKey`
   会被复用（同一 `session_id`），但 encoder 不会跨连接保留。原清单里“encoder 未重建”
   不是本方案能达到的目标，记为已知限制，不改服务端布局。
2. **服务端 session 在唯一 remote 连接关闭时立即删除**：`check_remove_session`
   （[src/server/connection.rs](../../../src/server/connection.rs) `if is_remote || !another_remote`
   分支）不保留 30s buffer；`HIBERNATE_TIMEOUT` 只作用于 service 线程的错误退避。
   与规格“客户端 30s 静默重连窗口”并不冲突：服务端只需接受同一 `session_key` 的新登录，
   恢复延迟实测 <1s。
3. **强制 I 帧不可从 socket 观测**：无对应日志，只能由代码路径与恢复后字节突增间接验证。

## 6. P0 前置缺陷（必须在 B 阶段之前修复）

**自动 fps 可能落入 1..4，被服务端当成“挂起”，导致 viewer 永久冻结。**

- 位置：`src/client/io_loop.rs` `fps_control()`（约 1543–1639 行）。
- 机制：`limited_fps = min_decode_fps * 4/5`（direct 为 `*9/10`），解码 fps 低于约 7 时
  结果可能为 1..4，并被 `auto_fps` 直接通过 `OptionMessage.custom_fps` 发给被控端。
- 服务端语义：`src/server/connection.rs` 把 `custom_fps` 1..=4 解释为挂起
  （`VideoQoS::user_explicit_fps(id, fps)`），`send_video_frame_to_subscribers` 对
  `user_fps_target > 0` 的订阅者**一帧不发**——于是弱机 viewer 一旦自动降到 4fps，
    就再也收不到帧、`inactive_counter` 超阈值后不再调整 fps，形成永久冻结。
- [x] 修复（最小 diff）：发送前把 `auto_fps` 钳到 `>= 5`（低于 5 的自动档位在新语义下没有
  合法含义）
- [x] 回归测试：`automatic_fps_never_requests_a_suspended_viewer`，解码 5fps 时自动档位必须落在 5..=120
- [x] 验证：`cargo test --lib --features flutter`（builder 容器内，挂宿主 `~/.cargo` 离线编译）
  - `automatic_fps_never_requests_a_suspended_viewer` 通过
  - 全量 lib 测试 226 passed / 1 failed，失败项为
    `keyboard::shortcuts::tests::alt_only_shortcut_neutralizes_windows_menu`（`kbd context error`），
    与本改动无关，属该容器缺少键盘上下文的既有环境失败

## 7. 需要用户确认的三项

1. ~~是否批准立即执行 A 阶段~~ → 已执行，A 阶段验收见 §4。
2. ~~P0 缺陷是否随本次修改~~ → 已修复并加回归测试。
3. ~~B/C 用哪条路径：Flutter SDK（B1）/ 仅注入（B2）/ 暂缓（B3）~~ → 采用 **B1**：
   构建环境已就绪（Flutter 3.24.5 + pub get 成功），唯一阻塞是 codegen 产物缺
   `sessionCanIncrementalReconnectSync` 桥接，修复路径见 §5.2；降级路径见 §5.3。

## 8. 清理

```bash
docker rm -f rd-a rd-b
pkill -f '/tmp/rd-hbbs/data/hbbs'; pkill -f '/tmp/rd-hbbs/data/hbbr'
pkill -f 'Xvfb :99'; pkill -f 'Xvfb :100'
```

## 9. 回归面

- `src/client/io_loop.rs` `fps_control()` 的自动档位下限由 `1` 提到 `5`。受影响的是
  “解码 fps 低到 5–6 的 viewer”：原本会下发 2–4，现在下发 5，即弱机多收一点帧、
  不再被服务端误判为挂起；正常机器（解码 ≥ 7fps）档位不变。
- `src/server/connection.rs` `custom_fps >= 5` 分支不再清除 `explicit_fps`、不再置
  `FORCE_KEYFRAME`。仅影响“挂起中又收到 ≥5 自动档位”的 viewer：挂起不再被自动帧率
  取消。未挂起的 viewer 行为不变（`user_custom_fps` 更新逻辑保持原样）；恢复仍由
  `custom_fps < 0` 触发。
- `flutter/lib/{desktop,mobile}/pages/remote_page.dart` `_markInput()` 允许从 `suspended`
  回到 `foreground`。仅影响最小化 / 后台恢复后的首个输入或窗口事件：现在会补发
  `custom_fps: -1`；`foreground` 下无变化。
- A 阶段只新增测试环境与脚本（hbbs / 容器 / Xvfb），失败时全部可丢弃，不影响仓库代码。
