# 双机带宽实测 Spec — 帧差分优化（Phase 1+2）实机验证

## 目标

在真实双机链路上量化 tile-diff 优化（静止跳帧 + 脏矩形 YUV 回填）的带宽收益，
覆盖 `docs/OPTIMIZE_TRANSPORT.md` 3.1 节的验收要求。

## 已确认的环境事实

| 项 | 被控端 10.176.35.165（本机） | 控制端 10.176.35.167（R760） |
|---|---|---|
| 系统 | Linux，X11 桌面（1360x768 同网段） | Ubuntu 20.04（glibc 2.31，与 bullseye 构建兼容） |
| 访问 | 本地 + `sudo -n` 可用 | 免密 SSH（portion@），`DISPLAY=:0` 可用（xrandr 验证通过），GTK3 已装 |
| RustDesk | 优化版二进制运行中（后台 job），ID 385209248 | 未安装，需部署 |
| 链路 | 同子网 10.176.34.0/23，RTT < 0.3ms | 同左 |

代码事实：
- diff 改动**未提交**（`libs/scrap/src/common/diff.rs` 新增 + `video_service.rs`/`mod.rs` 修改），
  另有未提交的 server-setup-prompt 改动（`index.tis`/`desktop_home_page.dart`）。
  基线 = `git worktree` 检出 HEAD（2d047511d），干净且不动工作区。
- `direct-server` 选项默认关；`Config::get_option` 读内存缓存（CONFIG2），
  **改配置文件必须重启被控进程才生效**，重启后临时密码重新生成。
- 永久密码支持明文遗留格式（`decrypt_permanent_password_str_or_original` 对无版本前缀的
  存储原样返回），可在 `RustDesk.toml` 写 `password = '...'`，多轮重启密码稳定，
  免去每轮截图读密码。
- direct server 监听端口 = `direct-access-port` 或默认 21118（RENDEZVOUS_PORT+2）。
- 本机未装 xdotool / glxgears。

## 关键决策

1. **连接方式：Direct IP 直连**。被控开 `direct-server=Y` 监听 21118；控制端以 IP 作为 ID
   直连。流量路径确定（仅 .165:21118 ↔ .167 的 TCP），抓包过滤干净；顺带验证内网无外网
   部署场景。备选：公共 rendezvous（ID 385209248 + 临时密码），同子网 P2P，零配置改动，
   但 hole-punch 失败会走中继导致本地抓不到包（可检测兜底）。
2. **固定永久密码**：`RustDesk.toml` 设 `password = 'rdbench123'`，两轮（baseline/优化版）
   复用同一密码，避免每轮截图。
3. **控制端免 sudo 部署**：scp 同一 bullseye 二进制 + `libsciter-gtk.so` 到
   `~ portion/rustdesk-test/`，so 放 `~/rustdesk-test/usr/share/rustdesk/`，启动时设
   `APPDIR=$HOME/rustdesk-test`（`ui.rs` 探测 `$APPDIR/usr/share/rustdesk/libsciter-gtk.so`）。
   控制端不参与优化逻辑，用同一二进制无影响。
4. **baseline 构建**：`git worktree add /home/portion/rustdesk-baseline HEAD` +
   `submodule update --init`，复用既有 bullseye docker 构建链与离线缓存。
5. **场景激励**：
   - 静止：连接后静置，无激励；
   - 光标移动：xdotool（`sudo -n apt-get install -y xdotool`）小范围循环移动 15s；
   - 全屏变化（可选）：xdotool 拖动窗口画圈 15s。
6. **计量**：.165 上 `sudo -n tcpdump -i eno8303 host 10.176.35.167 -w <file>` 与激励同步
   抓 15s；字节数 = pcap 中 TCP payload `length` 列求和，换算 kbps。

## 测试矩阵与流程

2 个被控版本（baseline / optimized）× 2 场景（static / cursor）+ 可选 fullscreen。
每轮：启动对应版本被控 → 确认 `ss -ltn | grep 21118` → .167 SSH 启动
`--connect 10.176.35.165 rdbench123` → 静置 5s → 逐场景抓包计量 → 断开。

## 预期结果与判定

- 静止：X11 capturer 已有 exact-match 去重，baseline 与优化版都应接近 0；
  优化版 ≤ baseline 即合格（±2 容差的增量价值在抗锯齿亚像素抖动场景）。
- 光标移动：优化版应显著低于 baseline（脏矩形回填使未变区域编码输出趋零），
  目标降幅 ≥ 50%。达不到则停下来分析编码器参数/分辨率因素，不硬过。
- 全屏变化：两版相当（±20%），验证 50% 阈值退化 FullFrame 无回归。

## 风险与缓解

- xdotool 未装 → sudo apt 安装；失败则退化为手动晃鼠标（计时同步即可）。
- .167 缺 sciter 依赖 → 先 `ldd` 检查再启动；缺则 `apt install libgtk-3-0`。
- baseline worktree 缺子模块 → 构建前 `git submodule update --init --recursive`。
- 21118 未监听/被挡 → `ss -ltn` 确认 + .167 上 `nc -z` 验证。
- 明文密码首启被加密改写属正常，解密结果不变，多轮稳定。

## 结果交付

- `docs/specs/two-machine-bandwidth/results.md`：矩阵数据表 + kbps 对比 + 结论。
- 回填 `docs/OPTIMIZE_TRANSPORT.md` 3.1.6 小节补实测数据。

## 范围外（记录不处理）

- 截图观察到公共服务器配置下仍弹出 "ID/Relay server" 配置弹窗，疑似
  server-setup-prompt 逻辑缺陷，测完后另行回顾。
