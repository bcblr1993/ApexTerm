# macOS 27 实施与验收记录

本记录对应 `macos27-alignment-plan.md`。只有存在可复核证据的项目才记为通过；设计实现、单元测试、真实窗口验收、签名候选包和正式发布分别记录。

## 当前实现

- 会话标题、复制、分屏、监控摘要和文件开关移入系统 toolbar，移除重复工作区标题条与页脚指标。
- 侧栏采用系统选中态，选中名称加粗。
- SFTP 使用原生 Table，支持列排序/宽度调整、选择、双击和上下文菜单；文件过滤按需显示，低频操作收纳至更多菜单。过滤/排序结果缓存，不随传输进度重复排序。
- 窗口可跟随系统明暗外观，终端保留用户选中的 12 主题配色；减少动态效果时停止循环传输状态动画。
- 编辑器采用 NSTextView、原生查找栏与可见行号标尺；行号随同一滚动视图移动。关闭/重新加载有未保存确认，保存期间的新编辑不会被错误标记为已保存。
- 恢复主窗口位置、文件面板开关与分隔比例、每会话远程目录；恢复目录不连接 SSH。
- 移除终端设置观察者和重复窗口观察者，停用非焦点/非激活窗口的光标闪烁；查找快捷键只路由到实际焦点终端。
- 监控超过 30 秒未收到数据时显示过期状态。

同工作区另有会话连接状态修复改动，已保留；本记录不将这些改动归为外观改造独立成果。

## 已验证证据

证据位于忽略目录 `outputs/macos27/`，不包含于分发包。

| 项目 | 实测与证据 |
| --- | --- |
| 原生主窗口 | `preview/main-white.png`，真实 SwiftUI App 窗口；包含原生 toolbar 和 Table |
| 编辑器 | `qa/editor.png`、`qa/editor-unsaved.png`、`qa/editor-find.png`；实际窗口已验证未保存确认、取消继续编辑、原生查找匹配及定位 |
| 基础全量测试 | `tests-editor.log`：101 SSH/UI + 19 Core，0 failures；8 项网络测试因未提供环境跳过 |
| 主题与生命周期回归 | `tests-restoration.log`：7 ProductFeature 测试通过，包括新增系统外观保留色板、目录恢复不重连、标签释放窗格测试 |
| 编译 | `build-native-editor.log`、`build-restoration.log`、`build-accessibility.log` 无编译警告/错误 |
| 受控原版空闲 | `baseline/controlled-idle.json`：60.692 秒，单核 CPU 0.676%，RSS 165.45–169.80 MB；旧版优化构建、固定虚构会话与文件目录 |

## 失败与待完成

- 早期采样 `baseline/idle-process.json` 受到键盘/鼠标/重连交互影响，不能作为空闲基线，禁止用于改善比例。
- 初次 VM 门禁因 VM 停止而失败；启动后 SSH 已连通，真实 VM 测试可运行。
- VM 重跑全量 Debug 测试失败：普通日志写入约 24,528 行/秒，RSS 180.1875 MB；分别低于 30,000 行/秒、略高于 180 MB 测试限制。保持原有门槛，处理后重跑。
- 普通 ASCII 日志整行写入优化及一致性测试已通过。Debug 针对性基准：261,135 行/秒、RSS 100.73 MB。
- 最新完整 VM 门禁通过：105 SSH/UI + 19 Core 测试，0 failures；4 个真实 VM 集成测试通过，4 个公共服务器测试未配置而跳过。
- 优化构建 8 基准通过：RingBuffer 1,897,497 行/秒 / 191.82 MB/秒，ANSI 420,760 spans/秒，RSS 99.47 MB，并发 2,198,255 writes/秒，指标 14,063 次/秒，SSH 149,936 hosts/秒，SFTP 1,291 tasks/秒，内部输入 5.14 μs。
- `vm-gate-final-iteration.log` 确认 Swift 6 零诊断；30 分钟组合负载已启动，尚未结束。
- 新版优化构建的同条件空闲、帧时间 P95、真实 PTY 回显、30 分钟组合负载尚待完成。
- 全主题关键页、窄窗口、分屏、SFTP 点击/拖拽可见结果、其余页面状态、系统无障碍设置和键盘流程尚待完整验收。
- 候选包签名、公证、安装、CI 与公开发布尚未执行。本记录不是发布完成证明。

## 最新门禁与复测（2026-09-27）

- `vm-gate-final.log`：106 SSH/UI 测试（4 个公共服务器测试未配置而跳过）及 19 Core 测试，0 failures；4 个真实 VM 测试通过。8 项 Release 基准通过，Swift 6 零警告。
- 最新基准：RingBuffer 1,319,366 行/秒 / 133.37 MB/秒；ANSI 256,443 spans/秒；RSS 98.59 MB；并发 2,579,597 writes/秒；指标 14,421 次/秒；SSH 149,693 hosts/秒；SFTP 1,251 tasks/秒；内部按键路径 5.28 μs。组合负载与其他验收 App 同时运行，不能将不同负载下的基准波动解释为回归。
- `pty-echo.json`：实际 NativeSSHSession → VM PTY → 输出回调，预热 10 次、有效 100 次，P50 19.95 ms、P95 26.88 ms。关闭远端输入回显，等待远端命令输出；不包括终端绘制帧。
- `directory-calls-com.apexterm.qa.flows2.json`：⌘L 输入期间无目录加载，Enter 后只加载一次，⌘F 焦点进入文件筛选框。
- `editor-final.png`、`editor-save-race.png`：原生查找栏 Done 后可再次 ⌘F 打开；异步保存期间继续输入，新内容仍触发未保存确认。已修正保存提示，明确显示仍有新更改待保存。
- 左右/上下分屏拖动改用起始比例加拖动位移，避免分隔条局部坐标导致比例跳变；8 项分屏测试通过，实际拖动仍待最终窗口复测。
- 导入验收发现可注入配置路径未参与扫描，已修正 scanHosts 使用指定配置路径；默认生产行为仍使用标准 SSH 配置。旧 `page-import.png` 读取了开发机配置，不作为合成验收证据，也不纳入提交或分发包。
- 空闲采样记录了 keyWindow；工具动作使窗口失去激活，当前连续前台样本不足 60 秒，不作为有效前台验收。帧时间、系统无障碍真实操作、最终候选包等待完成项目保持未通过状态。

