# RustDesk 传输与压缩优化方案

> 目标：对标 NoMachine NX，缩小远程桌面带宽利用率与弱网体验差距
> 负责人：powerfs 分支维护者
> 状态：方案评审中，未实施

---

## 一、现状与差距分析

### 1.1 RustDesk 当前架构

```
屏幕采集 (scrap)
    ↓ 整块像素帧 (BGRA/RGBA)
编码器 (H.264/H.265/VP9/AV1, 硬编优先 VP9 兜底)
    ↓ 原始 RTP-like 视频包
UDP 通道 (hbbs/hbbr 中继或 P2P 打洞)
    ↓ 无 FEC / 无 MTU 探测 / 粗粒度 QoS
解码 → 渲染
```

### 1.2 NoMachine NX 架构

```
屏幕采集
    ↓
NX 帧差分 (tile-based, 只输出变化矩形)
    ↓
NX 自研压缩 (有损/无损可选, 编码前二次压缩)
    ↓ (可选叠加 H.264/H.265)
FEC 编码 (Reed-Solomon)
    ↓
带宽自适应 (主动探测 + 多路径)
    ↓
UDP 传输 (MTU 探测, 防分片)
解码 + tile 还原 → 渲染
```

### 1.3 差距量化

| 维度 | RustDesk | NoMachine | 差距 | 根因 |
|---|---|---|---|---|
| 静止画面带宽 | 持续发 I/P 帧, ~5-30KB/s (VP9) | 零, 不传输 | **严重 100x** | 无帧差分预处理 |
| 小区域变化带宽 (光标/打字) | 编码整帧, ~5-20KB | 1-2 tile, <1KB | **严重 10x** | 无 tile 差分 |
| 5% 丢包体验 | 严重花屏/卡顿 | 轻微劣化流畅 | **严重** | 无视频 FEC |
| 100kbps 可用带宽 | 1-2 FPS, 低画质 | 15+ FPS 清晰 | **大** | 帧差分 + 自研压缩 |
| 动态路径 MTU | 固定, 不分片就丢 | 启动探测 | **中** | 缺 MTU 探测 |
| 色彩 4:4:4 | 依赖编码器支持 | 原生支持 | **小** | 编码器配置 |

---

## 二、优化目标

### 2.1 总目标

在不破坏现有协议兼容性的前提下（旧版本客户端仍可连接），达到：

| 指标 | 现状 | 目标 | 验证方法 |
|---|---|---|---|
| 静止画面带宽 (1080p 文档场景) | ~15 KB/s | **< 1 KB/s** | tcpdump 抓包 + 带宽统计脚本 |
| 弱网 5% 丢包体验 | 花屏卡顿 | **流畅可用** | netem 丢包模拟 |
| 100kbps 带宽下 FPS | ~2 | **≥ 10** | iperf3 限速 + FPS 统计 |
| P99 端到端延迟 (同机房) | 150ms | **< 80ms** | rr 录制回放 |

### 2.2 约束条件

1. **协议兼容**：新客户端能连旧 hbbr，旧客户端能连新 hbbr（能力协商）
2. **不开源依赖**：不引入闭源库；自研压缩层只允许使用 Rust/CLib 开源 crate
3. **跨平台一致**：Win/Mac/Linux/Android 同一份逻辑
4. **Flutter 与 Sciter 双路径**：两边 UI 都要用到传输层，改动必须在公共层

---

## 三、分阶段实施计划

### Phase 1：帧差分预处理（核心收益，预计 2-3 周）

#### 3.1.1 改动位置

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `libs/scrap/src/common/diff.rs` | **新建** | tile-based 帧差分实现 |
| `libs/scrap/src/common/mod.rs` | 修改 | 导出 diff 模块 |
| `libs/scrap/src/frame.rs` | 修改 | 采集完像素后经过 diff 再送编码器 |
| `src/server/video_service.rs` | 修改 | 编码前接收差分结果 |
| `src/server/video_protocol.rs` | 修改 | 协议增加 `VideoFrame::Diff` variant |

#### 3.1.2 算法设计

