# 实施计划

详细设计见 `docs/plan/easytier-feature-plan.md`。

当前状态：M4（对接方案 v2：常驻系统服务、长连接 RPC、IP 租约与看门狗，见 `docs/plan/core-integration-v2.md`）已实现；M1（配置 + core + 主界面/日志）、M2（Peers/Routes/菜单栏/流量）与 M3（TUN 授权启动、登录启动）已实现；WireGuard 门户、通知、ACL/DNS/凭据等仍待实施。

## 1. 语义转换与配置层

- [x] 替换 `ServerProfile/ServerGroup` 为 `NetworkProfile/NetworkGroup`
- [x] 网络配置 CRUD + 分组/收藏/禁用
- [x] TOML 导入/导出与 `--check-config` 校验
- [x] 配置持久化 + Keychain 网络密钥

## 2. 核心与运行时

- [x] 内置 `easytier-core` 的下载、固定版本、校验和
- [x] `CoreSupervisor`：启动/停止/状态机/异常退出
- [x] 无 TUN 模式（普通用户）跑通
- [x] 原生 EasyTier RPC：ZCPacket + protobuf，node/peer/route/traffic（不依赖 easytier-cli）
- [x] 日志采集与过滤

## 3. 主界面改造

- [x] 网络列表 + Inspector + 连接条接真实状态
- [x] Peers 窗口（替换 Connections）
- [x] Routes 窗口（替换 Rules）
- [x] 日志窗口接真实日志
- [x] 菜单栏 `MenuBarExtra` 与快捷启停
- [x] 设置页重排（General/Core/About）

## 4. TUN 与系统集成

- [x] 常驻 root 系统服务（launchd 守护进程，一次授权安装/更新/卸载，状态显示在 设置 → 核心）
- [ ] 改用 SMAppService.daemon + XPC（需要 Developer ID）
- [x] ~~授权启动 root core（AuthorizationExecuteWithPrivileges 过渡方案）~~ 已被系统服务取代
- [x] 登录启动、自动连接（SMAppService + 每网络 Auto Connect）
- [ ] 流量统计（当前使用 core stats；utun 接口计数器未接入）

- [x] 虚拟 IP 自动获取：租约沿用 + 冲突检测 + 卡住自动重启 + 应用侧选址
- [x] 启停提速：长连接 RPC、去掉 `--check-config` 子进程、daemon 同步应答停止

## 5. 网络服务

- [x] SOCKS5 开关与地址复制（配置 + 连接条）
- [x] 子网代理 / 手动路由 / 出口节点（配置）
- [x] 端口转发规则（编辑器文本配置）
- [ ] WireGuard 门户与客户端
- [ ] 通知

## 6. 安全与进阶

- [ ] ACL 编辑/统计、TCP/UDP 白名单
- [ ] 魔法 DNS（配置项已接入，系统 DNS 未应用）
- [ ] Secure Mode / 临时凭据
- [ ] P2P/KCP/QUIC/加密/MTU 高级设置（常用项已接入）
- [ ] Core 版本更新、CLI 安装、远程配置
- [ ] 中英文本地化与无障碍

## 7. 构建与分发

- [x] `project.yml` 嵌入 core/cli，`Scripts/build.sh` 先签 helper
- [x] DMG 打包回归
- [x] LGPL-3.0 许可与源码声明
