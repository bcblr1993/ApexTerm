# ApexTerm 更新日志 (Changelog)

本项目的版本记录严格遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/) 与 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范。

---

## [v1.2.2] - 2026-09-26

### ✨ 新增特性 (Features)
- **SFTP 全场景传输任务中心与记录可视化 (Comprehensive Transfer Tracking & Records)**：
  - **4 大传输链路 100% 全量入库**：全面打通并接管“点击下载”、“拖拽下载（导出至访达/桌面）”、“点击上传”、“拖拽上传（拖入面板/终端）”全生命周期；
  - **底层异步任务流统一抽象**：在 `TransferManager` 中增加外部传输生命周期接管能力（`beginExternalTransfer`、`updateExternalProgress`、`completeExternalTransfer`、`failExternalTransfer`），无论是系统拖拽手势还是本地队列均拥有瞬时速率、分片字节、进度与完成时间追踪；
  - **工具栏与底栏双常驻显式入口**：
    - SFTP 顶部工具栏新增显式 **“传输记录 (N)”** 按钮，传输中自动呈现动态旋转指示器与“传输中 (N)”高亮徽标，支持一键切换展开/收起；
    - 顶部传输通知气泡（如“拖拽导出完成: xxx.sql”）升级为**可交互直达链接**，点击即可立即展开任务详情；
    - 底部状态栏增加实时传输概要指示器（展示进行中任务数、总带宽吞吐或历史总数）；
  - **任务抽屉体验深度升级 (`TransferDrawer`)**：
    - 新增 **“全部 / 上传 / 下载”** 三态分类筛选器；
    - 任务列表明确标识 `[上传]` (蓝) / `[下载]` (绿) 专属标签与端到端完整路径映射；
    - 已完成的下载任务增加 **“在访达中显示”** (Reveal in Finder) 快捷按钮，支持一键打开本地目录并定位高亮文件。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **全量测试与 Tart VM 验收门禁**：新增 `testAllFourTransferScenariosRecordInTransferManager`，92 项自动化单元与功能测试 100% 通过（0 failures）；
- **Swift 6 编译器规范**：严格并发模式下保持 0 警告（Zero Warnings）。

---

## [v1.2.1] - 2026-09-26

### ✨ 新增特性 (Features)
- **SFTP 远程文件与目录无缝拖拽至本地任意目录 (Drag & Drop to Finder)**：
  - 突破传统 SFTP 仅支持右键菜单下载的限制，支持直接在远程文件列表中抓取任意文件或目录，自由拖拽至 macOS Finder 窗口、桌面或任意本地文件夹；
  - 深度实现 AppKit / UniformTypeIdentifiers 标准契约，在 `NSItemProvider` 注册 `UTType.fileURL` (`public.file-url`)、文件特定 MIME/扩展类型以及通用二进制流，消除 Finder 拖拽拦截符号；
  - 拖拽手势触发瞬间即在后台异步并发预下载（Pre-fetch），并在用户释放（Drop）时提供进度追踪与无缝落盘；
  - SCP 传输引擎深度增强：全面支持递归传输 (`-r`) 与私钥路径参数 (`-i`)，支持多级嵌套子目录完整拖拽下载；
  - 封装高复用性与强可测性的 `SFTPDragExportHelper` 组件，并补齐端到端单元测试。

### 🐞 问题修复 (Bug Fixes)
- **修复“关于”面板缺少关闭操作通道问题**：
  - 在“关于”面板 (`AboutView`) 右上角引入原生标准圆形关闭按钮 (`xmark.circle.fill`)；
  - 在操作链接栏新增显式“关闭”按钮；
  - 深度绑定键盘响应机制：完整支持 `Esc` 键、`⌘W` 快捷键与 Enter/Space 键一键退出面板；
  - 同步为快捷键速查面板 (`ShortcutsSheetView`) 补齐 `.onExitCommand` 与 `⌘W` 关闭支持。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **全量测试与 Tart VM 验收门禁**：91 项自动化单元与功能测试 100% 通过（0 failures）；
- **Swift 6 编译器规范**：严格并发模式下保持 0 警告（Zero Warnings）。

---

## [v1.2.0] - 2026-09-25

### ✨ 新增特性 (Features)
- **定制原生“关于”面板 (`AboutView`)**：
  - 拦截系统默认空白对话框，提供高分辨率 App 图标、版本与构建号徽标；
  - 呈现硬件架构标签（Apple Silicon arm64、Metal 120Hz、Native SSH / SFTP、Swift 6 Native）；
  - 内置一键“检查更新”按钮与开源主页直达。
- **在线版本更新引擎 (`UpdateManager` & `UpdateSheetView`)**：
  - 支持 SemVer 语义化版本严格比对算法，自动解析 GitHub Releases 规范元数据；
  - 提供非阻塞异步检查状态机，并在发现新版本时弹出结构化更新日志与直接下载引导；
  - 支持启动时自动静默检查新版本（可在偏好设置中自由启闭）。
- **原生 macOS 偏好设置中心 (`SettingsView`, `⌘,`)**：
  - **通用设置**：自动更新检查开关、当前版本展示、终端提示音模式（声音 / 视觉闪烁 / 静音）、一键恢复默认；
  - **终端外观**：等宽字体选择器（SF Mono、Menlo、Monaco、Courier、JetBrains Mono、PingFang SC）、字号无级调节、3 种光标形状（竖线 / 方块 / 下划线）、光标闪烁开关、5 套官方精选配色（Apex Dark、OLED Black、Solarized Dark、Monokai Pro、One Dark），并提供实时排版预览小窗；
  - **操作习惯**：划选自动复制开关、鼠标右键直接粘贴开关、终端回滚历史缓冲区行数设置；
  - **SFTP 传输**：显示隐藏文件、终端与 SFTP 目录联动开关、默认下载目录路径选择器、并发传输上限；
  - **数据备份与迁移**：一键导出所有会话为 `sessions.json`、一键导入合并已有配置。
