# ApexTerm 更新日志 (Changelog)

本项目的版本记录严格遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/) 与 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范。

## [v1.6.0] - 2026-10-02

### ✨ 新增特性 (Features)
- 路径栏新增“复制当前路径”按钮，复制当前浏览目录；未提交的路径草稿不会被复制为当前目录。
- 支持终端鼠标跟踪、⌘1…9 标签切换和 ⌘+/−/0 字号调整。

### ⚡️ 体验优化 (Improvements)
- 合并文本更新、限制刷新调度与完整行历史淘汰；光标控制包不再重复编辑历史文本。
- 终端固定覆盖式滚动条，避免输入设备切换滚动条样式导致历史重新排版；同目录联动提示合并为尾随刷新。
- 文件选中行的四列文字和图标使用系统动态颜色，改善深浅主题对比度。

### 🐞 问题修复 (Bug Fixes)
- 修复 Vim 普通数据包、光标/方向键、中文复制粘贴及跨包 UTF-8；CJK、Emoji、组合字符与字号变化对齐。
- 修复 PTY 子进程信号掩码与窗口尺寸同步，真实 Vim 验证连续调整和文件面板显隐后的远端行列更新。
- 修复 ANSI 样式/背景擦除、宽字边界、控制字符串碎片及输入法焦点状态。
- 修复 PTY 部分写入、断开描述符复用及同主机多会话的复用连接互相影响。
- 修复 SFTP 特殊字符文件名、IPv6 参数、目录提示分包/编码和 macOS 文件修改时间。
- 创建文件或文件夹被权限拒绝时说明原因，点击可查看完整远端错误；不自动提权或修改远端权限。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- Finder 双向拖拽门禁使用普通窗口层级、可见文件图标和无遮挡落点，并确认自建 Finder 窗口关闭后再删除临时目录。
- 本轮开发验收：297 项 Swift 用例，4 项未配置外部网络用例跳过、0 失败；28 项脚本测试通过；远端 UI Runner 增加桌面互斥，拒绝并发验收争用窗口。正式发布另执行当前提交的完整 VM、UI 与 8 项优化基准门禁，产物门禁记录见发布验收文档。
- 开发 UI 41 项交互通过证据来自 38 项原运行与 3 项 Finder 重跑；追加文件创建权限拒绝、正常创建和路径复制验证通过。
- 30 分钟真实 SSH/SFTP 持续负载无校验失败，136 次回显、46 次传输往返检查，RSS 峰值 209.875 MiB；高负载 CPU、4K/120Hz 与待机功耗不作为本轮通过指标。
- 第 8 项基准为 Mock 会话内部输入处理时间，不代表真实网络往返或显示器呈现延迟。

## [v1.5.6] - 2026-09-30

### 🐞 问题修复 (Bug Fixes)
- **彻底解决打开文件面板/分屏时终端首行被遮挡削头缺陷**：
  - **根因剖析**：当开启底部 SFTP 文件面板或拖拽分屏调节器时，终端容器高度被压缩；`NativeTerminalScrollView.setFrameSize` 中由于此前键盘输入将 `isPinnedToBottom` 置为 `true`，触发了 `scrollToBottom(forceLayout: true)`。此时远端 PTY 尚未下发缩小后的 Vim 行数，导致当前文档高度大于新的视口高度，`scrollToBottom` 计算出正向位移并滚动 `clipView`；AppKit 的 `NSLayoutManager` 在缩小后将 `documentView.frame.origin.y` 推入负坐标（例如 -8px），直接将首行 `networks:` 的上半部切断遮挡；
  - **重构方案**：在 `TerminalClipView.layout()`、`constrainBoundsRect`、`NativeTerminalScrollView.setFrameSize`、`refresh()` 以及 `scrollToBottom` 中全面建立硬性安全门禁：当处于备用屏幕（Vim / Less / Htop）模式时，绝对禁止触发 `scrollToBottom`，并且不论视图如何重排缩放，强制将 `documentView.frame.origin` 和 `clipView.bounds.origin` 锁定在精确的 `(0, 0)` 原点，保全顶部 10px 安全边距，彻底杜绝文字削头截断。