```
输入：上一帧 Frame + 当前帧 Frame
输出：Vec<DiffTile>

struct DiffTile {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: Vec<BGRA>,   // 只传变化 tile 的像素
}

算法：
1. 把屏幕切成固定大小 tile (推荐 32x32 或 64x64)
2. 逐 tile 比较 RGB 内容 (可带微小容差 1-2 灰度值, 抗锯齿/字体抗锯齿误报)
3. 收集有变化的 tile，去重（合并相邻变化 tile 成更大矩形）
4. 如果变化 tile 超过总数 50%，退化为传整帧 (避免差分开销 > 直接编码)
```

#### 3.1.3 协议扩展（向后兼容）

```rust
// src/server/video_protocol.rs

#[derive(Serialize, Deserialize)]
pub enum VideoFrame {
    Full { width: u16, height: u16, data: Vec<u8> },
    Diff { tiles: Vec<DiffTile>, full_frame_flag: bool },
}

pub struct DiffTile {
    x: u16, y: u16, w: u16, h: u16,
    data: Vec<u8>,  // BGRA 原始像素 (后续可叠加自研压缩)
}
```

客户端-服务端能力协商：

```
INIT 握手中新增字段:
  client_flags |= SUPPORTS_DIFF
  server_flags |= SUPPORTS_DIFF
双方都支持 → 启用 Diff 路径; 任一方不支持 → 退化为 Full
```

#### 3.1.4 验证方法

| 场景 | 预期 |
|---|---|
| 1080p 静止文档 | `Diff.tiles.len() == 0`，带宽 ≈ 0 |
| 光标移动 | 1-2 个小 tile，< 1KB |
| 窗口拖动 | 大部分 tile 变化 → 退化为 Full |
| 旧客户端连接新服务端 | 走 Full 路径，行为不变 |

#### 3.1.5 风险与规避

| 风险 | 概率 | 影响 | 规避 |
|---|---|---|---|
| Diff 开销 > 直接编码 | 低 (64x64 tile 在 1080p 下仅 480 次比较) | 浪费 CPU | 超过 50% tile 变化时自动退化 |
| 抗锯齿导致大量微小 tile | 中 | 带宽节省被抵消 | 灰度容差阈值 + 小 tile 合并 |
| 协议版本兼容出错 | 中 | 连接失败 | 严格按 `SUPPORTS_DIFF` 标志协商 |

#### 3.1.6 已实现状态（零协议路线）

实际落地时选择了不改协议/客户端的零侵入路线，已合并到 `feature/server-setup-prompt`：

| 文件 | 改动 |
|---|---|
| `libs/scrap/src/common/diff.rs` | **新建**。32x32 tile 灰度容差对比（±2）、`TileMask` 逐 tile 变化位图、`restore_unchanged_yuv()` 把未变化 tile 的 Y/U/V 从上一帧回填（I420 / NV12 / I444），7 个单元测试 |
| `src/server/video_service.rs` | `frame.to()` 之前做 BGRA tile diff：静止帧（`Static`）完全跳过编码与发送；小变化帧（`Partial`）转完 YUV 后按 mask 回填未变化区域再送编码器；>50% 变化自动退化原路径 |

效果与文档目标的对应关系：

| 目标 | 达成方式 |
|---|---|
| 静止画面带宽 ≈ 0 | 整帧跳过（不编码不发送） |
| 光标移动 < 1KB | 未变化 tile 回填上一帧 YUV，编码器 inter-frame 压缩自然只编变化区域 |
| 旧客户端兼容 | 协议零改动，天然兼容 |
| 协议 Diff variant（3.1.3） | **未做**。协议层 tile diff 与视频编码器自带的帧间预测高度重叠，收益有限；后续若仍需要可再加 |

遗留项：BGRA→YUV 的逐帧转换 CPU 不变（脏 buffer 发生在 YUV 层之后）；协议级 tile 压缩（Phase 4）若做仍可叠加。

##### 3.1.6.1 双机实测（2026-11-04）

环境：被控 10.176.35.165（Linux/X11，1360x768，VPX），控制 10.176.35.167，Direct IP 直连，同子网。
方法：A/B 对比（HEAD 基线 vs 本实现），tcpdump 逐场景抓包，剔除连接首屏爆发后取每秒中位数。
完整数据见 `docs/specs/two-machine-bandwidth/results.md`。

