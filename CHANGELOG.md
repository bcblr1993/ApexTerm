# ApexTerm 更新日志 (Changelog)

本项目的版本记录严格遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/) 与 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范。

## [v1.3.0] - 2026-09-26

### ✨ 新增特性 (Features)
- 新增 12 种全局主题：经典白色（默认）、VS Code Dark Modern、Tokyo Night、Catppuccin Mocha / Latte、Nord、Dracula、One Dark Pro、Gruvbox Dark、Everforest、Rosé Pine、Solarized Light。
- 主题覆盖侧栏、工作区、设置、弹窗、按钮、状态、文字、选区、终端及查找栏；切换无需重连 SSH，已有 ANSI 索引色输出同步更新，显式 TrueColor 保持原样。
- 包含服务器硬件、磁盘 SSD / NVMe / HDD 类型展示及紧凑监控详情界面。

### ⚡️ 体验优化 (Improvements)
- UI 文字、状态色及主题终端索引色自动调整明度，至少保持 4.5:1 对比度；原生控件跟随主题明暗外观。
- 统一主题持久化与恢复默认行为，兼容旧终端预设名称。

### 🐞 问题修复 (Bug Fixes)
- 修复 SGR TrueColor 中 0 / 1 通道被误判为重置或加粗，以及切换配色覆盖历史 TrueColor 的问题。
- 修复模拟 SSH 会话并发连接、重连时连接状态的内存竞争。
- 示例主机使用文档保留地址，避免真实私网地址被当作模拟会话。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 全量 117 项测试零失败，其中 4 项未配置公共服务器的测试跳过；真实 Tart VM 的 PTY / SFTP 往返 / 指标 / 磁盘 4 项全部通过。
- 优化构建 8 项基准全部达标：134,584 行/秒（13.60 MB/秒）、406,348 spans/秒、RSS 102.66 MB、2,201,121 writes/秒、指标 12,891 次/秒、125,043 hosts/秒、1,108 tasks/秒、单键 8.76 微秒。
- 新增主题对比度、历史输出切换、ANSI / TrueColor 与并发模拟连接回归测试；12 种主题均完成窗口渲染检查。
- 正式包强制 Developer ID、安全时间戳、Apple 公证和 stapling；扫描二进制与资源中的凭据及私网端点，保留旧安装备份。

## [v1.2.5] - 2026-09-26

### ✨ 新增特性 (Features)
- **SFTP 基础文件系统操作完整闭环与体验升级 (P1)**：
  - **远程文件与目录基础操作闭环**：
    - 新增远程文件与文件夹删除能力，集成 macOS 原生二次防误删确认对话框 (`confirmationDialog`)，明确提示文件名称与不可逆永久删除风险；
    - 新增文件夹新建 (`新建文件夹...`) 与空文件创建 (`新建文件...`) 弹窗输入；
    - 新增项目就地重命名 (`重命名...`) 功能，支持修改文件及目录名称；
    - 底层通过 SSH ControlMaster 复用连接通道与原生 POSIX 语义原子执行，并在 MockSSHSession 中提供高保真并发内存文件系统支持；
  - **多字段灵活列排序**：
    - 新增“名称”、“大小”、“修改日期”列头可点击排序 (`SFTPSortField`) 与升降序切换 (`SFTPSortOrder`)，直观箭头标识当前排序依据；
    - 目录始终保持置顶，子项按选定排序字段精确排列；
  - **隐藏文件过滤切换**：
    - 支持快捷键 `⌘⇧.` 或工具栏按钮一键显隐以点号 `.` 开头的隐藏系统文件与配置文件；
  - **右键上下文菜单与操作栏联动**：
    - SFTP 面板右键菜单与底部工具栏全面集成：下载、重命名、删除、新建文件夹、新建文件与刷新。
