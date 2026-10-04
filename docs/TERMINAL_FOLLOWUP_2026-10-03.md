# 2026-10-03 终端交互与刷新修复

## 改动

- 组合键编码按 Shift、Option、Control 的完整组合生成 xterm 参数，覆盖方向键、Home、End、Delete、PageUp、PageDown 和 F1…F12。未修复代码在新增三项回归中产生 170 个失败断言，修复后通过。编码依据：[XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)。
- Vim 等备用屏幕中的 Option＋左右键发送编辑器的 Alt 方向键序列，避免被解释为 Escape 后的 shell 按词移动命令。普通 shell 的 Option＋左右键及 Option 删除快捷键保留原行为。
- 备用屏幕缓存未变化行的富文本，局部变化仅重建相应行；主题、字体、关键词规则、行数和会话变化使缓存失效。回归检查选区、颜色、TrueColor、缩小视口和重新进入备用屏幕。
- VM 传输包为重启测试应用固定工作目录内路径，支持位于其他目录甚至仓库外的报告。新增测试实际打包并解包外部目录的应用，再核对内容。
- SFTP 工具栏给路径输入框保留至少 240 点宽度；工具栏宽度低于 880 点时收起按钮文字，低于 680 点时改为两行。使用 `AnyLayout` 复用路径控件，避免切换布局时创建另一份输入框；紧凑按钮保留辅助功能名称和提示。

## 性能测量

同一台开发机、Debug 构建、40 行 × 120 列彩色备用屏幕，XCTest 每次测量执行 100 次光标移动及刷新，10 次测量取平均：

| 实现 | 平均耗时 | 相对标准差 |
| --- | ---: | ---: |
| 修复前 | 0.612 秒 | 17.3% |
| 复用未变化行后 | 0.168 秒 | 22.3% |

这组测量耗时减少约 72.5%，只包含缓冲与 AppKit 视图刷新调用，不代表网络延迟、屏幕呈现帧率或长期功耗。原始报告为 `outputs/terminal-ui-followup-render-before.log` 与 `outputs/terminal-ui-followup-render-after.log`（开发工作区的独立诊断输出）。

最终代码全量复测再次测得平均 0.175 秒，相对标准差 27.3%；测量存在明显的环境抖动。

## 已验证

- 终端专项：45 项通过，随后补充了备用屏幕主题切换与 Option 退格行为回归。
- 脚本：74 项通过，包含自定义报告目录应用传输的真实归档往返。
- 最终代码的全量 Swift 测试：291 项 ApexSSHTests + 66 项 ApexCoreTests，共 357 项通过，0 失败、0 跳过；包含 10 项 VM 集成及 4 项真实服务器测试。
- 10 项 VM 集成覆盖真实 SSH PTY、Vim 编辑、保存与多次尺寸回传，SFTP 字节校验、特殊文件名、监控和进程清理。
- 最终 Release 测试二进制在 Tart `macos27` 执行 8 项优化基准，0 失败，全部发布阈值通过；传输前后的 SHA-256 一致，机型验证为 VirtualMac。Swift 编译无警告。

| 基准指标 | macos27 实测 |
| --- | ---: |
| RingBuffer | 1,779,615 行/秒、179.90 MB/秒 |
| ANSI | 379,889 spans/秒 |
| 峰值 RSS | 104.44 MB |
| 并发写入 | 1,642,038 writes/秒 |
| 监控解析 | 13,653 次/秒 |
| SSH 主机解析 | 133,546 hosts/秒 |
| SFTP 调度 | 952 tasks/秒 |
| Mock 输入链路 | 7.81 微秒/键 |

第八项只测 Mock 会话内部输入路径。证据：`outputs/terminal-ui-followup-current-code-gate.log`、`outputs/terminal-ui-followup-vm-benchmark/benchmarks.log`、`outputs/terminal-ui-followup-vm-benchmark/thresholds.txt`、`outputs/terminal-ui-followup-vm-benchmark/run.json`、`outputs/terminal-ui-followup-script-tests-final.log`。

零跳过复测中有一次因长历史刷新和 ANSI 解析墙钟时间超限而失败；当时开发机负载读数为 732，两个用例随后保持原阈值单独通过，全量复测也通过。失败日志保留为 `outputs/terminal-ui-followup-final-swift-under-load.log`，不能用单项补跑覆盖失败记录或宣称没有出现过超时。

