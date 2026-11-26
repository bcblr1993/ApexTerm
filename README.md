# ⚡ AetherTerm

Aether Native 系列的纯原生 SSH 终端与 SFTP 运维工作台。官网：[AetherTerm](https://aethernative.com/apps/aetherterm/)。

> 源码模块、Swift Package 产物与钥匙串/配置目录为保持向后兼容沿用历史内部标识，详见 [docs/branding.md](docs/branding.md)。

<div align="center">

[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-black?style=for-the-badge&logo=apple)](https://www.apple.com/macos/)
[![Architecture](https://img.shields.io/badge/Arch-Apple%20Silicon%20(M--Series)-orange?style=for-the-badge&logo=apple)](https://www.apple.com/mac/)
[![Language](https://img.shields.io/badge/Swift-6-F05138?style=for-the-badge&logo=swift)](https://swift.org)
[![Rendering](https://img.shields.io/badge/Render-Metal%20%7C%20120Hz%20ProMotion-blue?style=for-the-badge)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

**专为 Apple Silicon 深度定制的下一代纯原生 SSH 远程运维工作台**

[核心特性](#-核心特性) • [竞品对比](#-核心竞品全维度对比) • [技术架构](#-技术架构) • [快速开始](#-快速开始) • [质量门禁](#-质量与测试规范-release-gate)

</div>

---

## 🌟 为什么做 AetherTerm？

在 macOS 上进行远程服务器管理和日常开发，开发者长期忍受着传统工具链的“不可能三角”：
- **electerm**：终端 + SFTP 联动工作流顺手，但 **Electron 架构沉重、高延迟、内存占用高、大日志易假死**；
- **FinalShell**：实时查看服务器 CPU、内存、网络波形很方便，但 **Java Swing 内存占用高**，高分屏渲染容易发虚；
- **SecureCRT**：稳健可靠、会话管理强大，但 **界面与交互停留在旧时代**，缺少现代 macOS 原生体验。

**AetherTerm 将三者之长融为一体，并以 100% 纯原生 Swift 6 + AppKit / SwiftUI + Swift Charts 打造轻量、极速且安全的全能终端工作台。**

---

## 🚀 核心特性

### 1. ⚡ 极致原生引擎与现代终端协议
- **极速启动与超低内存**：纯原生 Apple Silicon 编译机器码，常驻内存约 **35MB**；
- **防卡死环形缓冲与 120Hz 渲染**：零拷贝 `TerminalRingBuffer` 支持十万行级回滚与跨行光标回溯编辑，`cat` 大日志依然跟手；
- **现代终端协议与交互增强**：
  - **OSC 8 超链接与 `file:line[:col]` 智能跳转**：支持 `⌘+点击` 终端中的 OSC 8 链接与相对/绝对文件路径（自动解析当前工作目录并跳转定位行号）；
  - **OSC 133 命令块时间线与失败命令跳转**：提示符边界追踪、退出码与耗时徽章、命令块时间线弹窗及最近命令输出一键提取（`⌘⌥C`）；
  - **触发器引擎、正则查找与亮暗适配**：支持规则高亮、桌面通知与可选自动响应（默认关闭并带冷却防回声环保护），支持 `.*` 正则/`Aa` 大小写终端查找与 `SGR 2` 暗淡字效；
  - **DEC 2026 同步输出 & OSC 52 安全剪贴板**：抑制 TUI 刷新闪烁，`拒绝 / 每次询问 / 允许写入` 三级策略严格阻断远端读取本机剪贴板；
  - **OSC 9 / 777 桌面通知与后台长命令提醒**：长耗时任务完成自动发送原生 macOS 通知，点击通知直达对应终端标签页。

### 2. 📊 无侵入式实时监控、进程与容器运维
- **零安装探针 (Agentless)**：远端无需部署守护进程，复用 SSH 轻量通道采集 CPU、内存、Swap、磁盘及网络吞吐；
- **Swift Charts 动态仪表盘**：标题栏微型胶囊一键展开或钉住右侧分栏查看实时波形与历史曲线；
- **进程、端口与容器/Systemd 运维**：内置 Top 进程检查器（支持核心进程保护与 SIGTERM/SIGKILL/SIGHUP）、监听端口扫描，以及无代理 **Docker / Podman 容器实时指标（CPU / 内存 / 网络 IO）** 与 **Systemd 服务日志 (`journalctl`)** 实时查看。

### 3. 📁 高吞吐 SFTP、实时日志追踪与双栏文件对比
- **终端 + SFTP 联动与实时 `tail -F`**：支持 **OSC 7 路径自动同步**、可点击交互路径面包屑、本地/远程双栏文件管理（`LocalDualPaneView`）、远端日志流式追踪面板（`RemoteLogTailSheet`，>1MB 日志免下载直看）、远端压缩打包/解压（`.tar.gz` / `.zip`）、`find`/`grep -F` 远端搜索与断点续传/SHA-256 校验；
- **内置快速编辑与外部编辑器热同步**：内置语法高亮与编码/换行符切换编辑器（支持与远端版本双窗格 Diff 对比），同时支持用 **VS Code / Cursor / Zed / CotEditor** 等本机外部编辑器打开远程文件并实时监听保存自动回传。

### 4. 🌐 ControlMaster 连接复用池、多主机协同与环境安全围栏
- **SSH ControlMaster 连接复用池 (`SSHControlMasterPool`)**：同主机、端口、密钥与跳板机链的多标签页、SFTP 传输、后台监控与批量任务自动复用已认证主通道，消除重复 2FA/密码握手；
- **多主机分屏、广播围栏与批量模板**：支持 `1×2` / `2×1` / `1+2` / `2×2` 多窗格布局与无损放大（保留查找与滚动位置），支持按标签页勾选广播目标、`[PROD]` / `[STAGING]` / `[DEV]` 环境分级标签与生产环境高危二次确认，以及可复用批量运维命令模板；
- **SSH 端口转发与隧道自动重连**：支持 Local (`-L`) / Remote (`-R`) / Dynamic SOCKS5 (`-D`) 隧道指数退避自愈重连、多跳 `ProxyJump (-J)`、Agent 转发 (`-A`)、压缩 (`-C`) 与自定义 `ProxyCommand`；
- **iCloud v2 多设备同步与工作区快照**：支持基于墓碑传播与时间戳胜出的 **iCloud Cloud Vault v2** 同步及冲突差异预览（`iCloudConflictDiffSheet`），支持零凭据工作区快照保存/启动恢复，以及 AES-256-GCM 加密的 `.aetherpack` 分组分享包。

### 5. 🛡️ Touch ID 应用锁、加密密钥保险库与审计脱敏
- **Touch ID / 系统密码应用锁**：支持 `⌘⇧L` 一键锁定、闲置自动锁定与切至后台自动锁定，锁定后使用 `.ultraThinMaterial` 毛玻璃遮罩彻底隐藏终端、SFTP 与凭据内容；
- **敏感操作二次验证**：查看已保存密码/私钥口令、导出含凭据 `.aetherpack` / `.aetherkeyvault` 备份包、查看/复制/导出保险库私钥前强制 Touch ID 或系统密码鉴权；
- **加密密钥保险库 (`.aetherkeyvault`) 与审计脱敏**：支持导出/导入强口令加密的 `.aetherkeyvault` 全库备份、`-cert.pub` OpenSSH 证书自动发现与验证；会话审计日志支持自动脱敏私钥 PEM、Bearer Token 与密码输入提示并内置审计日志查看器（`0o600` 权限落盘）。

---

## 📊 核心竞品全维度对比

| 对比维度 | **AetherTerm (本项目)** | **electerm** | **FinalShell** | **SecureCRT** |
| :--- | :--- | :--- | :--- | :--- |
| **底层技术栈** | **Swift 6 + AppKit + SwiftUI** | Electron + Node.js | Java + Swing / AWT | C++ / WxWidgets |
| **适配平台** | **macOS 14+ (Apple Silicon 原生)** | 跨平台 (Win/Mac/Linux) | 跨平台 (Win/Mac/Linux) | 跨平台 |
| **空闲常驻内存** | **~35 MB** | 450 MB ~ 800 MB | 600 MB ~ 1.2 GB | ~120 MB |
| **实时服务器监控 & 容器** | **原生 Swift Charts + 无代理 Docker/Systemd** | 基础插件 | 支持 | 无 |
| **SFTP 联动 & 热同步** | **OSC 7 联动 + 外部编辑器热同步** | 支持 | 手动刷新 | 独立窗口 |
| **应用锁与凭据安全** | **macOS Keychain + Touch ID 应用锁与敏感操作门禁** | 基础本地加密 | 本地配置加密 | 本地加密配置 |

---

## 🏗️ 技术架构

```text
ApexTerm/
├── Package.swift                      # 针对 Apple Silicon 优化的 Swift 6 Package 清单
├── Sources/
│   ├── ApexTerm/                      # 应用程序入口 (@main)、全局命令、通知代理与锁定遮罩挂载
│   ├── ApexUI/                        # 原生界面层 (SwiftUI + AppKit + Swift Charts)
│   │   ├── Security/                  # AppLockOverlayView 毛玻璃隐私锁定界面
│   │   ├── Workspace/                 # 主工作台 (终端 + 分屏 + SFTP + 命令面板 + 快捷命令栏)
│   │   ├── Dashboard/                 # 实时性能监控、进程检查器、Docker/Systemd 面板
│   │   ├── SFTP/                      # 高性能 SFTP 浏览器、外部编辑器同步、传输队列
│   │   ├── Sidebar/                   # 会话树、分组分享 (.aetherpack)、SSH Config 导入
│   │   ├── Settings/                  # 多标签偏好设置、密钥保险库、Known Hosts 审查
│   │   ├── Tunnel/                    # SSH 端口转发与 SOCKS5 隧道管理
│   │   └── Broadcast/                 # 多主机广播与批量分发交互条
│   ├── ApexTerminal/                  # 终端仿真核心 (RingBuffer, VTParser, ShellIntegration, Highlighter)
│   ├── ApexSSH/                       # SSH / SFTP / Agentless 探针 / PTY / Terminfo 探测驱动
│   ├── ApexSSHBridge/                 # 沙盒辅助凭据桥接进程
│   └── ApexCore/                      # 领域模型、存储同步与安全基座
│       ├── Models/                    # Session, SSHTunnel, SSHKeyIdentity, ServerMetrics 等
│       ├── Security/                  # AppLockManager, KeychainStore, SharePackCrypto, KnownHosts 等
│       └── Storage/                   # SessionStore, iCloudSyncManager, SSHKeyVaultManager 等
└── Tests/
    ├── ApexCoreTests/                 # 核心模型、同步、加密与 Keychain 单元测试
    └── ApexSSHTests/                  # 终端引擎、SSH/SFTP、应用锁、UI 回归与基准测试
```

---

## 🛠️ 快速开始

### 系统需求
- **硬件**：配备 Apple Silicon（M1 / M2 / M3 / M4 或更高版本）的 Mac 电脑
- **操作系统**：macOS 14.0+
- **工具链**：Xcode 16+ / Swift 6.0+

### 本地编译与运行
```bash
# 1. 克隆代码仓库
git clone https://github.com/bcblr1993/ApexTerm.git
cd ApexTerm

# 2. 运行自动化测试套件（零警告门禁）
swift test -Xswiftc -warnings-as-errors

# 3. 运行调试版本
swift run ApexTerm

# 4. 构建发布优化版
swift build -c release
```

---

## 🧪 质量与测试规范 (Release Gate)

为保证产品在高并发输出、多主机运维与安全场景下的绝对稳定性，AetherTerm 在每次版本发布前均严格执行自动化质量门禁（详见 [TEST_SCENARIOS.md](TEST_SCENARIOS.md) 与 [AGENTS.md](AGENTS.md)）：
- **Swift 6 `-warnings-as-errors` 零警告编译门禁**；
- **全量 XCTest 回归矩阵**：覆盖核心存储与加密（`ApexCoreTests`）、终端仿真与协议、SSH/SFTP/隧道、应用锁与敏感操作安全门禁、UI 对齐与跨主题渲染，以及 Tart VM 真实 Linux 链路验收；
- **8 大 Release 性能基准测试（`FullPerformanceBenchmarkTests`）**：对 RingBuffer 写入吞吐、ANSI 着色速度、RSS 内存水位、16 线程并发写入、Agentless 指标解析、OpenSSH 配置解析、SFTP 队列调度与按键直通延迟进行逐版压测校验。

---

## 📜 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。