- 已推送实现分支并创建 Draft PR #3，CI run 36289605932 运行中；当前不合并、不声明发布完成。
- 合成导入预览已复测，`page-import-synthetic.png` 只显示 RFC 示例地址主机。QA 工具同时修正 Finder 启动时工作目录变化导致合成配置与遥测路径错误的问题。
- 连续后台空闲有效样本（监控关闭）：`idle-background-summary.json` 中新版 IdleCandidate 64.10 秒，单核 CPU 0.254%，RSS 178.20–178.34 MB。原版区间更长且混有窗口操作，不能据此计算严格改善百分比；前台仍未得到连续 60 秒有效样本。

- 30 分钟组合负载已完成：`soak/progress.json` completed=true、failures=[]；822,720 行输出、103 次输入检查、35 次 256 KB 双向传输完整性检查、70 条可见任务记录；历史上限 50,000 行、监控历史 40 条。`soak/process-load.json` 采样 1,800.714 秒，峰值 RSS 228.41 MB，负载 CPU 单核 33.397%。此负载使用早期 Release 验收 App；之后的路径/焦点/文案/分屏改动已另行跑完整门禁，未宣称最终签名二进制完成同一 soak。
- CI run 36289605932 成功，后续 QA 路径修正 commit 10e4dfb 的 CI run 36289713399 尚在运行。
- Animation Hitches 请求录制 30 秒后未正常完成，trace 异常膨胀至约 23 GB，导出报 Document Missing Template Error；已停止本任务的录制进程，保留失败诊断，帧 P95 不作通过结论。


## 接续复核（2026-09-27）

- 当前工作区重跑 `vm-gate-resumed.log`：真实 VM 集成、全量测试、8 项 Release 基准全部通过，Swift 6 无警告。RingBuffer 1,903,094 行/秒、192.38 MB/秒；ANSI 403,691 spans/秒；RSS 98.27 MB；并发 2,095,057 writes/秒；指标 14,833 次/秒；SSH 149,670 hosts/秒；SFTP 1,154 tasks/秒；内部输入 5.49 μs。
- 传输失败提示的关闭按钮移出记录按钮，避免嵌套按钮影响命中与无障碍；随后 `tests-resumed-final.log` 全量 130 项测试零失败，9 项网络测试因无环境跳过。实际 VM 已在上一条独立门禁执行。
- 构建清理 4 项测试通过：只清理已识别生成物、保护运行中应用及符号链接目标、保留最近一份安装回滚备份；CI 加入同一检查。
- 真实隔离窗口验证终端点击焦点、⌘L 路径选择和 ⌘F 文件筛选焦点正常。
- `foreground-current-summary.json`：连续前台 62.00 秒（预热 15 秒后），单核 CPU 0.341%，RSS 196.39–196.48 MB；合成会话、监控开启、无传输。不是监控关闭场景，也不能用于同条件新旧改善比例。
- 旧提交 9005671 的 CI run 36289814547 已成功；本轮提交的 CI 必须另行确认。
- IdleProofOff 的 UI 读取两次超时，未据此宣称监控关闭前台采样通过。帧时间、完整系统无障碍操作和最终签名候选包仍须继续验收。

- 接续修复提交 `cfe61a7` 已推送，CI run 36291260780 正在运行。
- 实际产品 Release 二进制生成独立 `com.apexterm.candidate` 候选应用，版本仍标 1.3.0、内部构建 2026092701，未作为新正式版本发布。`candidate/` 中保存来源说明和 Apple 公证响应；敏感扫描、Developer ID 深度严格验签、公证 Accepted、staple/validate 均通过。Gatekeeper 返回 Notarized Developer ID，同时显示本机 security disabled，因此不把本机评估当作启用安全策略机器上的安装证明。

- 监控关闭的优化构建连续前台 67.00 秒有效采样（预热 15 秒后），单核 CPU 0.145%，RSS 169.47–179.69 MB；达到 ≤1% 目标。证据 `foreground-monitor-off-summary.json`，合成连接、无输出/传输。


## macOS 27 候选安装验证

- 将 `ApexTerm-Candidate-arm64.tar.gz` 复制到已有测试 VM，在新建临时目录解包，不替换 VM 现有 `/Applications/ApexTerm.app`。
- VM 系统版本 27.0，`spctl --status` 返回 assessments enabled；深度严格验签、stapler validate、Gatekeeper execute assess 全部通过，来源 Notarized Developer ID，无本机 security disabled 覆盖。
- `open` 启动成功，随后 `ps` 确认运行路径为本次临时安装的候选可执行文件。证据 `candidate/vm-install-verification.log`。这是安装、安全验证和进程启动证据；尚不替代 VM 实际窗口的完整操作验收。
- 候选包生成 DMG、tar.gz 和 SHA256SUMS，DMG 的最终公证与票据校验待记录；不上传为正式 release。