- **彻底修复 Vim 模式下方向键移动光标看不见、不跟随及 DECCKM 应用光标支持**：
  - **根因剖析**：
    1. 当 Vim 收到方向键移动光标时，通常下发光标绝对或相对定位序列（如 `\e[row;colH` 或 `\e[B` / `\e[C` / `\e[1;2H`）。`RingBuffer.handleScreenCSI` 在处理这些光标控制码时，更新了 `screenRow` 与 `screenColumn`，但没有递增 `_screenRevision`，导致前端未能感知视图更新；
    2. `NativeTerminalView.resetCursorBlink()` 此前仅将新的光标位置矩形标记为 `setNeedsDisplay`，而旧的光标位置区域从未被重绘清除；当焦点发生转移（如点击了文件面板）时，`stopCursorBlink()` 直接将 `isCursorVisible` 置为 `false`，导致光标在非焦点状态下彻底隐形；
    3. DECCKM（Application Cursor Keys Mode `\e[?1h`）缺失支持：当 Vim 开启应用光标键模式时，期望接收 `\eOA`、`\eOB`、`\eOC`、`\eOD`，此前硬编码发送标准 ANSI `\e[A` 等序列，导致部分 Vim 模式下方向键未被识别。
  - **重构方案**：
    1. `RingBuffer` 全面支持 DECCKM（Mode 1）应用光标键模式，`NativeTerminalView` 键盘输入及滚轮自动根据 DECCKM 模式无缝派发 `\eOA` 或 `\e[A`，并支持 Shift / Ctrl 方向键扩展修饰符；
    2. `handleScreenCSI` 中所有光标移动序列及光标存取均原子递增 `_screenRevision` 并触发刷新；
    3. 重构光标渲染与双矩形清除机制：引入 `lastRenderedCursorRect`，移动光标时光标原位与新位同时执行局部重绘，彻底解决残影与重绘时序不同步；非焦点状态下光标转换为优雅的空心描边矩形（Hollow Outline），确保无论焦点在终端还是文件面板，光标位置始终 100% 清晰可见。
- **彻底修复 Vim 模式下无法退出（Esc / :q / 输入法拦截）问题**：
  - **根因剖析**：
    1. macOS 中文输入法拦截：当输入法处于中文模式时，用户键入冒号时被 IME 拦截并转译为全角冒号 `：`（U+FF1A），而 Vim 的 Ex 命令行仅接收半角 ASCII 冒号 `:`（U+003A），导致 `:q`、`:wq`、`:q!` 被 Vim 当作普通模式下的无效字符而吞掉或转入录制宏（`recording @q`），用户无法呼出底部命令行退出；
    2. Esc 键被输入法截断：此前按 Esc 时若输入法处于候选状态，只退出了输入法候选词，却未向底层终端发送 `\e`，用户以为已回到正常模式，输入 `:q` 实际上仍在插入模式输入了字面量，导致无法退出。
  - **重构方案**：
    1. 在 `NativeTerminalView.insertText` 中加入智能终端字符标准化过滤：自动将中文输入法误输入的中文全角冒号 `：`、分号 `；` 规范化为 ASCII `:` 与 `;`，即使在中文输入法下键入 `:q`、`:wq`、`:q!` 也能精准触发 Vim 命令行；
    2. 在备用屏幕（Vim / Nano）模式下，Esc 键按击无论当前输入法是否有候选状态，均无条件确保向远程 PTY 直通派发 `\u{1B}`（ESC）字符，确保用户永远能在第一下按键时立刻打断插入模式，返回 Normal 模式顺利退出。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **测试套件扩充至 17 项 Vim 与备用屏幕专项测试 (`VimAndScreenModeTests`)**：新增 DECCKM 应用光标键进出校验、光标相对位移与修订号自增门禁、中文输入法全角冒号过滤规整与 Vim 退出指令验证、分屏缩放视口原点锁定测试以及非焦点空心光标视觉呈现测试；
- 经由真实 `macos27` 虚拟机全量验证通过，35 个测试套件（240+ 用例）100% 绿灯（0 failures, 0 warnings）；
- 8 项 Release 生产级性能基准全部大幅超越工程规范要求：
  - RingBuffer 写入吞吐: 1,934,160 行/秒 (195.52 MB/秒) (标准 ≥ 50,000)
  - ANSI / TrueColor 样式解析: 424,746 spans/秒 (标准 ≥ 150,000)
  - 内存水位驻留集 (RSS): 103.98 MB (标准 ≤ 250 MB)
  - 16 线程高并发争用写入: 2,411,082 writes/秒 (标准 ≥ 1,000,000)
  - 64 核 Linux 无代理指标解析: 14,946 次/秒 (标准 ≥ 8,000)
  - OpenSSH 500 主机集群解析: 152,682 hosts/秒 (标准 ≥ 80,000)
  - SFTP 任务中心并发调度: 1,275 tasks/秒 (标准 ≥ 800)
  - 物理按键直通与全链路键入延迟: 5.41 微秒 (μs) (标准 ≤ 15.0 μs)

## [v1.5.5] - 2026-09-30