| 场景 | 基线 | 本实现 | 结论 |
|---|---|---|---|
| 静止 ×3 | 44.4 kbps（31.6–44.8） | 35.0 kbps（33.3–37.4） | 名义低 21%，但方差大于差值，**不显著** |
| 小区域 10Hz 刷新 ×2 | 44.0 kbps | 44.6 kbps | **无差异** |
| 纯光标移动 ×1 | 46.9 kbps | 46.4 kbps | **无差异** |

**负结果及原因**：X11 capturer 的 `would_block_if_equal` 已做整帧去重（静止本就零帧），
而 VPX 的 P 帧本身只编变化区域，与「未变化 tile 回填上一帧 YUV」高度重叠，因此
带宽几乎不变；同时每帧多付一次 BGRA 遍历与 YUV 快照拷贝。当前形态在
Linux/X11 + VPX 组合下投入产出比为负。

结论：该实现适用于没有等价去重/帧间预测的路径（Web JS 解码、texture 直传），
在 X11+VPX 路径单独使用时收益不显著；带宽优化优先级应转向 3.2 视频流 FEC 与降低周期性
static-refresh 关键帧开销。（该结论在 3.1.6.2 叠加发送节流后被修正：节流本身带来显著收益。）

##### 3.1.6.2 小变化动态降频（方案 A，2026-11-04）

问题：X11 下 IDE 光标闪烁、顶栏时钟这类「每帧只变几块 tile」的画面，服务端仍会每帧
编码并发送一条 `video_frame` 消息（外壳约 176B），30fps 即约 45 kbps 的无意义开销。

实现（`src/server/video_service.rs`，零协议改动）：

| 机制 | 说明 |
|---|---|
| 判定 | `DiffResult::is_small_change(divisor)`：变化 tile 数 < 总 tile 数的 1/20（5%） |
| 节流 | 距上次发送 < 200ms 则跳过编码与发送（上限 5fps），大变化不受影响 |
| 参考帧 | `prev_bgra` 只在真正发送时推进，跳过的变化累积到下一次发送一次性编码 |

双机 A/B（同一 10Hz 小区域终端场景，仅换被控二进制，按 `Message` 类型只统计
`video_frame` 出方向）：

| 版本 | 消息数 | 平均每帧 | video kbps | 总 kbps |
|---|---|---|---|---|
| 无节流 | 458（29.9 fps） | 346 B | 83.0 | 83.2 |
| 方案 A | 69（4.5 fps） | 1011 B | 36.6 | 36.7 |

结论：总流量 **−56%**，消息数 −85%；单帧变大（200ms 累积变化一次编码），因此收益小于
消息数降幅。IDE 光标闪烁场景 video 流量约 7.6 kbps（无节流同场景约 45 kbps）。
要进一步逼近 NoMachine 需要协议级 tile 矩形增量（Phase 4 / 3.1.3）。

已知限制：小变化最多引入 200ms 显示延迟（光标/打字），大范围变化（滚动、拖窗）不受影响；
每帧仍付一次 BGRA 遍历 + YUV 快照的 CPU 成本。

##### 3.1.6.3 协议级 tile 矩形增量（方案 B 探明，已证伪并回退，2026-11-05）

按 Phase 4 设想实现了协议级增量：`VideoFrame.tiles` 只携带变化 tile 矩形（XOR delta +
zstd，逐字节 <8 的死区量化清零），客户端对解码输出缓冲区直接 XOR 应用，全程绕开
编码器。机制正确性全部验证通过（大变化自动回退编码路径、断线重连经 refresh_video
自愈、远端渲染无残影无色偏），但双机 A/B 实测收益为负。

黑窗遮挡法同条件成对（被控 .165:21118 / 控制 .167，video_frame 出方向 payload）：