- DMG 公证 Accepted、staple/validate 通过；只读挂载卷名为 ApexTerm Candidate，包含候选应用及 Applications 符号链接，挂载包内严格验签通过。`candidate/dmg-inspection.json` 与最终 `SHA256SUMS.txt` 为证据。
- 实现提交 cfe61a7 的 CI run 36291260780 已完成成功；后续仅验收文档提交 224530d 的 CI 仍独立跟踪。

- 有界帧采样复试：xctrace Animation Hitches 请求 5 秒录制，超过 35 秒仍未完成，保护逻辑终止该录制进程；`frame-resumed-result.json` 记录退出码 1。未得到有效帧时间，仍不计为通过。下一步需更换可正常导出的采样路径并覆盖实际交互。


## 文件筛选键盘闭环

- 实际窗口发现 Escape 不退出文件筛选，已补齐关闭、清空筛选与文件表格焦点恢复。等待 SwiftUI 移除输入框后恢复焦点，避免焦点落回窗口。
- KeyboardFocus 真实窗口按 ⌘L → ⌘F → 输入 nginx → Escape：筛选隐藏、完整目录恢复，焦点为文件 outline；Down 选中首行后 ⌘F 再次进入筛选输入框。证据 `qa/keyboard-filter-exit.txt`。
- `tests-filter-escape.log` 全量 130 项测试零失败，9 项未配置网络环境跳过；编译无 warning/error。此次仅文件筛选交互变更，不将旧签名候选包声称为包含该修复的最终包，收尾时须更新候选包。


## 最终候选重建门禁

- `vm-gate-keyboard-final.log` 捕获局部递归函数访问 AppKit 的 actor 隔离警告，门禁拒绝构建。显式标注 MainActor，改用顺序遍历子视图后，`vm-gate-actor-final.log` 真实 VM、全量测试及 8 项 Release 基准全部通过，零 warning/error。
- 新增 `scripts/build_candidate.py`：要求已提交的干净工作区，保护运行中的旧候选，构建前清理准确命名的上一轮产物；执行真实 VM 门禁、Release 编译、安全扫描、签名、公证、DMG/tar.gz 和最终哈希生成，不替换已安装正式应用。
- 构建号取当天序号并严格高于上一候选；候选版本沿用当前 CHANGELOG 正式版本，清单记录精确来源提交，候选不冒充新正式发布。
- 候选清理新增保留无关文件与符号链接预检测试。共 6 项 Python 清理测试通过，CI 已包含全部清理测试。


## 最新候选产物（构建 2026092702）

- `build-signed-candidate-final.log` 完整候选流水线退出码 0，来源提交 `3d8857ccc8ee6a65613f3652c0d950855e20db29`，清单 `candidate/candidate-manifest.txt`。应用与 DMG 均公证 Accepted、staple/validate 通过，包含文件筛选 Escape 与焦点修复。
- 最新 DMG 只读挂载：卷名 ApexTerm Candidate，根目录仅候选应用及 Applications 链接，包内严格验签通过；最终 DMG/tar.gz 哈希与 SHA256SUMS 一致。
- `candidate/vm-install-verification-final.log`：macOS 27 VM assessments enabled，最新包严格验签、票据与 Gatekeeper 通过；进程检查确认新安装路径 `/private/tmp/apexterm-candidate.93wLEY/` 启动成功，未把仍运行的旧候选进程误认为新包。
- 有界帧 trace 导出仍报 Document Missing Template Error；失效数据占 7,314,867,520 字节，已清理本任务生成的这一目录，保留录制/导出错误及 `frame-resumed-cleanup.json`。没有有效交互帧 P95。
- 传输记录 sheet 复测时 Computer Use 截图两次报 zero-size capture；Escape 后返回原筛选输入框。只证明弹窗可关闭与焦点返回，不证明该次空态布局。
- VoiceOver/增强对比度/减少透明度实测的系统设置确认尚待用户回复，未擅自改变设置。整体计划仍未全项完成，候选包交付不等于全部 UI/性能/无障碍验收通过。


## 分隔条辅助操作

- 实际窗口创建左右分屏后，无障碍树缺少自绘分隔条。为左右/上下终端分隔条及终端/文件分隔条加入名称、百分比与 Increment/Decrement 动作，调整步长 5%，保持原拖动边界。
- AccessibleSplit 窗口实际动作通过：文件面板 70%→75%；左右分屏 50%→55%→50%；切换上下分屏后 50%→45%。证据 `qa/accessible-split-actions.txt`。这证明控件可被辅助技术发现与操作，不代替实际 VoiceOver 朗读流程。
- `tests-accessible-divider.log` 全量 130 项零失败（9 项无网络环境跳过），无 warning/error。
- 已交付 2026092702 候选包不包含本次分隔条增强；最终候选须重建后重新验收。


## 窗口交互补验

- `qa/monitor-disabled.png` 与 AX 文本验证监控关闭详情明确提示可在会话设置开启，无伪造实时指标。
- 两个终端窗格分别查找 ERROR：第一窗格 1/1，第二窗格 0 结果；Escape 分别返回对应终端。证据 `qa/pane-find-routing.txt`，合成会话窗口，不作为真实 SSH 内容证明。
- 包含分隔条增强的候选 2026092703 来源 fc8c0bd。应用公证 Accepted；DMG 首次提交 connectTimeout，仅重试该产物后 Accepted，并完成 staple/validate、最终哈希与来源清单生成。
- `candidate/vm-accessible-install.log`：新包在 macOS 27 VM assessments enabled 时通过严格验签/票据/Gatekeeper，确认新路径 `/private/tmp/apexterm-candidate.d1e1UW/` 的进程启动。
- 复制会话验收发现新标签焦点停在窗口，补齐可见窗口挂载后的终端焦点恢复，保留已有字段编辑保护。`tests-mounted-focus.log` 回归通过；`qa/copy-focus-proof.txt` 证明复制后自动落到新终端、无需再点击即可输入，模拟命令回调完成。
- 2026092703 候选尚不包含复制后焦点修复；最终包仍需更新。完整 VM 门禁 `vm-gate-copy-focus.log` 已通过：真实 VM、全量测试与 8 项 Release 基准通过，零 warning/error。