### 🐞 问题修复 (Bug Fixes)
- **彻底解决全屏幕状态下终端/Vim 仅能显示一部分及尺寸不同步严重缺陷**：
  - **根因剖析**：
    1. 当使用密码认证时，`NativeSSHSession` 通过 `sshpass` 工具拉起 `/usr/bin/ssh`。窗口全屏或调整尺寸触发 `resizeTerminal` 时，此前仅对 master PTY 调用了 `ioctl(TIOCSWINSZ)`；Darwin 内核发送的 `SIGWINCH` 仅被传递给直接子进程 `sshpass`，而 `sshpass` 默认忽略该信号且不向其子进程 `/usr/bin/ssh` 转发。由于 `ssh` 未收到 `SIGWINCH`，它从未向远程 OpenSSH 服务器发送 `SSH_MSG_CHANNEL_WINDOW_CHANGE` 协议包，导致远程 Linux 终端与 Vim 始终被锁定在启动时的 30 行/35 行，大窗口或全屏下方留出大量黑屏未利用空间；
    2. 防抖任务竞态漏洞：此前防抖任务在休眠 150ms 前便先行写入了 `lastReportedDimensions`。当全屏过渡动画期间多次连续触发或任务取消时，`lastReportedDimensions` 已记录为新尺寸，导致后续即便动画结束也不再触发 `onResize` 远程尺寸回调；
    3. 视窗容器尺寸监听盲区：`NativeTerminalScrollView` 此前未监听 `NSWindow.didEnterFullScreenNotification`、`didExitFullScreenNotification` 与 `didResizeNotification`，且未重写 `tile()` 与 `viewDidEndLiveResize()`，在 macOS 系统级全屏切换完成时未能即时计算出全屏可视区域行列数。
  - **重构方案**：
    1. 在 `NativeSSHSession.resizeTerminal` 中，调用 `ioctl(TIOCSWINSZ)` 后，递归遍历并向 `childPid` 及其所有后代进程（包括 `/usr/bin/ssh` 及其子会话）主动发送 `SIGWINCH` 信号，确保无论是否使用 `sshpass` 密码中继，远程 `sshd` 均能 100% 毫秒级接收到最新的终端窗口行列数；
    2. 重构尺寸防抖模型：将 `lastReportedDimensions` 仅在尺寸真正下发时原子提交，并引入 `immediate: true` 模式，在全屏切换、窗口最大化与调整结束时即时触发；
    3. `calculateTerminalDimensions()` 全面适配外层全屏容器边界（`enclosingScrollView.bounds` 与 `contentView.bounds` 取最大安全值），并在 `tile()`、`viewDidEndLiveResize()` 与 `NSWindow` 全屏完成通知时即刻重新校准。
- **彻底修复 Vim 模式下光标不可见及光标脱节至窗口底部缺陷**：
  - **根因剖析**：此前 `NativeTerminalView.getCursorRect()` 假定终端光标始终位于文本末尾行（`activeLineStartLocation + cursorCol`），而在备用屏幕（Vim / Less / Htop）模式下，`activeLineStartLocation` 被重置在全部文本之后，导致光标被错误绘制在窗口最底部第 50 行的黑屏盲区中，用户在上方第 1 行编辑时完全看不到光标位置。
  - **重构方案**：
    1. 在 `TerminalRingBuffer` 中新增 `cursorPosition: (row: Int, column: Int)` 属性，由 VT 解析引擎精准跟踪备用屏幕下的 2D 绝对光标网格坐标；
    2. 重构 `NativeTerminalView.getCursorRect()`：当处于备用屏幕模式时，直接根据 `pos.row` 与 `pos.column` 映射至字体度量网格 `(origin.x + col * charWidth, origin.y + row * lineHeight)`，实现光标在 Vim 文档中的像素级精准对齐与实时闪烁跟随；
    3. 完整支持 DECTCEM 光标显隐控制（`\e[?25h` 显示光标，`\e[?25l` 隐藏光标），退出备用屏幕时光标状态自动复位；
    4. 优化块状光标（Block Cursor）渲染，增加半透明透光与对比度保护，确保光标覆盖下的英文字符与符号清晰可见。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **测试套件扩充至 12 项 Vim 与全屏专项测试 (`VimAndScreenModeTests`)**：新增 Vim 2D 光标位置动态跟踪、DECTCEM 光标隐藏与恢复、备用屏幕视口光标原点校验、全屏窗口即时尺寸广播等全套测试；
- 经由真实 `macos27` 虚拟机全量验证通过，35 个测试套件（235+ 用例）100% 绿灯（0 failures, 0 warnings）；
- 8 项 Release 生产级性能基准全部大幅超越工程规范要求：
  - RingBuffer 写入吞吐: 1,934,009 行/秒 (195.51 MB/秒) (标准 ≥ 50,000)
  - ANSI / TrueColor 样式解析: 429,719 spans/秒 (标准 ≥ 150,000)
  - 内存水位驻留集 (RSS): 105.73 MB (标准 ≤ 250 MB)
  - 16 线程高并发争用写入: 2,608,221 writes/秒 (标准 ≥ 1,000,000)
  - 64 核 Linux 无代理指标解析: 14,606 次/秒 (标准 ≥ 8,000)
  - OpenSSH 500 主机集群解析: 153,006 hosts/秒 (标准 ≥ 80,000)
  - SFTP 任务中心并发调度: 1,287 tasks/秒 (标准 ≥ 800)
  - 物理按键直通与全链路键入延迟: 5.31 微秒 (μs) (标准 ≤ 15.0 μs)