| 场景 | 3.1.6.2 节流（VP9） | tiles（量化 XOR） | 判定 |
|---|---|---|---|
| 静止 | 1.1 kbps（146 B/条） | 0.6 kbps（71 B/条） | tiles 胜 ~2x |
| 10Hz 小区域（时间戳终端） | 12.7 kbps（335 B/条） | 27.0 kbps（736 B/条） | tiles 劣 2.1x |
| IDE 真实桌面（agent 活跃） | 11.3 kbps（312 B/条） | 48.0 kbps（1360 B/条） | tiles 劣 4.2x |

证伪原因：文本抗锯齿边缘每拍大 delta 翻转，无损/近无损 XOR 必须传每个变化像素的
精确值（~740 B/条，死区量化仅再省 ~4%）；VP9 的有损 DCT 量化 + skip 块对同内容只需
~310 B/条。tiles 唯一胜出的近静止场景 VP9 本就只有 1.1 kbps，绝对收益 0.5 kbps 无
实际价值。结论：**X11+VP9 组合下协议级 tile 增量无收益，3.1.6.2 节流即甜点位**；
代码已整体回退（proto/协商/收发路径未保留），详细数据与协议设计存档于
`docs/specs/tile-rect-incremental/`（spec.md 三次修订记录 + results.md）。

---

### Phase 2：视频流 FEC（弱网质变，预计 2 周）

#### 3.2.1 改动位置

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `src/server/fec.rs` | **新建** | FEC 编码/解码 |
| `src/server/video_service.rs` | 修改 | 发包前加 FEC 冗余包 |
| `src/client/io_loop.rs` | 修改 | 接收时用冗余包恢复丢包 |
| `src/server/video_protocol.rs` | 修改 | 协议增加 FEC 头 |

#### 3.2.2 技术选型

| 方案 | 冗余率 | 计算量 | 说明 |
|---|---|---|---|
| **Reed-Solomon** | 10-25% 可调 | 低 | 成熟，实现简单，推荐 |
| RaptorQ | 5-20% | 中 | 更高效，但实现复杂 |
| 简单 XOR | 50% | 极低 | 只适合极低丢包场景 |

**推荐 Reed-Solomon**：每 N 个视频包生成 M 个冗余包，丢 ≤ M 个时可完全恢复。默认 N=10, M=2（冗余率 20%，抗 2 个包丢失）。

#### 3.2.3 协议扩展

```
UDP 视频包头新增:
  fec_enabled: bool,
  fec_group_id: u32,     // 同一组 FEC 包共享
  fec_packet_index: u8,  // 本组内序号
  fec_group_size: u8,    // N + M
  fec_redundancy_size: u8, // M

接收方:
  按 fec_group_id 收集本组包, 存进 FEC 解码器
  丢包数 < M → 用 Reed-Solomon 恢复
  丢包数 ≥ M → 标记帧损坏, 等下一个 keyframe
```

#### 3.2.4 验证方法

| 丢包率 | 无 FEC 体验 | 有 FEC 预期 |
|---|---|---|
| 1% | 偶发花屏 | 透明 |
| 5% | 严重卡顿 | 流畅 |
| 10% | 不可用 | 勉强可用 |

工具：`tc qdisc add dev eth0 root netem loss 5%`

---

### Phase 3：动态 MTU 探测（低投入中收益，预计 1 周）

#### 3.3.1 改动位置

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `src/rendezvous_mediator.rs` | 修改 | 连接建立阶段增加 MTU probe |
| `src/server/connection.rs` | 修改 | 用探测结果调整 UDP 包大小 |

#### 3.3.2 算法

```
1. 连接建立后发送 5 个 probe 包 (ICMP 或 UDP echo), 大小递增: 512 → 1024 → 1400 → 1472 → 1500
2. 以成功到达的最大包大小减 20 字节 (安全余量) 作为 MTU
3. 后续所有 UDP 视频包 ≤ MTU, 避免 IP 分片
4. 中继 (hbbr) 也要做 MTU 探测, 中继路径 MTU 取两端较小值
```

---

### Phase 4：自研可选压缩层（叠加在 Diff 之上，预计 3 周）

#### 3.4.1 设计

在 Diff 输出的 tile 像素之上，再加一层轻量压缩：