- 候选重建清理同时移除旧来源清单，避免公证中断时旧提交信息留在新包目录；对应清理测试通过。


## 最新候选 2026092704 与主题检查

- 来源提交 4dc9e76197d75ac81e94ca0d3752a73e09c5b81b，包含复制会话焦点恢复。构建前清理上一轮准确命名产物；完整 VM 门禁 131 项零失败、8 项 Release 基准与零 Swift 警告通过。GitHub CI 36292276431 completed/success。
- 应用与 DMG 均完成官方 Developer ID 签名、Apple 公证及 staple/validate；最终两个产物 SHA256SUMS 校验通过。只读挂载卷名 ApexTerm Candidate，根目录仅候选应用和 Applications 链接，包内严格验签通过。证据 candidate/dmg-copy-focus-inspection.json。
- macOS 27 VM assessments enabled；新包通过严格验签、票据与 Gatekeeper，来源 Notarized Developer ID，构建号 2026092704。实际新进程 PID 6525 路径 /private/tmp/apexterm-candidate.iJe3tw/ApexTerm Candidate.app/Contents/MacOS/ApexTerm。证据 candidate/vm-copy-focus-install.log。
- 最新 CopyFocus 验收窗口实际切换全部 12 主题，逐张查看 qa/current-theme-00.png 至 11.png：主要文字、工具栏和文件表格无明显截断或布局回退，终端内容保留；检查数据 qa/current-theme-checks.json。结束恢复经典白色。此项覆盖主窗口，合成会话不替代真实 SSH，也不代表所有弹窗/系统外观组合已验收。
- 整体目标仍未完成：实际绘制帧 P95 缺有效结果，VoiceOver 与系统对比度/透明度测试待已提出的设置确认，输入法及完整状态/窗口矩阵仍需补验。本次为可安装内部候选，未正式发布。


## 全屏快捷键补验

- 最新 CopyFocus 实际点击全屏，保存 qa/current-fullscreen.png：终端、侧栏与文件表格无明显截断。随后在终端焦点按 Control+Command+F 意外打开终端查找栏；qa/current-fullscreen-restored.txt 保留实际 AX，不能计为退出全屏通过。
- 终端键盘处理补齐 Control+Command+F 路由到窗口 toggleFullScreen，避免被 Command+F 查找或 Control+F 远程输入吞掉。回归测试断言窗口收到一次切换且无远程输入。tests-fullscreen-shortcut.log 8 项通过；tests-fullscreen-all.log 全量通过。实际修复后窗口验证与新签名候选尚待执行，2026092704 不包含本次修复。


## 全屏修复实际窗口与候选 2026092705

- FullScreenFix 最新代码窗口终端聚焦后连续 Control+Command+F 进入/退出全屏，正常窗按钮恢复，内容与终端焦点保留；Command+F 查找和 Escape 返回仍正常。qa/fullscreen-fix-enter.png、exit.png、对应 AX 与 fullscreen-fix-proof.json 五项断言通过。
- 导入弹窗取消关闭，会话仍为 1 台；未执行导入，不保存真实配置内容。
- 来源 6bd4ba1，候选 2026092705 完整 VM/测试/8 Release 基准门禁及零 Swift 警告通过，应用与 DMG 公证票据通过，最终哈希通过。VM assessments enabled，严格验签/票据/Gatekeeper accepted，Notarized Developer ID；实际新路径 /private/tmp/apexterm-candidate.Hh2M3O/，PID 6794 启动。证据 build-fullscreen-candidate.log 与 candidate/vm-fullscreen-install.log。
- 整体剩余项目保持未完成，不把本次全屏验证扩展为全部窗口矩阵通过。


## 云端焦点测试复查

- CI 36292548032 为 failure，失败在 testTerminalMountedInVisibleWindowGetsFocusWithoutStealingFieldEditing 的自动聚焦断言；不是全屏路由断言。证据 ci-fullscreen-failed.log。本地与 VM 通过不替代本次 CI 失败，最新候选整体 CI 门禁仍待恢复。
- 将固定 50ms 等待改为最多 2 秒等待真实终端焦点条件，保留自动聚焦断言。tests-focus-ci-wait.log 8 项通过；这是排查异步调度的修复尝试，须由云端结果确认，未声称根因已证实。产品二进制未改变，候选不需因测试变更重新打包。


## 设置页主题补验

- FullScreenFix 实际设置页的终端外观标签切换全部 12 主题，逐张查看 qa/settings-theme-00.png 至 11.png，当前视口内原生表单文字/控件和所选主题无明显截断或可读性回退。qa/settings-theme-checks.json 记录选项与预览 AX 存在；AX 存在不代表预览在当前视口可见。
- 恢复经典白色；普通滚动动作未改变视口，随后用暴露的原生滚动条设为底部，qa/settings-preview-white-bottom.png 确认真正显示完整命令预览。仅此默认主题的底部截图通过，其他主题底部和其余设置标签仍待补验。
- 本轮开始核对 CI：测试修正 bc01dbc 的 36292740035 queued，前一文档提交 36292685423 in_progress；没有把排队或运行中记为通过。