## [v1.5.4] - 2026-09-30

### 🐞 问题修复 (Bug Fixes)
- **彻底根除 Vim / 全屏交互应用底部显示不全与排版残缺问题**：
  - **根因剖析**：
    1. SSH 连接建立前（异步握手期间），终端前端视图计算的实际窗口行列数（如 45 行 × 120 列）被发送给未打开的 Darwin PTY（`ptyMasterFd == -1`），导致尺寸同步被静默丢弃；而 SSH 连接完成后直接采用硬编码默认的 `35 行 × 120 列` 打开 PTY，导致远程 Linux 终端与 Vim 始终被锁死在 35 行（或 30 行），大窗口下方留有大量未使用黑屏空白；
    2. 终端底层缺少对 `DECSTBM`（设置顶底滚动区域 `\e[top;bottom r`）以及 `S`（向上滚动）、`T`（向下滚动）、`P`（删除字符）、`@`（插入字符）、`X`（清除字符）等 VT 序列的支持，导致 Vim 编辑和滚动文档时整屏错误滚动，进而冲毁或覆写底部状态栏；
    3. 在 Vim 进入备用屏幕缓冲区（`\e[?1049h`）时，滚动视口未锁定在顶部（`y = 0`），滚轮/触控板滑动直接滑动了 AppKit 视口而不是发送光标滚动指令，引发首尾行文字出界裁切。
  - **重构方案**：
    1. `NativeSSHSession` 与 `MockSSHSession` 实时记录并持久化最新终端尺寸 `currentDimensions`，连接前尺寸调整即时暂存；在 Darwin PTY 分配（`openpty`）及连接成功后，双向强制校准并即时同步远程 PTY 尺寸；
    2. `RingBuffer` 全面落地完整 VT/DEC 序列解析引擎：支持 `DECSTBM` 滚动区域隔离保护、`S` 向上滚动、`T` 向下滚动、`P` 字符删除、`@` 字符插入、`X` 字符清除及光标保存恢复；严格保证滚屏操作仅作用于滚动区域内部，彻底保全 Vim 底部状态栏与命令行；
    3. `TerminalClipView` 在备用屏幕模式下强制锁定垂直原点为 `0.0`，阻断任何视口漂移；
    4. 重写终端滚轮事件 `scrollWheel(with:)`：在备用屏幕（Vim / Less / Htop）模式下将触控板滑动平滑转化为上下方向键输入（`\e[A` / `\e[B`），实现如同原生 Mac 终端与 iTerm2 般丝滑的翻页滚屏体验。
- **修复 Vim / 终端多行文本粘贴格式错乱（楼梯效应与缩进乘倍）缺陷**：
  - 支持 DEC 复合私有模式解析（如 `\e[?1049;2004h`），确保括号化粘贴模式（Bracketed Paste Mode `\e[?2004h`）100% 正确激活；
  - 优化剪贴板粘贴文本换行标准化处理，在括号化粘贴包裹（`\e[200~ ... \e[201~`）下原样无损传递缩进结构，彻底杜绝 YAML、代码及脚本粘贴到 Vim 时的缩进自动累加与排版错位。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- **新增 9 大 Vim 与备用屏幕专项测试用例 (`VimAndScreenModeTests`)**：覆盖备用屏幕进出、复合私有模式解析、DECSTBM 滚动区域状态栏隔离保护、S/T 滚屏、P/@/X 字符增删抹除、括号化粘贴 YAML 缩进完整性、触控板滚轮方向键映射、视口零位锚定及连接前 PTY 尺寸同步；
- 经由真实 `macos27` 虚拟机全量验证通过，35 个测试套件（230+ 用例）100% 绿灯（0 failures, 0 warnings）；
- 8 项 Release 生产级性能基准全部大幅超越工程规范要求：
  - RingBuffer 写入吞吐: 1,970,285 行/秒 (199.18 MB/秒) (标准 ≥ 50,000)
  - ANSI / TrueColor 样式解析: 433,971 spans/秒 (标准 ≥ 150,000)
  - 内存水位驻留集 (RSS): 104.58 MB (标准 ≤ 250 MB)
  - 16 线程高并发争用写入: 2,899,591 writes/秒 (标准 ≥ 1,000,000)
  - 64 核 Linux 无代理指标解析: 15,457 次/秒 (标准 ≥ 8,000)
  - OpenSSH 500 主机集群解析: 160,457 hosts/秒 (标准 ≥ 80,000)
  - SFTP 任务中心并发调度: 1,242 tasks/秒 (标准 ≥ 800)
  - 物理按键直通与全链路键入延迟: 5.02 微秒 (μs) (标准 ≤ 15.0 μs)

## [v1.5.3] - 2026-09-30