开发机初次 `test_vm_acceptance.sh` 在全部 357 项功能测试通过后，因 4 项性能阈值未达标而退出 1，不能记为该次入口完整通过：监控解析 3,013 次/秒、SSH 主机解析 68,555 hosts/秒、SFTP 调度 694 tasks/秒、Mock 输入 15.86 微秒。随后同一二进制在 VM 中全数达标，支持环境负载影响测量的判断；未降低门槛，也未修改发布入口以绕开失败。

2026-10-03 21:29，包含最终 SFTP 布局修复的代码再次通过完整 `test_vm_acceptance.sh`，退出码 0：357 项 Swift 测试、8 项优化性能基准全部通过，9 个性能阈值均达标，0 失败、0 跳过、0 编译警告。RingBuffer 为 1,611,084 行/秒、162.86 MB/秒；ANSI 为 366,522 spans/秒；峰值 RSS 为 106.80 MB；并发写入为 1,891,363 次/秒；监控解析为 13,239 次/秒；SSH 解析为 133,407 hosts/秒；SFTP 调度为 1,087 tasks/秒；Mock 输入为 7.74 微秒。证据：`outputs/terminal-ui-followup-toolbar-stable-focus-final-gate.log`。此入口通过不包含下面尚未完成的 XCTest 产品 UI 验收。

## 尚未完成的 UI 验收

完整 UI 仍必须在 Tart `macos27` 执行。本轮自定义报告目录错误已解决，后续运行 `outputs/terminal-ui-followup/fixed/20261003-204302-14407/UI.xcresult` 因系统“Enable UI Automation”验证未完成而启动超时，运行器报告 `Timed out while enabling automation mode.`，43 项产品 UI 用例尚未执行。

已通过测试不能替代完整 UI 验收。此前主题菜单有限坐标断言与 XCTest 失败处理停滞，以及真实系统拼音、Finder 双向拖拽和窗口截图矩阵，仍需完整复测。系统身份验证在下面的 2026-10-04 复测前已完成。

2026-10-04 用户准备完成系统验证后，基于 `830fefc` 再次启动全量 UI 验收。实际出现 XCTest 密码弹窗，但约 60 秒内未完成验证；Runner 初始化失败，退出 65，43 项产品用例仍未执行。证据为 `outputs/terminal-ui-followup-resumed/20261004-082535-8595/UI.xcresult`、`summary.json` 和 `resume-status.json`。本次弹窗在 Runner 退出后仍显示，保留其独立 VM 工作目录，避免在人工验证期间删除应用；本地传输归档和目标配置副本已清理。系统验证完成后，该独立 VM 目录及本地临时应用已清理，日志、源码和 xcresult 保留（`guest-cleanup-after-verification.json`、`local-transient-cleanup-after-verification.json`）。

随后新增 `testSFTPToolbarResizeKeepsPathDraftAndKeyboardFocus`，完整 UI 清单增至 44 项。最初的 `xcodebuild build-for-testing` 只证明编译。实际执行发现按压拖动没有改变窗口尺寸；保留尺寸断言，改用 macOS 鼠标点击拖动后，真实缩放交互才通过。

### 2026-10-04 验证完成后的复测

`outputs/terminal-ui-followup-verified/20261004-084034-15632` 已实际启动产品 UI 测试，证明系统验证已完成。主题矩阵完成前五种主题后，在 Nord 的“操作习惯”标签有限坐标检查失败；运行器随后停在失败清理。采样堆栈显示同步失败处理在等待主 actor 的异步清理。仅停止这次拥有的 Runner 和控制器并保留证据；Xcode 取消过程中产生内部错误，原始 xcresult 未完成 `Info.plist`，不能用它宣称完整用例通过。原始包、日志、堆栈及失败画面保留，`runtime-audit.json` 记录该限制。

44 项 UI 操作本身均为同步 API，现改为同步 XCTest 入口和同步清理；清理入口断言处于主线程，再进入主 actor。`@unchecked Sendable` 仅用于 XCTest 同步清理的桥接，测试状态仍由主 actor 隔离；显式非隔离析构不访问这些状态。有限坐标断言保留，先检查控件存在再读取几何信息。诊断结果依次为：