## 设置标签空白行修复

- 实际查看通用、操作习惯、SFTP传输、数据备份四标签；qa/settings-tab-0..3.png。通用显示 QA bundle 缺版本元数据的回退值，不作为正式候选版本证明。操作习惯额外 Divider 被 grouped Form 渲染为空行；再次稳定截图 settings-habits-stable.png 确认。
- 移除行为表单额外 Divider，保留系统行分隔；重新编译 SettingsSpacing QA，实际 settings-spacing-fixed.png 确认多余空行消失且两开关和缓冲区控件保留。swift build 通过。候选 2026092705 尚不包含此布局修复；最终候选须更新。


## 设置操作与最新 CI

- settings-habit-actions.json：自动复制与右键粘贴各 off→on，缓冲区 10000→11000→10000。settings-sftp-actions.json：隐藏文件与目录联动各 off→on，并发数 3→4→3。均为真实控件操作，结束恢复原值，不替代真实传输吞吐验证。
- download-directory-cancel.json：系统目录选择器 Escape 关闭后返回设置，原下载目录保持。settings-dark-tab-0..3.png 记录代表性深色外观；SFTP 第一开关在首帧截图未绘出，AX 与前述交互正常，不据此宣称该截图全部控件已通过。结束恢复经典白色。
- CI 36292740035（bc01dbc 焦点等待修正）success；36292865307（最新产品 19766a6）全部步骤 success，包括 Debug、全量测试与 Release 编译。
- 候选 2026092706 应用已公证并安装到 macOS 27 VM；assessments enabled、严格验签/票据/Gatekeeper accepted，来源 Notarized Developer ID，PID 7130 实际新路径 /private/tmp/apexterm-candidate.IaFb9l/。证据 candidate/vm-settings-install.log。DMG 公证仍在运行，最终哈希/挂载未计通过。


## 会话主题对比度修复

- qa/session-validation-proof.json 记录空主机禁用保存、恢复有效地址可保存、密钥模式隐藏密码并显示Agent说明、恢复密码模式；未保存未连接。
- 最新实际会话窗口切换12主题，qa/session-theme-00..11.png 与 session-theme-checks.json；逐张查看发现部分浅强调色的认证选项和保存按钮白字对比偏低，未将所有主题可读性记为通过。
- 保存按钮额外 tint 覆盖 apexProminentButton 的可读强调色，删除覆盖；分段认证 Picker 使用同一 buttonAccent。build-session-contrast.log 编译通过；实际 session-contrast-mocha.png 确认两处变为深紫、白字更清晰。其余主题修复后的复验待完成。候选2706来源19766a6，不含本次修复，未把运行中的公证包与新代码混同。


## 会话按钮12主题复验完成

- 修复后实际 SessionContrast 窗口逐张检查 session-contrast-mocha.png、session-contrast-0..3.png 与 session-contrast-rest-0..6.png，合计12主题；认证选中项与保存按钮底色均使用可读强调色，当前可见表单无明显布局回退。仅覆盖该视口，不涵盖下方控件及所有无障碍组合。
- tests-session-contrast-all.log 全量测试零失败。最新候选仍未包含99cc122修复。
- Apple history诊断最新为2706应用 notarization.zip Accepted（03:58:12Z）；新DMG提交尚未出现在history，最新可见DMG Accepted为上一轮03:52:07Z。当前notarytool submit进程仍活跃，不以旧DMG状态冒充本轮成功，也不因等待超时重启。诊断 notary-history-diagnostic.json。


## 编辑器12主题实际窗口

- SessionContrast 实际 editor 页面切换12主题；qa/editor-theme-00..11.png 逐张查看：示例配置/行号与查找、重新加载、关闭、保存控件保留，无明显截断。editor-theme-checks.json 确认内容与保存AX存在。编辑区浅深系统表面、工具区所选主题配色；这不是语法色板逐token一致性的声明。
- 本项覆盖正常短文件桌面窗口，不替代长文件/错误/未保存状态或真实远程保存验收。

### 长文档行号绘制边界复验

- 2,002 行、30 KB 示例内容，原生查找 LAST_MARKER_2000 定位第 2001 行，匹配计数 1。
- 修复 CodeLineRuler 绘制越过文档可见区域、覆盖顶部工具栏：绘制时保存图形上下文并裁剪至可见文档区域，完成后恢复上下文。
- 实际截图 qa/editor-minimal-long.png 为修复前越界，qa/editor-viewport-long.png 为修复后；顶部工具栏和底部保存按钮均完整，匹配高亮和滚动正常。
- tests-editor-viewport.log 的 swift test 退出 0；验收结束恢复示例内容，未执行远程保存。
- 验收窗口从初始 editor 场景启动时未应用页面尺寸，产生与产品问题无关的布局异常；本次从 main 切换 editor 应用 900×650 尺寸后复验。撤回未奏效的尺寸/多层裁剪实验；验收窗口标题加入独立应用名称以区分并存窗口。
- 本项不替代真实 SSH 编辑上传、输入法和其余完整验收矩阵。

### 编辑器未保存内容取消流程

- EditorViewport QA 中加入 unsaved=qa 后点击关闭，实际弹出“放弃未保存的更改？”以及关闭丢失内容说明；选择“继续编辑”后内容仍在。
- 点击重新加载，实际弹出重新加载将覆盖当前内容说明；选择“继续编辑”后内容仍在。
- 结果记录 qa/editor-discard-cancel-proof.json，两条内容保留断言均为 true；结束恢复原示例，未保存远程文件。
- 此证据覆盖保护提示与取消，未覆盖真实远端加载失败/保存成功或实际 SSH 写入。