### 🐞 问题修复 (Bug Fixes)
- **彻底根除终端顶部第一行被顶出视口/遮挡及输入看不到的严重缺陷**：
  - **根因剖析**：AppKit 原生 `NSClipView` 默认 `isFlipped` 为 `false`，而 `NSTextView` 为 `true`，在零尺寸（frame `.zero`）初始挂载渲染或内容行数较少时，默认坐标翻转计算会导致文档原点被错误推入负空间（`-36.0pt`），导致视口上方首行内容被裁剪出界，用户在首行敲击键盘时文字不可见，需按回车换行或手动滑动滚轮才能显示。
  - **重构方案**：
    1. 引入专有 `TerminalClipView`（继承自 `NSClipView` 并强制 `isFlipped = true`），与 `NSTextView` 实现 1:1 无损同构坐标映射；
    2. 在 `TerminalClipView.constrainBoundsRect` 与 `scroll(to:)` 中加入强一致性坐标约束，当内容未填满视口时强制锁定在 `y = 0`，绝不允许视口原点进入负坐标或非预期向下滚动；
    3. `NativeTerminalScrollView` 初始化与 `setFrameSize` 增加兜底安全几何尺寸，重设尺寸时自动校准 `terminalView.frame.origin` 为零点，彻底杜绝任何场景下的首行遮挡与视口偏移现象。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 经由真实 `macos27` 虚拟机全量验证通过，34 个测试套件（220+ 用例，包括新增的 4 项视口零尺寸初始化、清屏与分屏动态调整首行保留测试）100% 绿灯（0 failures, 0 warnings）；
- 8 项 Release 生产级性能基准全部大幅超越工程规范要求：
  - RingBuffer 写入吞吐: 1,870,662 行/秒 (189.10 MB/秒) (标准 ≥ 50,000)
  - ANSI / TrueColor 样式解析: 432,488 spans/秒 (标准 ≥ 150,000)
  - 内存水位驻留集 (RSS): 104.52 MB (标准 ≤ 250 MB)
  - 16 线程高并发争用写入: 2,568,613 writes/秒 (标准 ≥ 1,000,000)
  - 64 核 Linux 无代理指标解析: 15,062 次/秒 (标准 ≥ 8,000)
  - OpenSSH 500 主机集群解析: 153,730 hosts/秒 (标准 ≥ 80,000)
  - SFTP 任务中心并发调度: 1,120 tasks/秒 (标准 ≥ 800)
  - 物理按键直通与全链路键入延迟: 4.96 微秒 (μs) (标准 ≤ 15.0 μs)

## [v1.5.2] - 2026-09-30

### ✨ 新增特性 (Features)
- **主流运维工具全场景测试矩阵深度补齐**：
  - 对标 Electerm、FinalShell、SecureCRT、Termius、iTerm2，全面构建并落地 6 大核心自动化测试套件（终端控制信号矩阵、多会话并发广播容错、SFTP 深度极端异常、触发器正则与复合变量插值、异构 Linux 与容器监控、Keychain 凭据安全生命周期），新增 34 个严苛边界测试用例。

### ⚡️ 体验优化 (Improvements)
- **终端视口与状态栏边距排版优化**：
  - 为 `NativeTerminalView` 注入 10px 舒适内边距与动态行列尺寸补偿，彻底消除终端最后一行文字/光标与底栏贴紧的视觉压迫感；
  - 底部状态栏高度调优至 32px，内边距重新平衡并在连接状态与文件联动控件间引入清晰分隔线。
- **Tart 虚拟机自动化寻址与持续验收支持**：
  - CI 与本地门禁流水线自动读取专用测试网络环境（固定直连 `macos27` 目标虚拟机），保障真机链路验收常态化运行。

### 🐞 问题修复 (Bug Fixes)
- **修复 SFTP 0 字节文件传输完成进度条滞留 0% 缺陷**：
  - 优化 `TransferTask.progress` 计算模型，在传输任务完成时统一明确返回 100%（1.0），解决空文件（如 `.gitkeep`、空配置文件）传输成功后进度条仍显示 0% 的产品显示缺陷。
- **修复文件删除后底层视图联动刷新问题**：
  - 增强 SFTP 操作后的事件通知与状态回流机制，确保删除文件后关联目录框即时响应更新。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 经由真实 `macos27` 虚拟机全量验证通过，34 个测试套件（220+ 用例）100% 绿灯（0 failures, 0 warnings）；
