# MacEasyTier

EasyTier 的 macOS 菜单栏客户端。用 SwiftUI 管理多个 EasyTier 网络配置，内置 `easytier-core`，通过原生 RPC 通信，可查看节点、对等节点、路由、流量与日志。

默认以 **无 TUN 模式**（普通用户）运行；在网络编辑器中开启 TUN 后，启动时会请求管理员授权并以 root 运行 core。通知、ACL、WireGuard 门户等高级能力仍在后续阶段。

## 功能

- 网络配置：网络名/密钥 + 公共共享节点或手动 peers；Host/Listen 作为显式服务端模式保留。
- 客户端默认：`Join via Public Server`，默认公共节点 `tcp://public.easytier.top:11010`。
- TOML 导入、导出与 `easytier-core --check-config` 校验。
- 每个网络独立的 core 进程：启动、停止、异常退出提示、日志采集。
- 路由窗口：查看拓扑和路由表；拓扑节点显示连接协议、丢包率及相邻采样间的收发速率，首次采样或统计不可用时速率显示“—”。中继按路由下一跳识别；无法解析时，若配置了公共节点，图中将其标为推测的中继。
- TUN 模式：由常驻 root 系统服务（launchd 守护进程）运行 core；只需授权安装一次，之后启停不再弹密码；App 退出/崩溃时自动结束 core。
- 首页内存：显示 App 与所有 EasyTier core 的物理内存占用；TUN 模式由系统服务通过 socket 查询。
- 启停优化：每个 core 一条长连接 RPC；启动不再跑 `--check-config`；TUN 启停是一次本地 socket 往返（实测启动 ≈0.6s、停止 ≈0.1s）。
- 虚拟 IP：DHCP 网络记住上次租约，下次以固定 IP 启动（IP 立即就位、重启不漂移）；租约冲突/失败回退 DHCP；连上节点后 10 秒仍无 IP 会自动重启 core，再不行由应用侧选址。详见 `docs/plan/core-integration-v2.md`。
- 菜单栏常驻：快速启停、打开主窗口/路由/日志/设置。
- 设置页：主窗口侧边栏底部“设置”按钮、菜单栏“设置…”或 `⌘,` 打开通用/核心/关于三个页签。
- 自动连接：在网络编辑器中开启“启动时自动连接”后，App 启动即连接该网络（无需额外总开关）。
- 登录启动：设置页通过 `SMAppService` 注册/注销（需要 App 位于 /Applications 且签名有效）。
- 网络密钥存 Keychain；配置存 `~/Library/Application Support/MacEasyTier`。

## 客户端模式

默认新建配置是 **客户端**：

- `Join via Public Server`：填写网络名、密钥，使用默认公共共享节点 `tcp://public.easytier.top:11010`，适合没有公网 IP 的节点。
- `Join via Peers`：直接连接一个或多个对等节点 URL。
- `Host / Listen (Server)`：仅用于自建共享节点/服务端，不会主动加入网络。

客户端仍可保留 listeners（默认 `tcp://0.0.0.0:11010`、`udp://0.0.0.0:11010`）帮助 P2P 直连；listeners 是本地 bind 地址，不能填公网 IP。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `App/Core/` | 配置存储、TOML、core 进程管理、系统服务客户端/安装器、原生 RPC、IP 租约、Keychain |
| `Helper/` | `MacEasyTierHelper`：常驻 root 守护进程（C，启停 TUN core） |
| `App/Features/` | 主窗口、网络编辑器、路由/日志、设置、菜单栏 |
| `App/Resources/AppIcon.icns` | macOS 应用包图标（菜单栏状态图标独立） |
| `Shared/` | 数据模型与设置 Tab |
| `Scripts/build.sh` | 下载 core、构建、签名并输出到 `dist/` |
| `Scripts/package.sh` | 构建并生成带 `/Applications` 快捷方式的 DMG |
| `Scripts/fetch-core.sh` | 下载固定版本 EasyTier core 到 `Vendor/` |
| `Scripts/embed-core.sh` | Xcode 构建阶段嵌入 `Contents/Helpers` |
| `Scripts/test-helper.sh` | 守护进程协议回归测试（无需 root、无需联网） |
| `Tests/` | TOML 编解码/校验单元测试 |
| `demo/v2mac/` | 旧 UI 参考工程，不参与构建 |