### 编辑器保存期间控件状态

- 验收回调延迟 8 秒，实际 UI 保存期间显示 busy indicator；重新加载、顶部关闭编辑器、底部关闭均为 disabled。完成后按钮恢复，并显示完成通知。
- 修复关闭按钮显示可点击但 requestClose 忽略操作的状态不一致，移除保存按钮覆盖 apexProminentButton 可读颜色的额外 tint。
- qa/editor-saving-fixed.txt 与 qa/editor-save-restored.txt 记录前后辅助功能状态；tests-editor-save-controls.log 全量测试退出 0，无 warning/error。
- 此为隔离验收回调，UI 的上传成功文字不代表真实 SSH 已上传；真实远端保存验收仍待完成。

### 最新真实链路入口复查

- RealWorkflow 通过 open 启动时真实 SSH 报 No route to host；同一时刻命令行 SSH 可达。未修改系统网络权限。
- 同代码 RealDirect 直接启动可读远端临时目录 /tmp/apexterm-ui-rxr9pSmP 的 transfer-payload.bin，记录 real-direct-ready-proof.json。该成功不替代 Finder/open 启动验收。
- 终端输入尝试未产生完整命令执行回显；粘贴工具报剪贴板读取超时。单字符曾显示，但回车/组合提交的完整远端输出未证明；保留 real-terminal-input-investigation.png，继续排查，未记为通过。
- fd63620 CI 36293891115 与 3279e01 CI 36294010074 已成功。

### 终端输入链路逐段诊断

- 隔离 QA 可选 APEX_QA_KEY_DIAGNOSTICS 只记录键码、修饰键、终端焦点/marked/input 布尔值及回调字节数、CR 数量，不记录用户输入正文。
- input-state-runtime.log：键码 14/36 均到 NativeTerminalView，marked=false、input=true。
- input-callback-runtime.log：字母回调 1 字节，回车回调 1 字节且 CR=1。回调之前的事件路径已确认，完整远端回显仍缺失。
- InputCallback 的实际 SSH 子进程 71305 有 /dev/ttys023 输入和错误输出，stdout 为 /dev/null；有效 SSH 配置 stdinnull=no、sessiontype=default、forkafterauthentication=no。该差异尚未确定根因，不作为修复通过证据。
- 验收程序原有递归视图查询补充 @MainActor，compile-InputState.log/compile-InputCallback.log 均为空，无编译警告。

### 默认擦除显示序列导致真实回显丢失

- 默认 CSI J 与显式 CSI 0J 被误当作清空全部历史，shell 提示符重绘抹掉此前输出。修复模式 0 仅擦除光标后的当前行内容，保留已提交历史；模式 2/3 保留原清屏行为。
- testEraseBelowCursorPreservesShellHistory 覆盖默认/显式模式 0，验证已提交输出和光标前提示符保留。tests-erase-display.log 全量退出 0。
- EraseDisplayFix 实际 SSH 输入 echo APEX_REAL_CHECK 并回车，界面保留执行回显与后续提示符；qa/real-terminal-erase-fix-proof.json 和截图记录。此为直接启动验收应用，不替代正常启动证据。
- 粘贴工具仍报等待应用读取剪贴板超时，未判粘贴通过。临时 NativeSSHSession 字节数量诊断已全部撤回，不进入产品提交。
- 先前 stdout=/dev/null 观察不构成根因；完整描述符仍有 PTY 副本，读取日志证实远端数据已到达。

### 真实终端 Command-V 粘贴复验

- 终端明确处理 Command-V，performKeyEquivalent 仅在当前第一响应者是该终端时处理；keyDown 同样保留直接分发入口，避免快捷键进入输入上下文。
- testCommandVPastesInsteadOfSendingShortcutToTerminal 验证两个入口各产生一次完整粘贴输入及 LF→CR 转换，测试保存/恢复剪贴板全部类型。tests-paste-focus.log 全量测试退出 0。
- 待全部测试结束、真实 SSH 提示符稳定后，sky.paste 指定 echo APEX_PASTE_FOCUS 并回车，实际窗口显示执行结果及下一提示符，工具未超时。qa/paste-focus-proof.json markerOccurrences=2，截图 paste-focus-success.png。
- 最早粘贴复验与修改剪贴板的测试并发，原有内容进入窗口；该尝试无效。随后快捷键入口增加第一响应者限制并独立复验成功。
- 本项仅证明直接启动 QA 的真实粘贴链路；正常启动、输入法候选与双向拖拽仍待完成。

### 真实 SFTP 创建、编辑保存和重新加载

- 在 /tmp/apexterm-ui-rxr9pSmP 的真实 SFTP 菜单新建 editor-acceptance-20260927.conf，界面出现行，远端 stat 确认为 0 字节。
- 双击打开实际编辑器，填写独立测试内容并保存，UI 显示保存完成；远端 stat 为 67 字节，SHA256 与预期 payload 完全一致：4c65adea9f3be8a71c14fb5371c031317309d6107f8bbfc8f52f872e159e02b8。
- qa/real-editor-save-hash-proof.json 记录哈希及字节数；实际重新加载读回 source=private-qa/value=20260927，real-editor-reload-proof.json 两字段存在且无失败。
- 关闭编辑器返回列表后，实际文件行显示 67 B，截图 real-editor-saved-list.png；覆盖真实创建、空文件编辑、保存成功、重新加载及列表刷新。
- 本项使用隔离 QA 直接启动，未覆盖正常启动、失败/取消传输及双向拖拽。e3d4ad3 CI 已成功；ba8c28b CI 尚在运行。