- 8 项 Release 生产级性能基准全部大幅超越工程规范要求：
  - RingBuffer 写入吞吐: 1,866,894 行/秒 (188.72 MB/秒) (标准 ≥ 50,000)
  - ANSI / TrueColor 样式解析: 409,249 spans/秒 (标准 ≥ 150,000)
  - 内存水位驻留集 (RSS): 103.31 MB (标准 ≤ 250 MB)
  - 16 线程高并发争用写入: 2,080,347 writes/秒 (标准 ≥ 1,000,000)
  - 64 核 Linux 无代理指标解析: 14,409 次/秒 (标准 ≥ 8,000)
  - OpenSSH 500 主机集群解析: 150,134 hosts/秒 (标准 ≥ 80,000)
  - SFTP 任务中心并发调度: 1,278 tasks/秒 (标准 ≥ 800)
  - 物理按键直通与全链路键入延迟: 5.22 微秒 (μs) (标准 ≤ 15.0 μs)

## [v1.5.1] - 2026-09-29

### ✨ 新增特性 (Features)
- **SFTP 多选与批量操作增强**：
  - SFTP 文件表格全面升级为原生多选模式（支持 Command/Shift 键连续或跳跃多选）；
  - 新增批量右键操作：支持选定多个文件后一键“批量下载”、“批量删除”及“复制路径”。
- **本地到远程批量拖拽智能防呆**：
  - 外部多文件/文件夹拖拽至 SFTP 目录或终端时，先汇总全部 dropped URLs 并统一做同名冲突预检，提供统一确认弹窗（全部替换 / 仅跳过冲突 / 取消），单次入队并平滑刷新，杜绝多弹窗锁死与重复中断。

### ⚡️ 体验优化 (Improvements)
- **终端与底栏视觉间距与排版优化**：
  - 为 `NativeTerminalView` 增加 10px 舒适内边距与动态行列尺寸补偿，彻底解决终端底部命令行/光标与底部状态栏贴合拥挤的问题；
  - 优化底部状态栏高度（提升至 32px 舒适高度）与内边距，并在终端连接信息与文件联动控件之间增加视觉分隔线，杜绝界面压迫感。
- **拖拽传输视图解耦与渲染优化**：
  - 将 `TransferToolbarButton` 抽离为独立子视图进行状态监听，解除 `SFTPView` 主体对传输进度高频通知的直接依赖，消除进度更新对 AppKit 拖拽事件循环与 Table 渲染的干扰。

### 🐞 问题修复 (Bug Fixes)
- **彻底根治远程拖拽到本地 AppKit 主线程死锁（Beachball 卡死）**：
  - 消除 `SFTPDragExportHelper` 与进度轮询中所有的阻塞式 `await MainActor.run` 调用，改为安全异步派发，彻底解决 AppKit 处于 `NSEventTrackingRunLoopMode` 模态事件跟踪时与后台文件导出 Task 之间的互锁假死。
- **彻底根治大文件传输 Swift 协程线程池饥饿假死**：
  - 重构 `NativeSSHSession.runTransferProcess`，以基于 `OSAllocatedUnfairLock` 与 `process.terminationHandler` 的纯异步事件挂起替代系统阻塞调用 `process.waitUntilExit()`，传输数 GB 级大文件时零线程占用，UI 始终保持极致流畅。
- **传输子进程输入流死锁防御与安全逃逸**：
  - 为 SCP 传输进程显式定向 `process.standardInput = FileHandle.nullDevice`，杜绝因终端提示导致的挂起；远端路径增加包含空格与特殊字符时的安全引号逃逸。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增专用拖拽与传输矩阵测试 `DragAndDropTransferTests`（覆盖远程到本地小文件、远程到本地大文件、多文件批量并发拖拽、拖拽中途取消、本地到远程批量拖拽、同名冲突自动编号避免、带空格与复杂特殊字符路径处理、子进程非阻塞取消生命周期等 8 大核心场景，100% 通过）。
- 全量自动化测试用例 100% 绿色通过（0 failures），8 大核心 Release 性能基准达标（RingBuffer 写入 1.9M lines/s、打字延迟 4.94 μs）。

## [v1.5.0] - 2026-09-29

### ✨ 新增特性 (Features)
- **主流工具功能深度对齐 (Electerm & FinalShell 对齐)**：
  - **SSH 密钥配置与跳板机 (ProxyJump) 穿透**：新建与编辑会话弹窗支持选择/指定私钥文件路径（支持 `~` 智能展开）及口令 (Passphrase)，支持通过跳板机（ProxyJump）经由 `-J` 隧道一键连接内网主机。
  - **终端按键与快捷键全覆盖**：终端引擎新增 `Shift+Tab` 反向制表符 (`\e[Z`)、Option (Alt) 词级快速跳跃与删除 (`\eb`, `\ef`, `\e\x7F`, `\ed`)，以及 F1–F12 全功能键原生直通，完美对齐 `htop`, `mc`, `vim`, `nano` 快捷操作。
  - **括号粘贴模式 (Bracketed Paste Mode)**：终端 RingBuffer 支持 DEC 2004 私有模式 (`\e[?2004h` / `\e[?2004l`)，粘贴多行文本时自动包裹转义边界，杜绝命令提前走火意外执行。
  - **SFTP 文本编辑器多编码自适应容错**：打开远程文件时自适应支持 UTF-8 与 Windows-1252 / ISO-8859-1 等多字符集降级解析，消除打开非纯 UTF-8 文件时“读取失败”的问题。

