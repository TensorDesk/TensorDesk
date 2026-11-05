# Phase 4 任务清单（tile 矩形增量）

依据 spec.md 执行；每步完成后验证再进入下一步。

- [x] T1 proto：message.proto 加 TileRect/TileRects/VideoFrame.tiles=15/SupportedDecoding.tile_rects=9；docker 内 `cargo check -p base` 确认 codegen 通过
- [x] T2 scrap：`libs/scrap/src/common/tile_rect.rs`（mask_to_rects/extract_rects/blit_rects）+ mod 导出 + 5 个单测；`cargo test -p scrap tile_rect` 全绿
- [x] T3 codec.rs：`peers_support_tile_rects()` + `supported_decodings()` 置位（!_use_texture_render）+ `CodecFormat::from` tiles 分支（若穷尽 match 报错）
- [x] T4 服务端 video_service.rs：tiles 发送分支 + skip_restore_once；`cargo check`（docker）
- [x] T5 客户端 client.rs：handle_frame 拦截 + handle_tile_rects（含校验/失败路径）；确认 start_video_thread 失败分支会触发 refresh_video
- [x] T6 `cargo test -p scrap` 全量 + bullseye release 构建（--features inline）
- [x] T7 双机部署：被控 .165 换二进制（备份到 /tmp/rd-bench/rustdesk-tiles），控制端 .167 同步换新客户端二进制
- [x] T8 实测：黑窗法成对（tiles 0.6/27.0/48.0 kbps vs VP9 1.1/12.7/11.3 kbps）；大变化回退、断线重连、远端渲染正确性全部通过；数据见 results.md
- [x] T11 XOR 增量修订（raw 实测 114.3 kbps 劣于编码路径 36.6 kbps）：extract/blit 改 XOR 语义 + 单测、服务端传 prev、客户端注释、spec 修订记录；重跑 T8 的 10Hz 小区域与静止场景对比。追加有损量化死区（<8 清零）修订：实测仅再省 ~4%（28.0→27.0 kbps），证伪
- [x] T9 回填 docs：results 写入本目录 results.md + OPTIMIZE_TRANSPORT.md 新增 3.1.6.3 节（证伪结论）
- [x] T12 终止决策（用户拍板）：机制正确但收益为负，代码整体回退（proto/协商/收发路径/tile_rect.rs 未保留），回退后 `cargo test -p scrap` 8/8 绿；文档存档不删
- [ ] T10 commit（英文，仅文档改动）+ push 到 fork；不建 PR