### 真实编辑器保存失败与重试

- 仅将本轮创建的 editor-acceptance-20260927.conf 临时 chmod 400，编辑器追加 failed-save=must-stay-local 并实际保存。界面显示 scp Permission denied，本地更改保留。
- 随即恢复权限 644；远端 SHA256 仍为 4c65adea9f3be8a71c14fb5371c031317309d6107f8bbfc8f52f872e159e02b8，失败未改变原文件。
- qa/real-editor-save-failure-proof.json 与截图记录失败及内容保护；恢复编辑器原内容并重新保存，成功通知出现、错误清除，real-editor-save-retry-proof.json 两项为 true。
- 此项覆盖真实权限错误和恢复重试，不替代传输取消、拖拽与其余失败矩阵。

### 真实编辑器取消关闭与 SFTP 空/失败状态

- 真实编辑器追加 cancel-close=qa 后尝试关闭，实际出现未保存提示；选择继续编辑后更改保留，real-editor-cancel-close-proof.json 为 true。恢复原内容，远端 SHA256 不变。
- SSH mktemp 新建独立空目录 /tmp/apexterm-empty-qa.ECeH9jS8；实际 SFTP 导航显示“文件夹为空”，上传入口可用，截图 real-sftp-empty.png。
- 导航该目录下不存在的 missing-directory-qa，界面显示 No such file or directory 和重试按钮；返回有效目录后恢复空状态、错误清除，real-sftp-missing-directory-proof.json 记录失败控件。
- 本项覆盖真实空目录和不存在路径错误/恢复，不替代权限读取错误、取消传输或双向拖拽。

### 最新实现真实点击双向传输与记录

- 独立 131,072 字节 transfer-source-20260927.bin 通过上传按钮及原生文件选择器上传到 /tmp/apexterm-empty-qa.ECeH9jS8；实际列表出现文件并显示 128.0 KB，任务中心自动展开并保留上传完成记录。
- 实际文件右键下载至 Downloads；任务中心同时显示上传(1)/下载(1)，两条记录均完成。下载文件存在，源/远端/下载 SHA256 均为 59f410ae5e17962412e2aed4f815918f634932f2abf084f00bb638c4db017850。
- real-click-roundtrip-proof.json 与 real-click-roundtrip-records.txt 记录哈希及任务状态；点击下载记录“在访达中显示”实际选中下载文件。
- 未覆盖双向拖拽、取消或重复文件处理；直接启动 QA 仍不替代正常应用启动验收。

### 验收实例生命周期与正常启动权限排查

- 清理本轮遗留的 34 个 QA 应用及 19 个子进程，确认宿主无 QA 可执行进程残留。验收构建脚本现在在发现任何已有 QA 实例时停止；绝对与相对可执行路径均已验证，且停止发生在编译与创建 bundle 之前。
- QA 应用关闭最后一个窗口后退出；LifecycleCheck 编译无诊断，尚未进行该退出行为的 GUI 复验。
- 候选、正式与 QA 打包入口补充 NSLocalNetworkUsageDescription，解释 SSH/SFTP/监控的本地网络用途。Python/Shell 语法检查、候选脚本两项测试通过。
- Apple TN3179 说明命令行与应用正常启动可能具有不同本地网络权限归属，符合先前直接运行成功/open 失败的现象，但不证明本机根因；未修改系统授权，正常启动仍待实际验收。参考：https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

### 候选 2026092706 DMG 本地阻塞收尾

- notarytool 62653 采样停在 xar_open_digest_verify/open，未见网络 socket；hdiutil info 将候选 DMG 关联至无挂载点的 disk8，diskimages-helper 持有该文件。仅正常 detach 此映像后，原提交以格式校验失败 64 退出。
- 只重试同一 DMG，Apple 返回 Accepted，submission ec5e53e3-0ab0-40cf-bc4d-114189c54133；staple/validate、只读挂载根目录、包内 deep/strict 签名及 DMG/tar.gz SHA256 校验通过。卸载命令退出 0，后续无挂载与文件占用。证据 candidate/notarization-dmg-retry.json、candidate/dmg-settings-inspection.json、candidate/SHA256SUMS.txt。
- 来源仍为 19766a6，未包含后续产品修复；此包不是最终交付。候选脚本新增清理前已连接映像检查，避免删除仍在使用的旧 DMG；Python 语法及原两项清理测试通过。

### 候选 2026092707 与单实例验收收尾

- 来源9686251，CI 36295541927 success。Debug全量134项0失败，其中4项公网目标未配置而跳过；5项真实VM测试通过。8项Release基准实际执行并通过全部阈值，编译日志无 warning/error。应用及DMG公证Accepted，票据与两个安装产物SHA256校验通过。
- DMG挂载卷名ApexTerm Candidate，根目录仅候选应用及Applications链接；包内严格签名/票据通过，detach退出0。证据candidate/dmg-current-inspection.json。
- VM启用Gatekeeper，安装2707于 /tmp/apexterm-current.msHjeA，严格签名/票据/assess接受；LaunchServices正常启动实际进程90173来自该新路径，随后仅退出此实例，无残留。未将进程启动当作界面验收。证据candidate/vm-current-install.log、candidate/vm-current-launch-proof.json。
- QA最后窗口关闭已通过实际AX点击与ps核验，qa/lifecycle-close-proof.json。正常启动ad-hoc QA仍No route to host，同期CLI SSH成功；Developer ID签名后窗口读取两次超时，工具禁止访问UserNotificationCenter，结果未验证，已退出唯一QA实例。没有修改系统授权。证据qa/normal-launch-network-failure.txt、qa/developer-id-normal-launch-diagnostic.json。