- **终端断线重连、自由双分屏比例拖拽、标签双击重命名 (P2)**：
  - **会话断线优雅悬浮横幅与重连机制**：
    - 终端连接断开或异常中断时，在终端内浮现磨砂半透明提示横幅：“会话已断开”，提供显式“重新连接 (⌘R)”高亮按钮；
    - 绑定快捷键 `⌘R`，随时随地一键重连当前断开分屏或会话；
  - **双分屏自由调比拖拽手柄 (Free Split Dragging & Ratio)**：
    - 分屏视图 (`WorkspaceActiveTabSplitView`) 重构为响应式 `GeometryReader` 动态布局；
    - 垂直分屏与水平分屏中间嵌入原生拖拽分割条，用户可自由拖拽调整主副分屏面积占比（`[0.15, 0.85]` 安全范围保护），彻底告别固定 50:50 死板布局；
  - **自定义标签页重命名与双击快捷编辑**：
    - 终端标签页支持双击直接呼出“重命名标签页”弹窗，或通过标签右键菜单选择“重命名标签页...”；
    - 支持输入自定义标题（如“生产数据库 01”、“Web 网关”），输入留空或点击“恢复默认名称”可随时一键恢复为服务器主机名；
    - 工作台顶部标题栏与标签栏全局原子联动展示 `tab.displayTitle`。
- **终端内嵌 ⌘F 查找、URL 智能检测与 ⌘+Click 直达、Top 5 进程监控 (P3)**：
  - **终端内嵌原生查找条 (In-View Find Bar)**：
    - 按下 `⌘F` 或在终端右键菜单选择“查找 (Find)...”即刻呼出内嵌悬浮查找面板；
    - 实时动态统计并展示匹配总数与当前序号（如 `3/12` 或 `0 结果`）；
    - 支持 `Enter` / 下箭头跳转下一个匹配项，`⇧Enter` / 上箭头跳转上一个匹配项，`⌘G` / `⌘⇧G` 快捷切换，`Esc` 退出查找并恢复终端焦点；
    - 采用 `NSLayoutManager.addTemporaryAttribute` 零开销高亮所有匹配项（当前匹配项高亮橙色，其余匹配项明黄色），并自动平滑滚动定位至可视区域；
  - **URL 智能检测与 ⌘+Click 浏览器直达**：
    - 终端原生集成 `NSDataDetector` 与 URL 解析引擎，智能检测终端输出中的网络链接（HTTP/HTTPS/SSH/FTP），精准过滤末尾附带的句号、括号等标点；
    - 按住 `⌘` (Command) 键悬停于链接上方时，鼠标指针自动变为点击小手 (`pointingHand`)，点击即可直接在默认浏览器中打开链接；
    - 终端右键菜单智能检测鼠标落点或当前选中文本是否包含链接，若存在则在菜单顶端新增“在浏览器中打开链接”直达项；
  - **轻量无代理 Top 5 进程资源监控**：
    - 底层 `AgentlessMonitor` 在极速探针中无缝采集 Linux 与 macOS 的 Top 5 CPU 资源占用进程（PID, User, CPU%, Mem%, Command）；
    - 顶部监控胶囊弹窗 (`MetricCapsuleView`) 中新增“Top 进程资源占用”实时列表，高 CPU 占用进程智能标记警示色，弹窗支持丝滑纵向滚动浏览。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **全量测试与 Tart VM 验收门禁**：新增 `SFTPOperationsTests` (5 个单元测试) 与 `TerminalFindAndURLTests` (5 个单元测试)，全量 106 项自动化测试 100% 通过（0 failures）；
- **8 大性能基准测试全部达标**：RingBuffer 吞吐 ≥ 50,000 行/秒、ANSI 解析 ≥ 150,000 spans/秒、RSS 峰值 155MB (≤ 250MB 门禁)、并发写入吞吐 1,026,137 writes/秒、Linux 指标解析 8,892 次/秒、OpenSSH 批量解析 83,916 hosts/秒、SFTP 并发调度 1,101 tasks/秒、单键全链路延迟 8.50 微秒；
- **Swift 6 编译器规范**：严格并发模式下保持 0 警告（Zero Warnings）。

---

## [v1.2.4] - 2026-09-26