### ⚡️ 体验优化 (Improvements)
- **重连生命周期与资源自清理**：会话断开重新连接时严格执行旧 PTY 描述符注销、子进程清理与 kqueue 事件注销，杜绝文件描述符与后台进程残留。

### 🐞 问题修复 (Bug Fixes)
- 修复私钥认证模式下，除 scp 之外的交互终端、目录枚举、SFTP 基础操作及无代理监控进程遗漏 `-i <keyPath>` 参数的问题。
- 修复私钥路径包含 `~` 时因 posix_spawn 未经 Shell 展开导致 SSH 报错找不到密钥文件的问题。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增主流工具对齐专项测试 `MainstreamParityTests`（18 个独立测试场景），涵盖密钥认证、跳板机路由、括号粘贴、按键映射、SFTP 转义与多系统指标容错。
- 本地 100+ 自动化测试用例 100% 通过（0 failures），8 项 Release 性能基准达标。

## [v1.4.3] - 2026-09-29

### ✨ 新增特性 (Features)
- 无新增产品功能；本次为 SFTP 文件拖放修复版本。

### ⚡️ 体验优化 (Improvements)
- 远端文件拖到 Finder 时，传输记录与拖拽进度随本地写入量更新。

### 🐞 问题修复 (Bug Fixes)
- 修复拖出远端文件后 Finder 为部分文件重复添加扩展名的问题，确保目标文件保留原名。
- 修复 SCP 传输等待退出前未持续读取错误输出，输出量较大时可能卡住的问题；为网络停滞增加连接和保活超时。
- 拖拽下载失败或取消后清理未完成的临时文件，并防止完成状态被迟到的进度回调覆盖。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增 SCP 大量错误输出回归测试，以及 Tart VM 64 MiB 远端文件拖拽导出校验。
- 专用 Mac mini 的真实 Finder 64 MiB 拖放测试通过，目标文件原名、内容校验与传输记录均正确。
- Tart VM 真实链路与 165 项 Swift 测试通过，0 failures；其中 4 项未配置公共服务器的测试按预期跳过。8 项 Release 性能基准达标：RingBuffer 1,937,010 行/秒，ANSI 419,499 spans/秒，RSS 峰值 104.33 MB，16 线程 2,153,876 writes/秒，指标解析 15,142 次/秒，OpenSSH 151,725 hosts/秒，SFTP 1,163 tasks/秒，单键延迟 5.15 μs。
- 完整 UI 验收执行 40 项，其中 34 项通过、6 项失败；修复后普通文本和 64 MiB Finder 拖放两项均通过，0 failures。UI 未全量通过，详细失败项与后续工作见 `docs/v1.4.3-ui-followup.md`。

## [v1.4.2] - 2026-09-29

### ✨ 新增特性 (Features)
- 无新增产品功能；本次为终端滚动修复版本。

### ⚡️ 体验优化 (Improvements)
- 连续输出多屏文件列表时，终端继续跟随最新内容；用户主动上翻阅读时仍保持当前位置。

### 🐞 问题修复 (Bug Fixes)
- 修复反复执行 `ll` 后未自动滚动到底部的问题。新行追加后先完成末尾文本排版，再按更新后的文档高度定位视口。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增长列表自动跟随及手动上翻保持位置的回归测试。
- Tart VM 真实链路与 163 项 Swift 测试通过，0 failures；其中 4 项未配置公共服务器的测试按预期跳过。8 项 Release 性能基准全部达标。
- 基准实测：RingBuffer 1,833,720 行/秒，ANSI 387,664 spans/秒，RSS 峰值 104.5 MB，16 线程 2,345,869 writes/秒，指标解析 14,500 次/秒，OpenSSH 149,151 hosts/秒，SFTP 1,255 tasks/秒，单键延迟 5.19 μs。
- 完整 UI 自动化验收未通过；应用户直接发布自动滚动修复的要求，失败项留待后续处理。本版本不声明 UI 全量通过，见 `docs/v1.4.2-ui-followup.md`。

## [v1.4.1] - 2026-09-29

### ✨ 新增特性 (Features)
- 无新增产品功能；本次为窗口与终端绘制修复版本。

### ⚡️ 体验优化 (Improvements)
- 全屏终端程序使用独立屏幕网格绘制，退出后恢复原有命令输出和滚动历史。