### 隔离会话与产品键盘流程复验

- f7d9563候选2026092708完成135项测试（4公网跳过、0失败）、5真实VM测试、8 Release基准、应用/DMG公证与票据及SHA256检查。实际候选启动显示0主机，正式目录三个文件的SHA256保持不变；证据candidate/production-store-isolation-proof.json。后续命令修复尚未纳入2708，不能将其作为最终源码交付。
- 2c458a9空库⌘T打开新增面板；本体Debug smoke通过GUI保存RFC示例192.0.2.10 Mock会话、连接及再次⌘T复制第二标签。证据main-command-smoke/command-t-proof.txt、duplicate-tabs-proof.txt。
- 2b42d41将默认Close及会话⌘W合并为唯一saveItem命令，Debug编译通过。实际2标签→1标签且窗口保留；左右/上下2窗格→1窗格，标签保留且焦点落在剩余终端。证据main-command-smoke/command-w-fixed-before.txt、command-w-fixed-after.txt、pane-close-proof.json。仅一个验收实例，结束后ps确认无残留。
- SwiftUI模板短录制/导出已可用；5秒真实分屏/标签操作trace正常退出，约150MB。18518条SwiftUI更新关联ApexTerm PID93619，视图更新P95 0.036041ms、最大3.864041ms；这不是显示帧持续时间。hitches-updates为空，显示帧仍未关联应用，不计帧P95通过。证据interaction-app-update-analysis.json。
- 系统本地网络列表只读检查可见ApexTerm.app授权on；独立候选条目未识别，不能推断其授权。未切换设置。证据local-network-permission-observation.json。

### 远端 HOME 初始化回归（2026-09-27）

正常启动候选 2026092709 的真实 SSH 输入、粘贴和 SFTP 临时目录列表已验证，证据为 `outputs/macos27/candidate/normal-real-ssh-sftp-proof.json`。首次连接曾错误使用 `/home/用户名`，现改为服务器 `$HOME` 探测，初始目录使用 `~`，列表返回绝对路径；关闭目录联动时仍允许首次 HOME 解析，之后不随终端目录变化。真实 VM 对比 `~`、`~/` 与绝对 HOME 的列表一致；全量测试证据为 `outputs/macos27/tests-home-full.log`。候选 2026092709 尚未包含本次修复，不能作为最终实现验收。

### ⌘W 窗口范围与未保存内容（2026-09-27）

主窗口通过 focused scene 标记参与连接关闭命令；设置窗口及 sheet 不关闭后台连接标签。编辑器底部关闭按钮绑定 ⌘W，复用原有未保存确认及保存/重载禁用保护，顶部 Escape 行为保留。真实产品窗口验证：活动连接存在时打开设置，⌘W 关闭设置且标签/终端内容保留；编辑器修改合成内容后 ⌘W 显示放弃确认，继续编辑保留内容；回主窗口复制为两个标签，⌘W 后剩一个且连接保留。证据：`main-command-smoke/settings-active-connection-proof.json`、`editor-command-w-unsaved-proof.txt`、`editor-command-w-cancel-proof.txt`、`scoped-tab-close-proof.json`（均位于 outputs/macos27）。验收后退出，进程检查无残留。

### 拖拽导出隔离与取消（2026-09-27）

发现两个目录的同名文件导出共用临时路径，新增真实 NSItemProvider 文件加载回归，修复前失败、独立 UUID 目录后通过。导出改为消费者请求文件时才启动下载，各表示共享一次下载；放弃未投放拖拽不创建传输任务，Progress 取消会取消下载并记录取消状态。相关 15 项测试通过，取消验证同时断言没有生成文件。全量真实 VM 测试日志为 `outputs/macos27/tests-lazy-drag-full.log`。真实 Finder 双向拖拽仍需实际窗口与哈希验收，不以 provider 测试替代。

候选 2026092710 来源 530a13e，应用/DMG 公证 Accepted、票据与 SHA256 校验通过；本次拖拽修改尚未纳入此候选。

### PTY 退出与测试 VM 连接上限（2026-09-27）

发现正常退出应用后遗留的 SSH PTY 客户端：41 个进程的父 PID 为 1，完整参数与本项目连接启动逻辑及测试 VM 目标匹配。测试 VM 的 SSH launchd 服务 `copy count=42`、系统 plist `inetdCompatibility.Instances=42`，新连接在密钥交换前被关闭，已有复用连接仍可用。精确清理本任务的孤儿 PTY 后，独立新 SSH 连接恢复。另清理 VM 内 7 个旧临时候选/验收应用，保留正式安装应用。

连接改为独立进程组，断开时回收进程组和密码辅助工具的后代并 waitpid；主应用 willTerminate 同步回收所有活动窗格的 PTY。延迟 HOME 探测在断开后不再启动/分发。新增真实 VM 回归验证 connect 产生子进程、重复 disconnect 后对应 PID 不再存在。7 项 VM 测试通过；实际正常 ⌘Q 验收记录应用 PID 4305、SSH PID 4334，复查均已退出，VM 新 SSH 成功。证据：`tests-pty-reaping-vm.log`、`main-command-smoke/lifecycle-normal-quit-proof.json`、`vm-ssh-service.log`、`vm-ssh-limit.log`（位于 outputs/macos27）。

候选 2026092711 来源 910bcc1，CI、公证、DMG 内容/票据/哈希及 VM 安装 Gatekeeper 已通过；尚未包含本次 PTY 清理修复，不是最终实现候选。
