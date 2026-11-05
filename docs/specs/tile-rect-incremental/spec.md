# Phase 4：协议级 tile 矩形增量更新（3.1.3 落地）

> 状态：**已终止（2026-11-05）**——机制实现并验证通过，但双机实测收益为负
> （活跃小变化场景劣于 VP9 编码路径 2-4 倍，详见 results.md），代码已整体回退，
> 本文档与 results.md 仅作存档。
> 前置：Phase 1（tile diff）、3.1.6.2（小变化节流）已合并
> 目标场景：IDE 光标闪烁、时钟、终端小区域刷新等「每帧只变几块 tile」的画面

> **修订（2026-11-05，T8 实测驱动）**：初版 data 承载原始 BGRA 像素 + zstd，
> 实测 10Hz 小区域场景 video 流量 114.3 kbps，反而劣于编码路径的 36.6 kbps
> （抗锯齿文本的原始像素对 zstd 不友好，实测压缩率仅 ~0.10，而 VP9 帧间编码
> 对同一变化只需 ~1KB）。**修订为 XOR 增量**：data 承载与上一发送帧的逐字节
> XOR（未变化像素为 0，zstd 对长零段压缩极佳），客户端对 rgb 缓冲做 XOR 应用。
> 消息格式与能力协商不变。
>
> **修订 2（同日，有损量化）**：XOR 增量实测静止 0.5 kbps（胜编码路径 2.1 kbps），
> 但 10Hz 小区域 28.0 kbps 仍劣于编码路径 11.7 kbps（字形抗锯齿边缘每拍全变，
> 无损 delta 熵约 2KB/条）。按用户决策加**有损量化死区**：逐字节 XOR < 8 的
> delta 清零（通道值变化 ≤7，不可感知），接收端保留旧值直到变化超过阈值，
> 误差有界（≤7/255）且不累积。

## 一、问题

小变化场景下服务端仍按帧编码并发送完整 `EncodedVideoFrames` 消息。3.1.6.2 节流把
消息数压到 5fps 后，单帧仍是整屏编码（实测平均 1011B/条，video ~36.7 kbps）。
要进一步逼近 NoMachine（变化区域 <1KB），必须在协议层只传变化矩形。

## 二、关键正确性论证（无需强制关键帧）

tile 矩形更新在客户端**不经过视频解码器**，直接 blit 进解码输出缓冲区
`VideoHandler.rgb`（持久 `ImageRgb`）：

- VPX 解码器内部参考帧保存在解码器内，blit 只改输出缓冲区，不污染参考帧；
- 服务端跳过编码期间，编码器参考帧 = 最后一次编码帧，与解码器参考帧一致；
- 之后大变化恢复编码时，P 帧两端参考一致，解码输出整帧覆盖 rgb，tile 痕迹被自然覆盖。

唯一需要处理：脏 YUV 回填（`restore_unchanged_yuv`）的 `prev_yuv` 对应「最后编码帧」，
tile 发送期间 `prev_bgra` 已推进而 `prev_yuv` 未动，恢复编码的第一帧若继续按
「对 prev_bgra 未变」回填，会把 tile 更新过的区域错误回退成旧内容。
对策：tile 发送后置一次性标志，下一次编码跳过 restore（仅一帧，损失可忽略）。

XOR 增量的基准一致性：服务端以无损采集帧 `prev_bgra` 为基准计算 XOR，客户端
应用在 `rgb`（编码帧经有损解码）上。大变化经编码帧后，客户端基准与 `prev_bgra`
相差一个编码误差 e；后续 tile 更新区域会带上 e 的残影，但 e 有界且不累积
（每条 delta 仍相对服务端 `prev_bgra` 计算），并在该区域下次经编码帧刷新后消失。
视觉影响限制在文本边缘等高频区域的轻微色偏，记为已知限制。

## 三、协议扩展（向后兼容）

`libs/base/protos/message.proto`（base 是普通 workspace member，可直接改；
build.rs 用 protobuf_codegen 构建期重新生成，无需外部 protoc）：

```proto
message TileRect {
  sint32 x = 1;
  sint32 y = 2;
  int32 width = 3;
  int32 height = 4;
}

message TileRects {
  bool compress = 1;          // data 是否经 hbb_common::compress(zstd) 压缩
  repeated TileRect rects = 2; // 按行合并的变化矩形，行主序
  bytes data = 3;             // 各 rect 当前帧与上一发送帧的 XOR（BGRA 序、行主序、无 padding）
}

// VideoFrame.oneof 新增：
//   TileRects tiles = 15;
// SupportedDecoding 新增：
//   bool tile_rects = 9;      // 客户端声明可处理 tile 矩形增量帧
```

兼容性：