### 🐞 问题修复 (Bug Fixes)
- **修复分屏后原终端黑屏无内容及切换后无法输入缺陷 (Split Pane Black Screen & Input Loss)**：
  - **终端视图即刻重水化渲染机制 (Buffer Rehydration)**：修复在执行分屏（垂直分屏 `⌘D` 或水平分屏 `⌘⇧D`）及关闭分屏回退到单屏时，原处于就绪/空闲状态的会话因无新网络字节流到达而导致终端全黑的问题。在 `TerminalRepresentable.makeNSView` 挂载瞬间立即调度 `refresh()`，从底层 `RingBuffer` 瞬间同步恢复所有历史行、ANSI 配色与当前命令行 Prompt；
  - **AppKit 与 SwiftUI 跨层双向焦点无缝联动 (Bidirectional Focus Coordination)**：
    - 移除分屏外层容器冲突的 `.contentShape(Rectangle()).onTapGesture`，消除对 AppKit 鼠标点击事件的拦截遮蔽；
    - 在终端获取第一响应者（`becomeFirstResponder`、`mouseDown`、`rightMouseDown`）时派发 `onFocus` 回调，实时对齐 SwiftUI 中的 `tab.activePaneId`；
    - 当分屏激活状态变更（`isFocused == true`）时，`updateNSView` 自动通知窗口 `makeFirstResponder`，确保键盘事件精准路由至对应分屏；
  - **分屏模式平滑横纵切换与标题智能规范**：
    - 当已有 2 个分屏时，按下 `⌘D` 或 `⌘⇧D` 支持直接在横向与纵向分屏模式之间平滑切换；
    - 关闭某一分屏后，剩余分屏名称自动规整复原为干净主机名，消除残留的“（分屏）”后缀。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **全量测试与 Tart VM 验收门禁**：新增 `testSplitPaneRehydrationAndFocusManagement` 与 `testSplitPaneModeTogglingAndTitleReset` 单元测试，全量 95 项自动化测试 100% 通过（0 failures）；
- **Swift 6 编译器规范**：严格并发模式下保持 0 警告（Zero Warnings）。

---

## [v1.2.3] - 2026-09-26

### ✨ 新增特性 (Features)
- **复制会话 (Duplicate Session) 与多维标签管理**：
  - **标签页右键菜单 (Context Menu)**：在任意终端标签页上右键即弹出完整上下文菜单，支持“复制会话”、“垂直分屏 (⌘D)”、“水平分屏 (⌘⇧D)”、“关闭标签页 (⌘W)”、“关闭其他标签页”以及“关闭右侧标签页”；
  - **无缝状态与路径继承**：复制会话时自动继承原标签的主机连接配置、认证凭据、目录联动配置 (`isDirectoryLinkageEnabled`) 以及当前远端所在工作目录 (`currentRemotePath`)，并在相邻位置 (`idx + 1`) 插入全新 SSH 终端标签立即建立连接；
  - **显式 UI 快捷入口**：
    - 标签栏末尾新增常驻 `+` 快捷按钮，支持一键基于当前活跃会话快速克隆新标签页；
    - 工作台顶部操作栏 (`WorkspaceHeaderBar`) 新增显式复制会话按钮 (`plus.square.on.square`)，带有悬浮提示；
  - **系统原生菜单与快捷键支持**：
    - 菜单栏“会话”及“文件”菜单新增“复制当前会话到新标签页”；
    - 深度贴合 macOS 终端原生肌肉记忆：`⌘T` 智能复制当前会话（无标签时连接侧边栏选中主机），`⌘⇧T` 显式强制复制会话；
  - **快捷键速查面板同步对齐**：在快捷键面板 (`ShortcutsSheetView`) 中增加 `⌘T` / `⌘⇧T` 复制会话与标签右键操作指引。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **全量测试与 Tart VM 验收门禁**：新增 `testDuplicateTabSessionStateAndInheritance` 单元测试，全量 93 项自动化测试 100% 通过（0 failures）；
- **Swift 6 编译器规范**：严格并发模式下保持 0 警告（Zero Warnings）。

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