```
Diff tile (BGRA 原始像素)
    ↓
自研压缩 (块内自适应: 平坦块 → RLE, 纹理块 → 类 PNG deflate, 渐变块 → 差分编码)
    ↓
输出压缩后的 tile data, 比原始 BGRA 再小 5-10x
```

#### 3.4.2 改动位置

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `libs/scrap/src/common/compress.rs` | **新建** | 自研块内压缩 |
| `libs/scrap/src/common/diff.rs` | 修改 | Diff 输出时可选调用 compress |

#### 3.4.3 与 Phase 1 的关系

Phase 1 的 Diff tile data 是原始 BGRA（未压缩），Phase 4 是 **叠加优化**——先差分掉不变 tile，再对变化 tile 压缩。两者独立，Phase 4 可延后实施。

---

## 四、依赖关系与优先级

```
Phase 1 (帧差分)  ────────────────────────────── 独立, 最高优先级
    │
    ├── Phase 4 (自研压缩) ────── 依赖 1, 可并行
    │
Phase 2 (视频 FEC)  ──────────────────────────── 独立, 高优先级
    │
Phase 3 (MTU 探测)  ──────────────────────────── 独立, 低优先级
```

**建议实施顺序**：Phase 1 → Phase 2 → Phase 3 → Phase 4

---

## 五、每阶段验证清单

### Phase 1 验收

- [ ] 静止画面 (1080p) 带宽 < 1 KB/s
- [ ] 光标移动带宽 < 1 KB
- [ ] 旧客户端连接新服务端正常工作
- [ ] 新客户端连接旧服务端正常工作
- [ ] `cargo test --workspace` 全绿
- [ ] 无明显 CPU 回退（diff 耗时 < 5% 编码耗时）

### Phase 2 验收

- [ ] netem 5% 丢包下画面流畅
- [ ] netem 1% 丢包下花屏完全消失
- [ ] FEC 开启时带宽增加 ≤ 25%（冗余率可控）
- [ ] 关闭 FEC 时行为与改造前一致

### Phase 3 验收

- [ ] MTU 探测在典型路径上能正确发现值 (通常 1400-1472)
- [ ] 分片场景下丢包率明显降低
- [ ] 探测阶段不超过 5 秒

### 阶段间回归

- [ ] `cargo test --workspace` 全绿
- [ ] Linux bullseye Docker release 构建成功
- [ ] 无 bridge 配置可正常运行（Sciter inline 版）
- [ ] 连接自建 VPS hbbr/hbbr 正常

---

## 六、性能评估方法

### 6.1 带宽测量

```sh
# 场景：1080p 桌面静止 10 秒
tcpdump -i eth0 port 21116 -w capture.pcap &
# 录制期间客户端做以下操作...
tshark -r capture.pcap -T fields -e frame.len | awk '{s+=$1} END {print "总字节:", s, "平均:", s/10, "字节/秒"}'
```

### 6.2 FPS 与画质

- FPS：`grep -i fps rustdesk.log` 或直接看客户端状态栏
- 画质：Subjective MOS 评分（1-5）或 PSNR/SSIM 指标
- 工具：`ffmpeg -i input.mp4 output.png` 抽帧对比

### 6.3 弱网模拟

```sh
# 5% 丢包 + 150ms 延迟 (模拟跨洋 VPS)
tc qdisc add dev eth0 root netem loss 5% delay 150ms

# 1% 丢包 (模拟局域网轻微干扰)
tc qdisc add dev eth0 root netem loss 1%

# 100kbps 限速 (模拟拨号)
tc qdisc add dev eth0 root tbf rate 100kbit burst 32kbit latency 400ms
```

---

## 七、不在本次范围内的项

| 项目 | 说明 |
|---|---|
| 音频压缩优化 | Opus 已够用，暂不处理 |
| 硬件编码器替换 | H.264/H.265 硬编已是最优选择 |
| WebRTC 原生视频 | WebRTC 有自己的 FEC/RTP，不走 RustDesk 视频服务路径，单独优化 |
| Flutter Rust Bridge 改动 | 传输层改动不涉及 bridge |
| 新硬件编码格式 (AV1 硬编) | 依赖硬件厂商 SDK，暂不追 |
