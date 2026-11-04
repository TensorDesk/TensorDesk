# 双机带宽实测结果 — 帧差分优化（Phase 1+2）

测试日期：2026-11-04。方法见 [spec.md](spec.md)。
被控端 10.176.35.165（X11，1360x768），控制端 10.176.35.167（R760），
Direct IP 直连（21118/TCP），同子网 RTT<0.3ms。

**结论先行：** 单独的 tile-diff（Phase 1+2）稳态带宽未见显著收益；叠加「小变化动态降频」
（方案 A，Phase 3）后，10Hz 小区域刷新场景总流量由 83.2 kbps 降到 36.7 kbps（−56%），
IDE 光标闪烁场景 video 流量约 7.6 kbps。详见「结论与原因」与「Phase 3」。

## 场景定义

- **static**：已连接静置（屏幕仅有 IDE 静态文本、编辑器光标闪烁、顶栏分钟时钟）。
- **small-region**：50x4 字符终端以 10Hz 刷新单行时间戳（约 400x20px、~13 个 tile 变化）。
- **cursor-only**：xdotool 以 10Hz 在 40x30px 范围内移动鼠标（X11 抓帧不含光标精灵，
  只产生 cursor-data 消息）。

## 计量口径

每次抓包约 15.3s，统计 `.165↔.167` 全部 TCP payload。剔除连接初期首屏爆发
（单秒 >20KB 的秒），再取每秒字节数的中位数，换算 kbps。

## 稳态数据

| 场景 | baseline (kbps) | optimized (kbps) | 差异 |
|---|---|---|---|
| static ×3 | 31.6 / 44.8 / 44.4（中位 44.4） | 37.4 / 33.3 / 35.0（中位 35.0） | 优化版名义低 ~21%，但两组区间重叠、方差 > 差值，**不显著** |
| small-region ×2 | 47.4 / 40.6（中位 44.0） | 46.2 / 43.1（中位 44.6） | +1%，**无差异** |
| cursor-only ×1 | 46.9 | 46.4 | −1%，**无差异** |

原始总量（含连接初期首屏，供参考）：

| 跑次 | 文件 | 总量 | 平均 kbps |
|---|---|---|---|
| opt static #1 | cap-opt-static.pcap | 83.9KB/15.3s | 43.8 |
| opt static #2 | cap-opt-static2.pcap | 65.4KB/15.3s | 34.1 |
| opt static #3 | cap-opt-static3.pcap | 67.9KB/15.3s | 35.4 |
| base static #1 | cap-base-static.pcap | 61.6KB/15.3s | 32.3 |
| base static #2 | cap-base-static2.pcap | 91.0KB/15.3s | 47.5 |
| base static #3 | cap-base-static3.pcap | 90.7KB/15.3s | 47.5 |
| opt small #1/#2 | cap-opt-small{,2}.pcap | 89.2 / 82.7KB | 46.6 / 43.3 |
| base small #1/#2 | cap-base-small{,2}.pcap | 236.1 / 79.2KB | 123.5 / 41.4 |
| opt cursor | cap-opt-cursor.pcap | 90.2KB | 47.1 |
| base cursor | cap-base-cursor.pcap | 91.5KB | 47.7 |

`base small #1` 的 123.5 kbps 是污染样本：抓包起点距连接仅 3s，首两秒含 115KB+41KB
首屏全帧与关键帧，剔除后稳态 47.4 kbps，与 `#2` 一致。这也说明单次抓包若贴近连接时刻
会严重失真——后续复测都在连接稳定后再开始。

## 结论与原因

1. **X11 侧已有整帧去重**：`would_block_if_equal` 在帧字节完全相同时返回 `WouldBlock`，
   video_service 直接跳过编码。Phase 1 的「静止零带宽」在这条路径上原本就已成立，
   tile 灰度容差（±2）只多过滤掉亚像素抖动，收益微小。
2. **VPX 的 P 帧本就只编变化区域**：Phase 2 把未变化 tile 回填上一帧 YUV，与编码器内部
   的帧间预测/运动估计高度重叠，编码输出几乎不再缩小。small-region 场景每秒 ~5.5–6.0KB
   在两版本上一致，正是这个重叠的直接证据。
3. **优化版每帧多付 CPU**：一次 BGRA 遍历 + 一次 YUV 快照拷贝（1360x768 约 1.5MB/帧）。
   带宽没降而 CPU 上升，当前形态的投入产出比为负。