## 环境要求

- Xcode 26 及以上（`Compat.swift` 使用 macOS 26 SDK 的 glass API）
- macOS 14 及以上（部署目标）
- XcodeGen：`brew install xcodegen`
- 首次构建需要网络下载 EasyTier 2.6.4 macOS 二进制（或预先运行 `Scripts/fetch-core.sh`）

## 开发

```bash
xcodegen generate
open maceasytier.xcodeproj
```

`maceasytier.xcodeproj` 是 `project.yml` 的生成物，新增/移动文件后重新生成。

## 构建

```bash
Scripts/build.sh                    # Release、当前架构、ad-hoc 签名 → dist/MacEasyTier.app
Scripts/build.sh --debug            # Debug → dist/MacEasyTierDev.app
Scripts/build.sh --no-generate      # 不重新生成工程
ARCH=universal Scripts/build.sh     # arm64 + x86_64
SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" Scripts/build.sh
```

脚本会：

1. 按 `ARCH` 运行 `Scripts/fetch-core.sh`，下载/校验 EasyTier 二进制。
2. 用 `xcodegen` 生成工程并构建。
3. 先签 `Contents/Helpers/easytier-core` 与 `MacEasyTierHelper`，再签 App。
4. 输出到 `dist/MacEasyTier.app` 并校验架构与签名。

## 测试

```bash
xcodebuild -project maceasytier.xcodeproj -scheme maceasytier \
  -configuration Debug -destination 'platform=macOS' test
```

单元测试覆盖 TOML 往返、监听器/空数组语义、真实配置解析与校验错误、IP 租约/选址/冲突检测。

```bash
Scripts/test-helper.sh      # 守护进程协议（非 root、离线）
# 真实 TUN 端到端（会弹两次管理员密码：安装与卸载系统服务）：
TEST_RUNNER_MACEASYTIER_E2E_CONFIG=/path/to/easytier-config.toml \
  xcodebuild -project maceasytier.xcodeproj -scheme maceasytier -destination 'platform=macOS' \
  test -only-testing:MacEasyTierTests/CoreIntegrationTests
```

## 打包

```bash
Scripts/package.sh                  # dist/MacEasyTier-<version>.dmg + .sha256
Scripts/package.sh --skip-build
```

DMG 内含 `MacEasyTier.app` 与 `/Applications` 快捷方式；打包后会挂载校验并输出 SHA-256。

## 运行时说明

- **无 TUN 模式**：core 以普通用户运行；虚拟网内节点可以访问本机，本机访问其他节点请使用 SOCKS5 或端口转发。
- **TUN 模式**：首次使用时安装系统服务（一次管理员密码，也可在 设置 → 核心 中安装/更新/卸载）；之后 TUN 网络启停无需密码。core 以 root 运行并创建 utun；App 退出或崩溃时系统服务会结束对应 core。
- `easytier-core` 会为每个网络配置监听默认端口（`tcp/udp 11010` 等），可在编辑器里改。
- 停止网络会向 core 发送 `SIGTERM`；退出 App 会停止所有由 App 启动的 core。
- 卸载系统服务：设置 → 核心 → 卸载。旧版本遗留的 root core 可在同页“清理”。
- ad-hoc 签名包首次启动可能需要在“系统设置 → 隐私与安全性”中放行。
- EasyTier 采用 LGPL-3.0；内置二进制为官方 v2.6.4 未修改版本，许可与来源见 `App/Resources/EasyTier`。