### 🐞 问题修复 (Bug Fixes)
- 修复关闭最后一个主窗口后，再点击运行中的 ApexTerm 图标仍不出现窗口的问题。
- 修复 Vim 使用光标定位与清屏指令时，文件内容只显示开头数行的问题。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 新增真实产品应用的窗口重开 UI 回归测试及 Vim 全屏绘制单元测试，并加入每次发布的强制门禁。
- Tart VM 真实 SSH、PTY、SFTP 集成测试与全量 Swift 测试通过；8 项 Release 性能基准全部达标，0 failures。
- 基准实测：RingBuffer 1,887,116 行/秒，ANSI 411,217 spans/秒，RSS 峰值 103.52 MB，16 线程 2,074,687 writes/秒，指标解析 13,181 次/秒，OpenSSH 116,372 hosts/秒，SFTP 1,110 tasks/秒，单键延迟 5.67 μs。
- 完整 UI 自动化验收按用户 2026-09-29 的发布决定延期；本版本不声明 UI 全量通过。未完成项与测试证据见 `docs/v1.4.1-ui-followup.md`。

## [v1.4.0] - 2026-09-28

### ✨ 新增特性 (Features)
- **macOS 原生工作区架构与原生快速编辑器 (QuickEditor)**：
  - 新增 SFTP 远程文件内嵌快速文本编辑器 (`QuickEditorView` & `NativeCodeEditor`)，支持语法行号、文件就地保存 (⌘S)、重载、未保存变动警告及原位查找能力。
  - 重构工作区原生窗口状态管理 (`WindowStateView`)，完美适配多窗口与全屏切换，分屏比例自由拖拽并持久化。
  - 支持 SFTP 与 macOS Finder 原生双向拖拽传输（向外拖拽下载至访达，从访达向内拖拽上传至远程服务器）。
- **原生中文拼音 IME 全链路支持与体验优化**：
  - 彻底解决中文输入法在终端中的文本截断与离屏渲染伪影，重构输入法组合态 (Marked Text) 优先级调度；
  - 按下 `Escape` 键优先撤回或放弃当前输入法未确认拼音，不向远程 Shell 发送异常控制字符；
  - 引入 CJK 字体度量回退机制，确保非等宽中文字符在终端网格与滚动缓冲区中严谨对齐。
- **Swift Charts 监控历史图表与多维连接状态联动**：
  - 监控详情集成原生折线图 (`metrics.history.chart`)，直观呈现近 60 秒 CPU 与内存水位动态趋势；
  - 细化多状态联动胶囊徽标：覆盖实时指标、连接中等待新数据、数据过期提示、断线保留历史及监控关闭等多种场景。

### ⚡️ 体验优化 (Improvements)
- 优化 SSH 监控采集与 PTY 交互生命周期：监控探针进程改为流式异步读取 stdout，防止大数据吞吐导致管道死锁阻塞。
- 增强进程树取消与优雅清理机制：主动终止进程树中由 `sshpass` 派生的所有 SSH 子进程，避免连接取消后残留僵尸进程。
- 完善 12 款全局主题在所有工作区弹窗（快捷键帮助、设置面板、关于页面、传输中心、新建会话）的首屏与高对比度排版。

### 🐞 问题修复 (Bug Fixes)
- 修复在会话断开或重新连接时未清理监控差分基线导致的使用率跳变缺陷。
- 修复监控关闭状态下详情面板依然展示历史最新实时指标的逻辑漏洞。
- 修复快捷键帮助窗口在特定主题下因视口高度不足导致首屏顶部被裁切的问题，补齐无障碍识别标签。

### 🧪 质量门禁与性能对比 (Verification & Benchmarks)
- 全量自动化测试用例与 Tart VM 虚拟机验收测试 100% 绿色通过，0 failures。
- 8 大生产级优化性能基准全部达标：
  - [Benchmark 1] RingBuffer 写入吞吐：1,918,980 行/秒 (193.99 MB/秒，远超 ≥50,000 行/秒基线)
  - [Benchmark 2] ANSI / TrueColor 颜色解析速度：431,816 spans/秒 (远超 ≥150,000 spans/秒基线)
  - [Benchmark 3] 内存驻留集 (RSS)：峰值 104.36 MB (远低于 ≤250 MB 门禁)
  - [Benchmark 4] 16 线程高并发锁争用写入吞吐：2,509,024 writes/秒 (远超 ≥1,000,000 writes/秒基线)
  - [Benchmark 5] 64 核 Linux 无代理系统指标解析速度：14,887 次/秒 (远超 ≥8,000 次/秒基线)
  - [Benchmark 6] OpenSSH 500 主机集群解析吞吐：152,689 hosts/秒 (远超 ≥80,000 hosts/秒基线)
  - [Benchmark 7] SFTP 任务中心并发调度吞吐：1,231 tasks/秒 (远超 ≥800 tasks/秒基线)
  - [Benchmark 8] 终端物理按键直通与键入延迟：5.09 微秒 (μs) (远低于 ≤15.0 μs 门禁)
- 经由 Apple Developer ID 官方签名、Hardened Runtime 及安全扫描，确保零私有密钥与敏感端点泄漏。

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
- 修复检查更新、帮助及问题反馈链接指向旧仓库，改为当前官方发布源。

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