4. 两版本共有的 ~45 kbps「底噪」并非协议固定开销，而是**画面微小变化驱动的空帧消息**：
   出方向严格 30fps（包间隔 33.3ms），每帧一条明文 protobuf `video_frame` 消息、约 110–150B，
   其中编码数据长度为 0。IDE 文本光标闪烁、顶栏时钟等肉眼几乎忽略的变化，让 X11 capturer
   的整帧字节比较每帧都判「新帧」，服务端于是每帧编码并发送消息，而 AV1 在几乎无变化时输出为空。
   实验验证：用静态黑窗遮住主区域后，同一条连接流量从 45 kbps 降到 **0.1 kbps**（14s 共 45 包 / 0.2KB），
   证明「完全静止时确实几乎不发帧」，也证明 tile-diff 的 `Static` 判定有效。


## Phase 3：小变化动态降频（方案 A）实测

在 tile-diff 之上加一条发送节流：变化 tile 数 < 5% 且距上次发送 < 200ms 时跳过编码与发送，
参考帧（`prev_bgra`）只在真正发送时推进，跳过的变化累积到下一次发送一次性编码。
实现见 `video_service.rs`（`SMALL_CHANGE_TILE_DIVISOR = 20`、`small_change_min_interval = 200ms`）。

### A/B（同一场景、同一控制端、仅换被控二进制）

场景：50x4 终端单行时间戳 10Hz 刷新（与上面 small-region 相同）。抓包 15s，按 `Message`
类型拆分统计（本节只算 `video_frame` 出方向，排除 `TestDelay`/音频/ACK）。

| 版本 | video 消息数 | 平均每帧 | video 字节 | video kbps | 总 kbps |
|---|---|---|---|---|---|
| optimized（无节流） | 458（29.9 fps） | 346 B | 158,398 B | 83.0 | 83.2 |
| throttle（方案 A） | 69（4.5 fps） | 1011 B | 69,752 B | 36.6 | 36.7 |

结论：**总流量 −56%，消息数 −85%**。代价是每帧平均从 346B 涨到 1011B（200ms 内累积的
变化一次编码），所以收益小于消息数的降幅；要再降只能改协议做 tile 矩形增量（Phase 4）。

### IDE 光标闪烁场景（定性）

同一实现，IDE 编辑器光标闪烁 + 顶栏时钟场景，14s 抓包：`video_frame` 仅 11 条 / 13,235B
= **7.6 kbps**；无节流版本同场景约 45 kbps。发送间隔在活跃期约 220ms，正是节流窗口。

### 抓包侧的两个新发现

1. 之前统计里的「8 字节小包」有两个来源，都不是视频：`TestDelay` QoS 探针（服务端 1/s，
   客户端原样回显）和 `audio_frame`。所有报文前 1 字节是 `BytesCodec` 的长度头
   （`len<<2`，≤0x3F 时 1 字节），不是多余数据。
2. IDE 那次抓包期间客户端中途启用了音频：869 条 `audio_frame`（19.2KB，含每 2s 约 205 条
   3 字节静音帧的突发）。这是音频服务的发包节拍问题，与视频节流无关，本次不改；
   此前的 baseline/opt 抓包里没有音频帧。

## 建议的下一步（不在本次范围）

- 单独的 tile-diff 在 Linux/X11 + VPX 上收益不显著（见上），但叠加方案 A 的发送节流后
  该路径已有可观测收益（−56%），因此节流应保留；要让 diff 单独产生收益仍需协议级
  tile 矩形增量（Phase 4）。
- 若目标是带宽，优先级应转向 `docs/OPTIMIZE_TRANSPORT.md` 的 Phase 2（视频流 FEC，
  解决弱网丢包）与降低周期性关键帧/static-refresh 的开销。
- 若要保留 tile-diff，应先补 CPU 成本测量，并把回填路径限制在「编码器无帧间参考」
  的场景，避免与编码器重复工作。

## 偏离与备注

- baseline 构建：`git stash` + 复用 `target-bullseye` 增量缓存（`git worktree` 缺
  gitignored 的 `src/ui/inline.rs`，不可用）。首次构建因 cargo 在线拉取
  `chromium.googlesource.com/webm/libwebm` 失败，改为挂载宿主 `~/.cargo/git` 缓存后成功
  （镜像内无 crates.io 索引，`--offline` 不可用）。构建 6m50s，md5 `369ea93d…`；
  优化版 md5 `3287d049…`。
- baseline 二进制内嵌 Sciter 资源与优化版相同（`inline.rs` 未随 stash 重新生成），
  屏幕渲染条件对等，视频编码路径不受影响。
- tcpdump 必须用 `sudo -n timeout --signal=TERM 16 tcpdump …`：`timeout sudo tcpdump`
  只杀 sudo，tcpdump 子进程继续写文件，首次 static 抓包因此作废重抓。
- 测量期间 ufw 临时放行 `.167 → 21118/tcp`（INPUT 默认 DROP）。
- 抓包文件在 `/tmp/cap-*.pcap`，逐包文本在 `/tmp/{opt,base}-*.txt`，二进制备份在
  `/tmp/rd-bench/`。