- proto3 未知字段被忽略：旧服务端收到新客户端的 `tile_rects=true` 无影响；
- 服务端只在**所有**在线连接都声明支持时启用（复用 `PEER_DECODINGS` + `all()` 语义），
  旧客户端 / web（JS 端不声明）永远收不到 tiles 消息；
- 新增 oneof variant 会让 `CodecFormat::from(&vf)` 等对 `video_frame::Union` 的
  穷尽 match 编译报错——编译器会列出所有需要显式处理的点，逐一显式处理
  （`tiles → CodecFormat::Unknown`，且不得触发 decoder reset，见 5.2）。

## 四、能力协商

复用现有通道，零新机制：

1. 客户端 `Decoder::supported_decodings()`（libs/scrap/src/common/codec.rs:424）
   构造 `SupportedDecoding` 时置 `tile_rects: !_use_texture_render`
   （texture render 模式下解码帧在 GPU 纹理，rgb 缓冲区是陈旧的，不能 blit）；
2. 客户端登录时经 `LoginRequest.option.supported_decoding` 上报
   （src/client.rs:3427），后续变更走 `Misc.option`（client.rs:3889）；
3. 服务端 `update_codec_on_login`（src/server/connection.rs:2749）→
   `Encoder::update(EncodingUpdate::Update(conn_id, decoding))` →
   全局 `PEER_DECODINGS`（codec.rs:42）；
4. video_service 每帧查询新 helper
   `Encoder::peers_support_tile_rects()`：
   `!decodings.is_empty() && decodings.iter().all(|(_, s)| s.tile_rects)`。
   `EncodingUpdate::NewOnlyVP9` 用 Default（false），天然安全。

## 五、实现设计

### 5.1 新模块 `libs/scrap/src/common/tile_rect.rs`

纯函数，全部可单测：

| 函数 | 说明 |
|---|---|
| `mask_to_rects(mask: &TileMask) -> Vec<TileRect>` | 行游程合并：同一 tile 行内连续变化 tile 合成一个 rect；rect 坐标/尺寸按像素，边缘 tile 按 `TILE_SIZE.min(width - x)` 裁剪 |
| `extract_rects(cur, prev, width, height, rects) -> Vec<u8>` | 按 rect 顺序输出当前帧与 `prev`（上一发送帧）的逐字节 XOR（BGRA 序、每行 `w*4` 字节） |
| `blit_rects(raw, buf_w, buf_h, swap_rb, rects, data) -> ResultType<()>` | 对客户端 rgb 缓冲区做 XOR 应用；`swap_rb=true`（flutter desktop 的 `ImageFormat::ABGR`，内存序 R,G,B,A）时先把 delta 的 B↔R 字节交换再 XOR；`false`（`ARGB` 内存序 = B,G,R,A，与采集 BGRA 一致）直接 XOR。stride 取 `raw.len()/buf_h` 整除校验，不整除返回 Err |

### 5.2 服务端 `src/server/video_service.rs`（run() 内，现有 diff 块之后）

现状（行号约为 888-974）：`diff_skipped`（静止跳过）→ 节流检查 → 转 YUV（可 restore）→
`handle_one_frame` 编码发送 → 推进 `prev_bgra`。

新增分支（插在节流检查之后、`encode_input` 构造之前）：

```rust
// 伪代码
if small_change
    && tile_rects_ok              // Encoder::peers_support_tile_rects()，循环外每帧取一次
    && recorder.lock().unwrap().is_none()   // 服务端录屏时保持全编码路径
    && let (Some(mask), Some(cur)) = (&diff_mask, &pending_bgra)
{
    let rects = tile_rect::mask_to_rects(mask);
    if !rects.is_empty() && rects.len() <= MAX_TILE_RECTS /* 64 */ {
        let raw = tile_rect::extract_rects(cur, prev_bgra, w, h, &rects);
        let packed = hbb_common::compress::compress(&raw);
        let (data, compress) = if !packed.is_empty() && packed.len() < raw.len() {
            (packed, true)
        } else {
            (raw, false)
        };
        // 组 VideoFrame{ tiles, display } → sp.send_video_frame(msg)
        // frame_controller.set_send / send_counter / prev_bgra / last_send 与编码路径一致推进
        skip_restore_once = true;
        continue;
    }
    // rects 过多：落回编码路径
}
```

- `skip_restore_once`：在下一次编码路径中，`if prev_yuv_key == Some(key) && !skip_restore_once`
  才执行 `restore_unchanged_yuv`，随后清除标志；
- 200ms 节流**保留**：tile 消息替代的是「节流到期后要发的那帧」的载荷，调度不变；
- 编码路径（大变化、未协商、录屏中）行为与现状完全一致。

### 5.3 客户端 `src/client.rs`（VideoHandler::handle_frame，2686 起）

在 `CodecFormat::from(&vf)` 与 decoder reset 逻辑**之前**拦截：

