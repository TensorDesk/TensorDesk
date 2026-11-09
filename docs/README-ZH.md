<p align="center">
  <img src="../res/logo-header.svg" alt="TensorDesk - 智能辅助桌面：挣脱键盘桎梏，释放思考力量"><br>
  <a href="#基本构建步骤">编译</a> •
  <a href="#使用-Docker-编译">Docker</a> •
  <a href="#文件结构">结构</a> •
  <a href="#截图">截图</a><br>
  [<a href="../README.md">English</a>] | [<a href="README-UA.md">Українська</a>] | [<a href="README-CS.md">česky</a>] | [<a href="README-HU.md">Magyar</a>] | [<a href="README-ES.md">Español</a>] | [<a href="README-FA.md">فارسی</a>] | [<a href="README-FR.md">Français</a>] | [<a href="README-DE.md">Deutsch</a>] | [<a href="README-PL.md">Polski</a>] | [<a href="README-ID.md">Indonesian</a>] | [<a href="README-FI.md">Suomi</a>] | [<a href="README-ML.md">മലയാളം</a>] | [<a href="README-JP.md">日本語</a>] | [<a href="README-NL.md">Nederlands</a>] | [<a href="README-IT.md">Italiano</a>] | [<a href="README-RU.md">Русский</a>] | [<a href="README-PTBR.md">Português (Brasil)</a>] | [<a href="README-EO.md">Esperanto</a>] | [<a href="README-KR.md">한국어</a>] | [<a href="README-AR.md">العربي</a>] | [<a href="README-VN.md">Tiếng Việt</a>] | [<a href="README-GR.md">Ελληνικά</a>]<br>
</p>

> [!CAUTION]
> **免责声明:** <br>
> TensorDesk 的开发人员不纵容或支持任何不道德或非法的软件使用行为。滥用行为，例如未经授权的访问、控制或侵犯隐私，严格违反我们的准则。作者对应用程序的任何滥用行为概不负责。

> [!NOTE]
> **合规提醒：** 中国大陆用户请遵守《中华人民共和国计算机信息网络国际联网管理暂行规定》等法律法规，合规使用本软件。

