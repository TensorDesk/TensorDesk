# Tasks — 双机带宽实测

## T1 被控端配置（direct IP + 固定密码）
- [x] 停掉当前后台被控进程（job-8f1845f0df8044bea754ebabb14cb5cb）
- [x] `~/.config/rustdesk/RustDesk.toml`：`password = ''` → `password = 'rdbench123'`
- [x] `~/.config/rustdesk/RustDesk2.toml`：`[options]` 加 `direct-server = 'Y'`（无 section 则追加）
- [x] 重新后台启动优化版被控；验证 `ss -ltn | grep 21118` 监听中

## T2 baseline 构建（改用主仓 stash 方案，复用 target-bullseye 增量缓存；worktree 缺 gitignored 的 src/ui/inline.rs 不可用）
- [x] 优化版二进制已备份到 /tmp/rd-bench/rustdesk-optimized（md5 3287d049…）
- [x] `git stash push` → 回滚到 HEAD 源码
- [x] 首次构建失败（cargo 在线拉 chromium.googlesource/libwebm）；改挂载宿主 `~/.cargo/git` 缓存后成功（`--offline` 因镜像缺 crates.io 索引不可用）
- [x] docker：`docker run --rm -v /home/portion/rustdesk:/home/user/rustdesk -v /home/portion/.cargo/git:/home/user/.cargo/git -e CARGO_TARGET_DIR=target-bullseye rustdesk-builder-bullseye --release --features inline`
- [x] 产物备份 /tmp/rd-bench/rustdesk-baseline（md5 369ea93d…，ldd 无 missing，构建 6m50s）
- [x] `git stash pop` 恢复改动 + 恢复优化版二进制到 target-bullseye（mod.rs 含 `pub mod diff`，md5 已核对）

## T3 控制端 .167 部署
- [x] `~/rustdesk-test/usr/share/rustdesk` 目录 + scp 二进制与 libsciter-gtk.so
- [x] `ldd` 检查通过（rustdesk 与 sciter 均无 not found）
- [x] ufw 放行：`sudo ufw allow from 10.176.35.167 to any port 21118 proto tcp`（INPUT 默认 DROP 会拦 21118；T7 需清理）
- [x] 从 .167 `nc -z 10.176.35.165 21118` 通

## T4 xdotool 安装（被控端）
- [x] `sudo -n apt-get install -y xdotool` 已装（/usr/bin/xdotool）

## T5 测试矩阵
- [x] T5.0 冒烟：直连 + 认证成功，ESTABLISHED 确认
- [x] optimized × static ×3（43.8 / 34.1 / 35.4 kbps；首次因 `timeout sudo` 杀不掉 tcpdump 作废重抓）
- [x] optimized × small-region ×2（46.6 / 43.3 kbps）
- [x] optimized × cursor-only ×1（47.1 kbps）
- [x] baseline × static ×3（32.3 / 47.5 / 47.5 kbps）
- [x] baseline × small-region ×2（123.5 污染样本 / 41.4 kbps；首样本含首屏爆发，剔除后稳态 47.4）
- [x] baseline × cursor-only ×1（47.7 kbps）
- [x] 版本切换均重启被控并确认 21118 监听

## T6 计量与汇总
- [x] 逐 pcap 统计 + 剔首屏后取每秒中位数：稳态无显著差异（small +1%，cursor −1%，static 名义 −21% 但不显著）
- [x] 对比表 + 结论 + 原因分析 → `docs/specs/two-machine-bandwidth/results.md`
- [x] 回填 `docs/OPTIMIZE_TRANSPORT.md` 3.1.6.1 双机实测小节

## T8 方案 A：小变化动态降频（Phase 3）
- [x] `diff.rs` 新增 `DiffResult::is_small_change()` + 单测（变化 tile < 5%），7 个测试全绿
- [x] `video_service.rs` 接入节流：200ms 最小发送间隔、`prev_bgra` 只在发送时推进；release 构建（md5 51f8bd8b…）
- [x] A/B 实测（同一 10Hz 小区域场景，仅换被控二进制）：无节流 83.2 kbps / 节流 36.7 kbps（−56%），消息 458→69
- [x] 抓包归因：8B 小包 = `TestDelay`（1/s）+ `audio_frame`；报文首字节是 `BytesCodec` 长度头
- [x] 数据与结论写入 `results.md` 与 `OPTIMIZE_TRANSPORT.md` 3.1.6.2
- [x] 恢复被控端为节流版并重启（21118 监听，md5 51f8bd8b…）；关闭测试用终端窗口

## T7 清理（用户确认：保留直连+固定密码、保留 .167 文件、启动优化版）
- [x] 启动优化版被控（md5 3287d049…，21118 监听中）
- [x] 保留 `direct-server='Y'`、密码 `rdbench123`、ufw `.167→21118/tcp` 规则（便于后续复测）
- [x] 未创建 `rustdesk-baseline` worktree（改用 stash 方案），`git stash list` 为空
- [x] 保留 .167 的 `~/rustdesk-test`；抓包证据留在 `/tmp/cap-*.pcap` 与 `/tmp/{opt,base}-*.txt`