- `synchronous-diagnostic-1`：故意失败用例正常完成截图、清理并退出，约 17 秒，下一用例正常执行。3 项中路径复制与草稿取消通过，故意失败和窗口尺寸未变化共 2 项失败；这是诊断，不能记为产品验收通过。故意失败源码仅保留在报告，已从当前 44 项清单移除。
- `resize-diagnostic-2`：Mocha 设置标签通过；按压手势仍未改变宽度，尺寸回归失败并正常退出。未降低或删除尺寸断言。
- `resize-diagnostic-3`：使用右侧直边上的[鼠标点击拖动 API](https://developer.apple.com/documentation/xcuiautomation/xcuicoordinate/click%28forduration%3Athendragto%3Awithvelocity%3Athenholdforduration%3A%29)，实际完成 1300 → 960 → 1300 点缩放，路径草稿、继续键入及 Escape 恢复均通过。
- `resize-diagnostic-4-two-rows`：同一回归分别在默认侧栏及受控 370 点侧栏下执行。QA 侧栏宽度限定在产品原有 260…370 点范围，实际窗口仍由鼠标拖动。分别断言单行和两行的控件位置、唯一输入框、至少 240 点路径宽度、按钮可点击性、草稿与键盘焦点，以及展开后回到同一行。两种交互均通过。此结果不表示用户已经实际拖动侧栏分隔线。

当前生产模块源码未因上述测试修复改变；完整 44 项产品 UI 门禁仍需基于最终测试源码重跑，不可用专项通过替代。

## SFTP 工具栏的 VM 渲染检查

在 Tart `macos27` 的独立 QA 应用中，修复前 960 点宽窗口的路径输入框约为 100 点宽，路径联动文字被截断。最终代码的两种初始窗口状态已分别核对截图：

- 960 点宽、VS Code Dark Modern：完整示例路径可见，工具栏为紧凑图标；证据 `outputs/terminal-ui-followup-manual/20261003-211227/compact-dark-render-final.png`。
- 1300 点宽、经典白色：路径与按钮文字均可见；证据同目录的 `wide-light-render-final.png`。

QA 辅助程序新增可选 `APEX_QA_INITIAL_WINDOW_WIDTH`，在启动时设置有限、受屏幕范围限制的宽度。主题也由原有初始主题选项设置。这些截图只证明指定初始尺寸和主题的真实渲染，不能替代拖动缩放、跨布局焦点保持、主题菜单选择或复制粘贴的交互验收。这些初始渲染检查当时没有覆盖两行布局；其真实窗口操作已在上面的 2026-10-04 专项复测中补充。通过 Tart 输入通道进行的菜单选择及复制检查当时没有获得可靠结果，不计为通过；后续 XCTest 的路径复制回归已实际通过。

同目录 `run.json` 保存最后两次渲染所用源码、传输归档及截图的 SHA-256，归档在 VM 解包前校验一致；`final-source.patch` 保存对应源码差异。QA 应用在 VM 中使用独立标识重新临时签名，不能据此声称签名后的整个二进制与传输前哈希相同，也不能替代正式分发包验证。

## 清理

本轮两次失败 UI 运行及独立性能运行的确切 VM 工作目录均已验证无相关进程或工作目录引用后删除；共享的物理按键工具保留。本地对应的传输归档、临时应用、编译辅助程序和一次性目标配置已清理，日志、源码快照、xcresult 及诊断报告保留。清理只覆盖这三次运行有所有权记录的残留。

后续工具栏渲染使用的独立 QA 进程已停止，确认无进程或工作目录引用后删除其 VM 工作目录 `apex-manual-run.BfoJ3z`、唯一 QA 标识对应的偏好设置及自有桌面互斥锁；本地三份传输归档已删除。日志和截图保留，清理记录为 `outputs/terminal-ui-followup-manual/20261003-211227/cleanup.json`。本次渲染使用受控 Mock 会话，没有在远端服务器新建文件。

改动位于 `bcblr/fix-terminal-ui-followup`，更新日志记为 Unreleased。本报告不改变已提交 Apple 审核的构建及此前发布结论。