**TensorDesk** 是一款开源智能辅助桌面，基于 [RustDesk](https://github.com/rustdesk/rustdesk) 深度优化，使用 Rust 编写。它把远程控制升级为智能协作——智能辅助交互、Agent 自动发现问题、24 小时行为轨迹汇聚产品改进——同时保留 RustDesk 全部能力，并围绕一个目标重构了传输层：**让常驻连接的流量降到最低**。所有会话由 TensorDesk SaaS 控制台统一管理——设备、成员、会话与计费一站搞定。

> *智能桌面：挣脱键盘桎梏，释放思考力量*

## 为什么选择 TensorDesk：智能辅助 + 极致低流量

当远端画面几乎不变时，TensorDesk 会把流量压到接近心跳的水平：

- **观看端挂起（Viewer Suspend）** —— 观看端一段时间无输入时自动挂起视频流，仅保留心跳；恢复输入即时强制关键帧，秒级回画面。
- **小变化动态节流** —— 光标闪烁、时钟跳动等微小画面变化触发自动降帧降码率，不为「无效像素」浪费带宽。
- **帧率下限语义化** —— 自动帧率调节下限为 5fps，1–4fps 保留为挂起语义，避免低性能客户端被永久锁帧。
- **30 秒增量重连缓冲** —— 断线 30 秒内重连直接续传增量帧，无需全量关键帧重传。

**每天最低流量对比（估算）**

| 场景 | RustDesk 原版 | TensorDesk |
| --- | --- | --- |
| 空闲办公桌面常驻 24 小时 | 约 0.5–2 GB/天 | **约 10–50 MB/天**（流量节省 90% 以上） |

<sub>估算值：假设典型办公桌面存在时钟、光标闪烁等微小变化；实际流量取决于画面内容，仅供量级参考。</sub>

[**正式版下载**](https://github.com/TensorDesk/TensorDesk/releases)

[**每日构建版**](https://github.com/TensorDesk/TensorDesk/releases/tag/nightly)

TensorDesk 期待各位的贡献。如何参与开发？详情请看 [CONTRIBUTING.md](CONTRIBUTING.md)。

![image](https://user-images.githubusercontent.com/71636191/171661982-430285f0-2e12-4b1d-9957-4a58e375304d.png)

## 依赖

桌面版本使用 Flutter 或 Sciter（已弃用）作为 GUI，本教程仅适用于 Sciter，因为它更简单且更易于上手。查看我们的 [CI](https://github.com/TensorDesk/TensorDesk/blob/master/.github/workflows/flutter-build.yml) 以构建 Flutter 版本。

请自行下载 Sciter 动态库。

[Windows](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.win/x64/sciter.dll) |
[Linux](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so) |
[macOS](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.osx/libsciter.dylib)

## 基本构建步骤

- 请准备好 Rust 开发环境和 C++ 编译环境

- 安装 [vcpkg](https://github.com/microsoft/vcpkg)，正确设置 `VCPKG_ROOT` 环境变量

  - Windows: vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
  - Linux/macOS: vcpkg install libvpx libyuv opus aom

- 运行 `cargo run`

## 在 Linux 上编译

### Ubuntu 18 (Debian 10)

```sh
sudo apt install -y zip g++ gcc git curl wget nasm yasm libgtk-3-dev clang libxcb-randr0-dev libxdo-dev \
        libxfixes-dev libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev cmake make \
        libclang-dev ninja-build libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

### openSUSE Tumbleweed

```sh
sudo zypper install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libXfixes-devel cmake alsa-lib-devel gstreamer-devel gstreamer-plugins-base-devel xdotool-devel
```

### Fedora 28 (CentOS 8)

```sh
sudo yum -y install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libxdo-devel libXfixes-devel pulseaudio-libs-devel cmake alsa-lib-devel gstreamer1-devel gstreamer1-plugins-base-devel
```

### Arch (Manjaro)

```sh
sudo pacman -Syu --needed unzip git cmake gcc curl wget yasm nasm zip make pkg-config clang gtk3 xdotool libxcb libxfixes alsa-lib pipewire
```

### 安装 vcpkg

```sh
git clone https://github.com/microsoft/vcpkg
cd vcpkg
git checkout 2023.04.15
cd ..
vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=$HOME/vcpkg
vcpkg/vcpkg install libvpx libyuv opus aom
```

### 修复 libvpx（仅仅针对 Fedora）

```sh
cd vcpkg/buildtrees/libvpx/src
cd *
./configure
sed -i 's/CFLAGS+=-I/CFLAGS+=-fPIC -I/g' Makefile
sed -i 's/CXXFLAGS+=-I/CXXFLAGS+=-fPIC -I/g' Makefile
make
cp libvpx.a $HOME/vcpkg/installed/x64-linux/lib/
cd
```

### 构建

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
git clone --recurse-submodules https://github.com/TensorDesk/TensorDesk
cd TensorDesk
mkdir -p target/debug
wget https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so
mv libsciter-gtk.so target/debug
VCPKG_ROOT=$HOME/vcpkg cargo run
```

## 使用 Docker 编译

克隆版本库并构建 Docker 容器：

```sh
git clone https://github.com/TensorDesk/TensorDesk # 克隆 GitHub 存储库
cd TensorDesk # 进入文件夹
docker build -t "tensordesk-builder" . # 构建容器
```

请注意：
* 针对国内网络访问问题，可以做以下几点优化：
   1. Dockerfile 中修改系统的源到国内镜像
      ```
      在Dockerfile的RUN apt update之前插入两行：

      RUN sed -i "s|deb.debian.org|mirrors.aliyun.com|g" /etc/apt/sources.list && \
          sed -i "s|security.debian.org|mirrors.aliyun.com|g" /etc/apt/sources.list
      ```

   2. 修改容器系统中的 cargo 源，在 `RUN ./rustup.sh -y` 后插入下面代码：

      ```
      RUN echo '[source.crates-io]' > ~/.cargo/config \
       && echo 'registry = "https://github.com/rust-lang/crates.io-index"'  >> ~/.cargo/config \
       && echo '# 替换成你偏好的镜像源'  >> ~/.cargo/config \
       && echo "replace-with = 'sjtu'"  >> ~/.cargo/config \
       && echo '# 上海交通大学'   >> ~/.cargo/config \
       && echo '[source.sjtu]'   >> ~/.cargo/config \
       && echo 'registry = "https://mirrors.sjtug.sjtu.edu.cn/git/crates.io-index"'  >> ~/.cargo/config \
       && echo '' >> ~/.cargo/config
      ```

   3. Dockerfile 中加入代理的 env

      ```
      在User root后插入两行

      ENV http_proxy=http://host:port
      ENV https_proxy=http://host:port
      ```

   4. docker build 命令后面加上 proxy 参数

      ```
      docker build -t "tensordesk-builder" . --build-arg http_proxy=http://host:port --build-arg https_proxy=http://host:port
      ```

### 构建 TensorDesk 程序

然后，每次需要构建应用程序时，运行以下命令：

```sh
docker run --rm -it -v $PWD:/home/user/rustdesk -v tensordesk-git-cache:/home/user/.cargo/git -v tensordesk-registry-cache:/home/user/.cargo/registry -e PUID="$(id -u)" -e PGID="$(id -g)" tensordesk-builder
```

请注意：
* 因为需要缓存依赖项，首次构建一般很慢（国内网络会经常出现拉取失败，可以多试几次）。
* 如果您需要添加不同的构建参数，可以在指令末尾的 `<OPTIONAL-ARGS>` 位置进行修改。例如构建一个 Release 版本，在指令后面加上 ` --release` 即可。
* 如果出现以下的提示，则是无权限问题，可以尝试把 `-e PUID="$(id -u)" -e PGID="$(id -g)"` 参数去掉。
   ```
   usermod: user user is currently used by process 1
   groupmod: Permission denied.
   groupmod: cannot lock /etc/group; try again later.
   ```
   > **原因：** 容器的 entrypoint 脚本会检测 UID 和 GID，在判定和给定的环境变量不一致时，会强行修改 user 的 UID 和 GID 并重新运行。但在重启后读不到环境中的 UID 和 GID，然后再次进入判错重启环节

### 运行 TensorDesk 程序

生成的可执行程序在 target 目录下，可直接通过指令运行调试（Debug）版本：

```sh
target/debug/rustdesk
```

或者您想运行发行（Release）版本：

```sh
target/release/rustdesk
```

请注意：
* 请保证您运行的目录是在仓库的根目录内，否则软件会读不到文件。
* `install`、`run` 等 Cargo 的子指令在容器内不可用，宿主机才行。

## 文件结构

- **[libs/hbb_common](https://github.com/TensorDesk/TensorDesk/tree/master/libs/hbb_common)**: 视频编解码、配置、tcp/udp 封装，以及与服务端共享的其他实用函数
- **[libs/base](https://github.com/TensorDesk/TensorDesk/tree/master/libs/base)**: protobuf、文件传输相关文件系统操作函数、仅本应用使用的键盘与平台代码
- **[libs/scrap](https://github.com/TensorDesk/TensorDesk/tree/master/libs/scrap)**: 屏幕截取
- **[libs/enigo](https://github.com/TensorDesk/TensorDesk/tree/master/libs/enigo)**: 平台相关的鼠标键盘输入
- **[libs/clipboard](https://github.com/TensorDesk/TensorDesk/tree/master/libs/clipboard)**: Windows、Linux、macOS 的文件复制和粘贴实现
- **[src/ui](https://github.com/TensorDesk/TensorDesk/tree/master/src/ui)**: 过时的 Sciter UI（已弃用）
- **[src/server](https://github.com/TensorDesk/TensorDesk/tree/master/src/server)**: 被控端音频、剪切板、输入、视频服务与网络连接的实现
- **[src/client.rs](https://github.com/TensorDesk/TensorDesk/tree/master/src/client.rs)**: 控制端
- **[src/rendezvous_mediator.rs](https://github.com/TensorDesk/TensorDesk/tree/master/src/rendezvous_mediator.rs)**: 与注册/中继服务器保持通讯，等待远程连接（打洞直连或中继）
- **[src/platform](https://github.com/TensorDesk/TensorDesk/tree/master/src/platform)**: 平台相关代码
- **[flutter](https://github.com/TensorDesk/TensorDesk/tree/master/flutter)**: 适用于桌面和移动设备的 Flutter 代码

## 截图

![image](https://user-images.githubusercontent.com/71636191/113112362-ae4deb80-923b-11eb-957d-ff88daad4f06.png)

![image](https://user-images.githubusercontent.com/71636191/113112619-f705a480-923b-11eb-911d-97e984ef52b6.png)

![image](https://user-images.githubusercontent.com/71636191/113112857-3fbd5d80-923c-11eb-9836-768325faf906.png)

![image](https://user-images.githubusercontent.com/71636191/135385039-38fdbd72-379a-422d-b97f-33df71fb1cec.png)
