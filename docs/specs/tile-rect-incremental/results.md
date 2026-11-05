# Phase 4 tile 矩形增量：实测结果与终止结论（2026-11-05）

> 结论：**已证伪，代码整体回退**。机制正确性全部通过，但 X11+VP9 组合下收益为负。
> 本文件存档完整数据链，供后续 Web/无编码器场景参考。

## 1. 测试环境与方法

- 被控 10.176.35.165（自建被控监听 :21118，直连接入）/ 控制 10.176.35.167
- tcpdump 抓 `host 10.176.35.167 and tcp port 21118`，脚本解析按 `Message` 类型
  只统计 `video_frame` 出方向（tiles / encoded 分开计数）
- 黑窗遮挡法：fullscreen 静态终端盖住桌面排除 IDE spinner/弹窗光标等污染源，
  前景 50x4 终端 10Hz 刷新时间戳作为标准小变化源
- 服务端二进制轮换（按 PID kill + `ss -tlnp` + `md5sum /proc/PID/exe` 双重验证端口
  归属），客户端固定 XOR 版（量化仅改服务端发送内容，客户端逻辑不变）

## 2. 数据链（video_frame payload）

三代 tiles 实现 vs 3.1.6.2 节流（VP9 编码路径）：

| 场景 | raw BGRA+zstd | 纯 XOR+zstd | 量化 XOR（死区 8） | 节流 VP9 |
|---|---|---|---|---|
| 10Hz 小区域 | 114.3 kbps | 28.0 kbps | 27.0 kbps | 12.7 kbps |
| 静止 | 79.9 kbps | 0.5 kbps | 0.6 kbps | 1.1 kbps |
| IDE 真实桌面 | — | — | 48.0 kbps | 11.3 kbps |

黑窗法成对明细（量化版 vs 节流版，各 ~15s 窗口）：

| 场景 | 版本 | 消息数 | 均帧 | video kbps | pcap |
|---|---|---|---|---|---|
| 静止 | tiles | 16（全 tiles） | 71 B | 0.6 | cap-q3-static |
| 静止 | VP9 | 14（全 encoded） | 146 B | 1.1 | cap-t3-static |
| 10Hz 小区域 | tiles | 69（全 tiles） | 736 B | 27.0 | cap-q3-small |
| 10Hz 小区域 | VP9 | 72（全 encoded） | 335 B | 12.7 | cap-t3-small |
| IDE 桌面 | tiles | 66（全 tiles） | 1360 B | 48.0 | cap-q4-ide |
| IDE 桌面 | VP9 | 68（全 encoded） | 312 B | 11.3 | cap-t4-ide |

## 3. 证伪分析

1. 抗锯齿文本的原始像素熵高，zstd 对 raw BGRA 压缩率仅 ~0.10 → raw 版 114 kbps
   负收益，修订为 XOR；
2. XOR 后静止场景压缩极佳（0.5 kbps，胜 VP9），但字形翻转是大 delta，
   每条消息仍 ~760 B，劣于 VP9 的 ~310 B；
3. 死区量化（<8 清零）只再省 ~4%（28.0 → 27.0）——文本边缘 delta 远超阈值，
   死区碰不到；提高阈值则画质损失不可接受且仍追不上有损 DCT；
4. tiles 唯一胜出的近静止场景，VP9 本就仅 1.1 kbps，绝对收益 0.5 kbps 无价值。

物理本质：VP9 的有损变换域编码对「结构小变化」天然匹配；逐像素无损增量在协议层
无法逼近。X11 整屏去重（capturer 层）+ VP9 帧间预测 + 3.1.6.2 节流已是甜点位。

## 4. 机制正确性验证（全部通过）

- **大变化回退**：拖窗（606x281 终端逐秒移动）时 9 条 encoded + 62 条 tiles
  （cap-q4-big2，74.1 kbps）——超过 5% tile 阈值自动回落编码路径，节流/tiles 不干扰；
- **断线重连**：客户端 rgb 为空时首条 tiles 校验失败走 refresh_video 自愈，
  服务端关键帧后 tiles 正常应用，远端截图渲染正确；
- **渲染正确性**：tiles 持续更新期间远端目检无花屏、无残影、无色偏
  （XOR 基准误差 ≤7/255 有界不累积，编码帧刷新后消失）。

## 5. 已知限制（存档，代码已回退）

- 有损帧后 XOR 基准误差 e 的残影（有界不累积，下次编码帧覆盖即消失）；
- 客户端本地录屏期间 tiles 增量不进录像；texture render 模式不声明 tiles 能力。

## 6. 二进制与抓包存档

- `/tmp/rd-bench/rustdesk-tiles-quant`（量化版，md5 93a221eb40e2bfc5c1ec11a01293373b）
- `/tmp/rd-bench/rustdesk-tiles-xor`（纯 XOR 版，md5 648f3a9bad63c4b5ad631240718018e7）
- `/tmp/rd-bench/rustdesk-throttle`（3.1.6.2 对照，md5 51f8bd8b8a90e17e2ac9b663848fd662）
- pcap：`/tmp/cap-{q3,t3}-{static,small}.pcap`、`/tmp/cap-{q4,t4}-ide.pcap`、
  `/tmp/cap-q4-big2.pcap`、`/tmp/cap-q4-reconnect.pcap`