```rust
if let Some(video_frame::Union::Tiles(tiles)) = &vf.union {
    return self.handle_tile_rects(tiles, pixelbuffer);
}
```

`handle_tile_rects`（新增私有方法）：

1. `tiles.compress` → `hbb_common::compress::decompress`；
2. 校验 `self.rgb` 非空、rect 均在 `rgb.w/rgb.h` 内、data 长度 == Σ(rect.w*rect.h*4)；
   任一失败 → 记 throttled 日志并 `Ok(false)`（走现有 fail-counter → refresh_video
   恢复路径，干净失败；实现时确认 start_video_thread 失败分支行为，client.rs:4060+）；
3. `swap_rb = matches!(self.rgb.fmt, ImageFormat::ABGR)`，调 `blit_rects`；
4. `*pixelbuffer = true`，返回 `Ok(true)` —— `video_callback` 照常推全帧给 UI。

已知限制（文档化，不修）：客户端本地录屏（record_screen）开启期间收到 tiles，
录像会跳过这些增量帧（`write_frame(..).ok()` 吞错），录像中对应区域滞后到下一编码帧；
显示不受影响。服务端录屏则直接不启用 tiles（5.2）。

### 5.4 编解码协商辅助 `libs/scrap/src/common/codec.rs`

```rust
pub fn peers_support_tile_rects() -> bool {
    let d = PEER_DECODINGS.lock().unwrap();
    !d.is_empty() && d.iter().all(|(_, s)| s.tile_rects)
}
```

并在 `Decoder::supported_decodings()` 中置位（见第四节）。

## 六、改动文件清单

| 文件 | 改动 |
|---|---|
| `libs/base/protos/message.proto` | +TileRect/+TileRects 消息；VideoFrame.oneof +`tiles=15`；SupportedDecoding +`tile_rects=9` |
| `libs/scrap/src/common/tile_rect.rs` | 新建：mask→rects、extract、blit + 单测 |
| `libs/scrap/src/common/mod.rs` | +`pub mod tile_rect;`（或并入现有导出块） |
| `libs/scrap/src/common/codec.rs` | +`peers_support_tile_rects()`；`supported_decodings()` 置位；`CodecFormat::from` 显式处理 tiles→Unknown（如为穷尽 match） |
| `src/server/video_service.rs` | run() 内新增 tiles 分支 + `skip_restore_once` 门控 |
| `src/client.rs` | handle_frame 拦截分支 + `handle_tile_rects` |

web 目标零改动（JS 端不声明能力）；Flutter bridge 零改动（无新 FFI）。

## 七、验证

### 7.1 单元测试（tile_rect.rs 内 #[cfg(test)]）

1. `mask_to_rects`：单个变化 tile → 1 rect；同一行相邻 3 tile → 1 合并 rect；
   不同行 → 2 rect；右/下边缘裁剪尺寸正确；
2. extract+blit 往返：构造 mask/帧 → extract → blit 到另一缓冲 → 变化区域像素一致、
   未变化区域保持原值；ARGB/ABGR 两种 fmt 各一遍（ABGR 验证 B↔R 交换）；
3. blit 容错：data 长度不符 / rect 越界 → Err 且不写缓冲区。

### 7.2 构建

- `cargo test -p scrap`（docker，`-e VCPKG_ROOT=/vcpkg`）；
- bullseye docker release 构建（`--release --features inline`）。

### 7.3 双机 A/B 实测（复用既有脚本与环境）

被控 10.176.35.165（:21118）/ 控制 10.176.35.167，场景沿用 10Hz 小区域终端刷新 +
IDE 光标闪烁；tcpdump 抓包按 `video_frame` 消息统计。预期：

| 场景 | 现状（3.1.6.2） | 目标 |
|---|---|---|
| 10Hz 小区域 | video 36.6 kbps / 69 msg / 1011B 均帧 | 消息数不变，均帧 200-400B，video ~10-15 kbps |
| IDE 光标 | ~7.6 kbps | ~2-4 kbps |
| 大变化（滚动/拖窗） | 编码路径 | 与基线一致（回归不劣化） |
| 静止 | 0 帧 | 不变 |

正确性目检：tile 更新区域显示正确、无花屏；大变化切换无残留旧内容
（重点验证 skip_restore_once）；客户端断线重连正常。

## 八、回归面声明

- 既有编码路径：仅新增 `skip_restore_once` 门控（默认 false → 走原逻辑）与一处
  `small_change` 分支前置判断（未协商时条件为 false → 走原逻辑）；
- `CodecFormat::from` 等穷尽 match 的新增分支只影响 tiles variant；
- proto 新增字段不影响既有字段编号与旧端互通；
- 不动 hbb_common 子模块以外……（hbb_common 完全不动的，proto 在 libs/base）。