- **服务器会话跨机迁移与备份 (`SessionStore`)**：
  - 新增 `exportSessionsJSON()` 与 `importSessionsJSON(from:overwrite:)`，并集成进系统主菜单栏（`文件` -> `导出/导入服务器会话`）。
- **键盘快捷键速查表 (`ShortcutsSheetView`, `⌘/`)**：
  - 结构化归类列出所有常用快捷键与鼠标高效操作。

### ⚡️ 体验优化 (Improvements)
- **终端动态外观即时重载**：`NativeTerminalView` 响应式监听 `AppSettings` 变更，无需重启应用即可热切换配色方案、字号、字体与光标样式；
- **右键粘贴习惯可配置**：支持在偏好设置中切换右键直接粘贴模式（开启时右键直通粘贴，按住 Shift+右键弹出系统菜单；关闭时右键展示标准菜单）；
- **菜单栏深度原生集成**：全量补齐应用菜单、文件管理、会话分屏与清屏、帮助体系。

### 🐞 问题修复 (Bug Fixes)
- **修复点击“检查更新”闪退崩溃 (SIGSEGV / EXC_BAD_ACCESS)**：
  - 排查定位崩溃日志 `ApexTerm-2026-09-25-225927.ips`，根因为 `L10n.swift` 中 `upToDateDesc` 使用了 C 语言字符串格式化说明符 `%s` 传入 Swift 原生 `String`，导致 Apple Silicon arm64 架构下 `_platform_strlen` 访问无效指针内存；
  - 全面修正格式化占位符为标准 Foundation 对象说明符 `%@`；
  - 优化关于面板的模态弹窗层级逻辑，避免 SwiftUI 多重 Sheet 渲染冲突，直接在关于面板内无缝展示最新稳定版本徽标与更新检查状态；
  - 新增 `testUpdateStringFormattingDoesNotCrash` 格式化安全回归测试。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **Tart VM 验收与全量自动化测试套件**：
  - 90 项自动化测试用例（覆盖 ApexSSHTests 与 ApexCoreTests）全部通过（0 failures）；
  - 新增 `ComprehensiveFeatureTests`，全量覆盖 SSH 会话生命周期、Agentless 指标解析、SFTP 权限格式化与任务取消、RingBuffer ECMA-48 控制序列、VTParser TrueColor 解析、分屏容器及 Snippet 参数插值等核心功能；
  - 集成 `scripts/test_vm_acceptance.sh`，支持在独立 Tart 虚拟机环境中完成用例验证与发布门禁拦截；
- **8 大性能基准测试实测数据**：
  - [Benchmark 1] RingBuffer 写入吞吐：**64,822 行/秒** (6.55 MB/秒)
  - [Benchmark 2] ANSI / TrueColor 颜色解析速度：**189,789 spans/秒** (单 span 5.27 μs)
  - [Benchmark 3] 内存水位与驻留集 (RSS)：初始 87.84 MB，峰值 152.09 MB，熔断机制正常
  - [Benchmark 4] 16 线程高并发争用写入吞吐：**1,165,499 writes/秒**
  - [Benchmark 5] 64 核 Linux 无代理系统指标解析速度：**10,655 次/秒** (单次 93.85 μs)
  - [Benchmark 6] OpenSSH 500 主机批量解析吞吐：**102,503 hosts/秒**
  - [Benchmark 7] SFTP 任务中心 100 任务并发调度性能：**1,133 tasks/秒**
  - [Benchmark 8] 终端物理按键直通全链路打字延迟：**7.23 微秒 (μs)**
- **安全签名**：全量通过 `Developer ID Application: YanNan Chen (5984KQD4D7)` 官方开发者证书代码签名，通过严格深度递归验签。

---

## [v1.1.1] - 2026-09-25

### 🐞 问题修复 (Bug Fixes)
- **方向键行内移动与历史命令乱码修复**：
  - 重构 `RingBuffer` 缓冲区，引入 `TerminalCell` 单元格模型与 `cursorCol` 精准列定位；
  - 彻底修复按左箭头时将 `\x08`（BS）误当作退格删除字符的缺陷；
  - 完整支持 ECMA-48 控制序列（`\x1b[C`、`\x1b[D`、`\x1b[@`、`\x1b[P`、`\x1b[K`），完美支持 Linux Bash 上下箭头历史命令切换覆盖；
  - 动态计算光标屏幕渲染坐标，光标在行内插入与移动时光标实时精准跟随。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增 `testArrowKeysAndInlineEditing` 与行内交互回归测试；
- 日志直通与单元格编辑双轨模式下，普通海量日志吞吐依然保持 **111,000+ 行/秒**。

---

## [v1.1.0] - 2026-09-25

### ✨ 新增特性 (Features)
- **无感实时性能监控 (Agentless Monitor)**：
  - 纯原语 SSH 会话后台采集 CPU、内存、网络与磁盘指标，无需在目标服务器安装任何 Agent；
- **终端目录联动 (OSC 7)**：
  - 终端 `cd` 切换远程目录时，下方 SFTP 文件面板实时同步切换路径；
- **Metal 120Hz 硬件加速终端渲染**：
  - 专为 Apple Silicon ProMotion 打造的丝滑终端流渲染层。
