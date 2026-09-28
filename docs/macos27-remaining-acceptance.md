# macOS 27 剩余验收清单

当前状态：按用户要求跳过正式发布，不打 Tag、不上传发布包。当前 38 项完整 UI 门禁 `20260928-033023-49254` 失败，12 passed、2 failed、0 skipped，只有 14 个结果；真实拼音提交失败，随后 Runner 开启 Automation Mode 超时。隔离复测在测试启动前同样受认证阻塞。测试机需恢复 Automation Mode 后继续排查与重跑。当前源码的真实 Tart 门禁已通过：7 项 VM 测试、152 项 Swift 测试（4 项可选环境跳过）、8 项 Release 基准与全部 9 个性能阈值，证据为 `outputs/macos27/current-monitoring-chart-vm-gate.log`。以下既往结果按历史记录保留，不替代当前完整验收。

最新完整门禁 `20260928-023520-36976` 已完成：37 passed、0 failed、0 skipped，入口 stage=passed、exit_code=0，44 个产品源码哈希与测试源码事后核验一致。随后增加保留历史但关闭监控的场景，专测 `metrics-history-repro-20260928` 在关闭摘要断言失败；修正摘要和详情读取逻辑，使关闭时不展示历史值为当前指标，历史存储保留。Release 编译通过且未见 warning/error，专测 `metrics-history-fixed-20260928` 为 1 passed、0 failed、0 skipped，10 个截图附件已导出，三份相关源码哈希未变。这次产品修正发生在完整门禁之后，最终源码完整门禁与签名候选仍需重跑、重建；断线实时提示及原计划其余性能/无障碍验收仍保留。

当前进行中的完整门禁为 `20260928-023520-36976`，包含 37 项测试，尚未取得最终结果。新增监控四状态专测 `metrics-label-20260928-023343` 已通过（1 passed、0 failed、0 skipped），8 个截图附件已导出核验；12 主题详情验证纳入本次完整门禁。该结果仅覆盖启动时的实时、过期、等待和关闭状态，不覆盖收到指标后关闭监控。源码复核发现关闭监控时仍读取历史最新指标，可能继续显示实时/过期摘要；这一问题须另行复现、修复并复测，不能用空历史的关闭状态截图替代。

正式打包入口 `scripts/build_app.sh` 在打包之前强制执行 `scripts/test_ui_acceptance.sh`，缺少测试配置、执行失败或结果验证失败均停止。当前按用户要求跳过正式发布；上述入口检查不表示本轮已发布。外部 CPU 采样脚本已校准空闲/单核负载/进程退出，并拒绝非有限或负数计数；23 项脚本测试通过。真实候选的四类空闲场景和显示帧 P95 仍待实测，不以工具校准代替性能验收。

2026-09-28 最新干净源码 `1b1bcb0` 的完整门禁为 `20260928-011558-21195`：36 passed、0 failed、0 skipped。内部候选 `1.3.0 / 2026092801` 已通过 VM 7 项、全量 Swift 测试、8 项 Release 基准、签名/公证/校验和及只读 DMG 内容校验。实体机候选已通过启用 Gatekeeper 时的签名接纳与启动，关于页核实实际版本；快捷键页 Escape 关闭已见实机截图。鼠标关闭与 Command 转发仍受屏幕共享输入异常影响，暂不能归因为产品缺陷。证据位于 `outputs/macos27/candidate/current-package-verification.json`、`physical-226-2801-verification.log` 和 `physical-226-2801-shortcuts-input-review.json`。

当前另有未提交的验收覆盖修正：快捷键 QA 窗口高度由滚动区 480 调整为包含页头/底栏的 590，并在 12 主题测试中检查标题和两个关闭按钮可见、可点击。Release 与 UI 测试编译通过，实体机专测 `shortcuts-visibility-20260928-020509` 已通过（1 passed、0 failed、0 skipped），168 个附件完整导出核验。12 张快捷键首屏已审阅，页头和上下关闭按钮完整可见，Dracula 上方裁切消失；不覆盖底部内容与关闭操作，不代替完整 36 项门禁。上述签名候选对应 `1b1bcb0`，不包含本次测试标识修改。所有阶段的性能、系统无障碍与完整交互剩余项继续保留。

2026-09-28 当前完整门禁已通过：`20260928-003341-13677`，36 passed、0 failed、0 skipped，入口 stage=passed、exit_code=0；用例清单/名称/测试源码校验通过，45 个源码与 QA 产物哈希事后未变，远端 QA 二进制与本地一致。双向 Finder 拖拽、真实拼音、真实 SSH/SFTP、终端系统指标、12 主题及其余操作完整执行。此报告证明当前 UI 门禁，不替代原计划性能/无障碍或最新签名候选安装验收。下文运行中与失败描述为历史过程。

本次按用户要求“ci 没有额度直接跳过发布版本”跳过正式版本发布，不打 tag、不上传发布包，不等待或声称 GitHub CI 通过。真实机器测试与自动化整理继续推进；后续正式发布仍须满足原有门禁并取得明确授权。`23d5ebc` 已固定离屏测试视图尺寸并保护 CGContext 状态，本地四项组合测试通过。

最终焦点修复源码 `200f538` 完整实体机门禁 `20260927-230435-96848` 已通过：33 passed、0 failed、0 skipped，清单/名称/源码校验通过，入口 stage=passed、exit_code=0。12 主题与九类页面整组、Mocha 标签切换、真实拼音恢复、真实 SSH/SFTP、导入取消、分屏及其余用例均完整执行。下列失败记录保留为历史，不代表最新门禁。随后接入两个真实 Finder 拖拽用例与一个指定应用的终端滚动系统指标用例，当前源码清单为 36 项；新增三项已分别在实体机实跑通过（下文保留失败与复测记录）；当前源码的 36 项完整门禁正在执行，尚未通过。系统卡顿指标不等于实际帧 P95。

新增三项诊断 `diag-finder-hitch-current`：终端滚动系统指标用例实际通过，三次测量记录应用卡顿时长为零，CPU 时间约 0.498–0.528 秒，系统物理内存峰值约 124143–126420 kB；这不是 RSS 长测或帧 P95 达标证明，仍须补充实际视口滚动取证与同条件基线。两个 Finder 用例在准备阶段被 Runner 系统 SSH 认证拒绝，尚未发生真实拖拽，不计通过；需复用已验证的应用内真实 SSH 链路准备和核对远端文件。原 33 项报告保持独立有效，不代表当前 36 项全部通过。

Finder 修正复测 `diag-finder-corrected` 两项均失败在连接断言，未执行拖拽。失败截图明确显示 `kex_exchange_identification: read: Connection reset by peer`；SFTP 目录读取仍成功。该轮完整 xcresult 已取回并导出附件；远端只读日志确认其他时刻公钥认证成功，尚未证明间歇性连接重置的根因。随后 `diag-finder-recovered` 下载准备已通过真实 PTY 创建和写入，但远程目录断言失败；上传仍连接失败。完整失败报告已补取回。远端系统 SSH 服务配置 `inetdCompatibility.Instances=42`，当前 `copy count=41`；多条历史 QA 的 `ssh -tt` 在应用退出后成为 PPID=1 的孤儿进程。核对本轮历史登录 PID 后释放三条已结束测试会话，实例数降至 39，新 SSH 立即成功；又清理一条已结束滚动诊断的确切孤儿客户端。没有重启或修改系统 SSH 服务，没有清理未知用户会话。测试 teardown 现在先调用既有“断开测试终端”操作再终止 QA，并让失败时清理断言继续执行；`diag-finder-pty-cleanup` 正在核验该修复与双向拖拽。

历史完整实体机 UI 报告 `20260927-224451-92066`：33 项，29 passed、4 failed、0 skipped，门禁未通过。失败包括两个设置窗口错误使用 Application.isEnabled 判断、导入取消和分屏控件被其他应用状态栏弹窗遮挡。修正焦点及菜单点击后，`diag-window-focus-menu-current` 五项针对性复测中四项通过，分屏仍失败；不能据此宣称全量通过。

随后分屏专测 `diag-split-clear-toolbar` 实际通过（19.756 秒）：只移动本次 QA 窗口避开持续悬浮的其他应用弹窗，垂直/水平布局、关闭后仅剩一个窗格和按钮消失均通过原断言；未退出其他应用。测试源码重新编译通过，入口脚本回归 17 项通过。当前仍须以最终源码完整重跑 33 项门禁。

2026-09-27 最新实体机证据：指定机器 macOS 27.0 (26A428)，`diag-native-ime-prebuilt-helper-current` 实际执行一项真实 Apple 拼音测试，1 passed、0 failed、0 skipped。截图确认预编辑及“中文”候选，提交前远端文本不变，真实 SSH `read/printf` 回显 `APEX_UI_IME:中文`；测试后独立恢复工具确认原七项输入源与原选择全部恢复，恢复附件随 xcresult 保存。恢复工具在测试前编译，避免测试沙盒内启动编译器；不删除或停用原有搜狗输入法。

该历史阶段测试源码为 33 项；最终 33 项门禁已通过，当前新增后的 36 项仍须完整执行。历史 `20260927-205543-63739` 为 31 项完整通过；`20260927-211702-37780` XCTest 31 项通过但入口收尾失败；`20260927-215241-67257` 主题菜单 hover 无穷坐标导致失败，已改为有限可见矩形中心点击；`20260927-220223-72387` 遭其他应用菜单栏弹窗遮挡 Mocha 标签而失败且被中断，报告不能作为通过证据。关闭遮挡后的 Mocha 六次标签切换独立用例已通过。当前脚本回归 19 项通过。

Tart VM 门禁 `release-vm-gate.log` 已通过：152 项 Swift 测试，零失败，四项可选公网测试跳过；七项真实 VM 集成测试全部执行通过，Swift 6 编译无警告。八项 Release 基准全部达到阈值，RSS 100.86 MB、内部按键 5.03 μs。以上不能替代仍待执行的完整 UI 门禁、原计划其余验收或最新签名候选安装。

依据 macos27-alignment-plan.md 原始阶段 0–8 与覆盖矩阵。此表是待核验事项，不缩小目标；已有基础证据详见 macos27-implementation-verification.md，不能以缺少失败证明替代通过证据。

| 原计划要求 | 当前可用证据 | 仍需完成的证据 |
| --- | --- | --- |
| 同条件基线与优化比较 | baseline/controlled-idle.json、新版前台/后台摘要 | 条件不同的采样不可计算改善比例；帧时间同场景基线/新版结果 |
| 全窗口导航/尺寸/状态 | 主窗口12主题、分隔条动作、全屏进入退出、本体左右/上下分屏与⌘W关闭、⌘T新增/复制 | 最小尺寸、非激活、各分屏比例及状态组合逐项实际截图/键盘操作 |
| 终端真实交互 | VM PTY回显、真实SSH输入/⌘V粘贴与输出保留、合成窗口查找与焦点；真实 Apple 拼音组合/候选/中文提交及输入源恢复通过（diag-native-ime-prebuilt-helper-current） | 2713正常启动真实连接、⌘V命令与回显及SFTP HOME已复核；输入法取消及其他候选补充场景、复制及粘贴补充场景、断线重连与正确窗格关联；合成回调不可替代真实SSH |
| SFTP完整流程 | real-click-roundtrip-proof.json（点击上传下载131072B哈希一致）、集成测试、真实新建文件与编辑保存/重载/列表刷新、空目录及不存在目录错误 | 双向拖拽已各自通过实际落盘、内容哈希、可见完成记录与清理（diag-finder-system-spinner-final 上传、diag-finder-download-geometry 下载）；当前完整门禁仍须证明稳定性。新建/重命名/删除、重复文件、失败/取消的真实窗口证据仍须完整关联 |
| 编辑器与其余页面状态 | 编辑器未保存/查找/真实保存成功与重载、权限失败后恢复重试、关闭取消、页面截图、会话地址/认证验证 | 正常/空/加载/失败/禁用/成功/取消分别关联页面证据，更新检查状态；不能把单页截图覆盖所有状态 |
| 12主题关键页面 | 主窗口全部、编辑器12主题记录、设置外观标签当前视口全部 | 编辑器最终实现复核、会话/监控/传输等关键页面与其他设置标签全主题检查；设置12主题四个非外观标签共48张截图已全部人工检查，文字布局未见裁切；部分首行开关在初次截图缺失。2712单实例复核Mocha两页与Dracula/Latte操作习惯显示正常，Dracula/Latte SFTP开关on/off/on交互及恢复画面通过，Dracula/Latte SFTP未点击开关静置5秒后均完整显示，其他受影响主题仍待同条件复核；底部预览12主题全部人工检查，示例文字完整可读；部分初次截图原生滑块/光标菜单/外观开关缺失，One Dark Pro静置5秒后全部控件完整，其他受影响主题仍需运行时复核 |
| 系统外观/无障碍 | 控件AX动作、布局与主题恢复测试 | 实际VoiceOver、全键盘流程、增强对比度、减少透明度/动态效果、系统浅深外观；系统设置操作确认尚待回复 |
| 性能与稳定性 | 当前011f5ad源码八项Release基准通过（RSS100.22MB、内部按键5.05μs，release-benchmarks-current.log）；2715旧长测工作负载完成但退出超时；指定实体机192.168.50.226当前30分钟负载完成且正常退出（114次输入、38轮双向传输、零失败；real-226-current-result.json） | SwiftUI交互trace已导出，但仍需有效实际交互绘制帧P95；同条件比较、独立于QA仪表的产品内存趋势、选区完整性与最终候选生命周期复查 |
| 候选交付门禁 | 545b976 CI36300851650成功；候选2026092715应用/最终重制HFS+ DMG公证Accepted、票据/严格验签/哈希通过，DMG卷标与包内版本通过；2715 VM独立安装、Gatekeeper启用并接受Notarized Developer ID。本机正常启动、中文搜索/恢复、颜色AX、取消按钮及主窗口退出通过；旧2713真实SSH/更新记录仅作历史证据 | 2715是历史源码候选；2716已完成重建与签名公证，仍需VM实际启动界面与完整流程验收；最终候选真实连接、更新成功/加载/失败及Escape取消待复核。本机spctl的security disabled override不能替代VM启用Gatekeeper验收。逐项收尾上述要求后才可标整体完成 |

证据根目录 outputs/macos27/ 不打入分发包。正式发布独立于内部候选，须另有明确授权。

资源控制：本次验收VM aether-diag-1434已通过tart stop停止，进程消失，主机内存空闲78%、swap 0；后续按需单实例启动，退出后核对App与PTY子进程。

2713外观底部复核：Mocha静置5秒后滑块、光标菜单及开关均可见；Nord同条件仍缺失这些控件（appearance-2713-review.json）。不能将全部缺失归因于截图时机，需继续定位并修复或证明实际窗口绘制正常。

Nord进一步定位：保持Nord设置重新启动候选App、打开并激活外观页后，原生滑块、光标菜单与两开关均完整绘制（Nord-2713-relaunch.png）。缺失目前关联实时切主题后的非激活窗口；尚未证明主题转换与窗口激活分别对缺失的影响，不据此引入强制重建视图。

2713同窗口Mocha→Nord实时切换后，点击标题栏激活窗口，滑块、光标菜单和两个开关均正常（Nord-2713-live-switch-active.png），无需重启或改变控件值。活跃窗口实时切换已通过；非激活绘制仍需独立复核，不能用这张图覆盖非激活要求。

非激活对照工具限制：点击Finder后候选截图仍保留红色关闭按钮、蓝色工具栏及前次指针高亮，未证明捕获了新的失焦状态；Nord-2713-deliberate-inactive.png不作为非激活验收通过证据。下一步应验证截图新鲜度与焦点状态后再判断绘制缺失，避免把缓存画面误判为产品问题。

截图新鲜度对照：通用→终端外观→操作习惯三次捕获的路径、mtime及SHA256均变化，窗口标题与页面对应（screenshot-freshness-2713.json），证明标签切换场景会更新截图；不能据此排除失焦场景缓存。截图原始格式为JPEG，后续证据使用正确扩展名。Nord活跃操作习惯页两个开关及行数控件均可见（Nord-2713-behavior-active.jpeg）。

候选后续源码修复：UpdateManager空版本比较原先会索引空数组；现改为安全取首段，并对更新响应的三个数值版本段验证，无效响应进入failed。UpdateCheckTests五项通过；全量swift test日志tests-invalid-version-full.log通过、无编译警告。候选2713仍为61dcea2旧源码，不包含此修复，最终交付前需更新候选及对应签名门禁。

当前候选更新为2026092714，源码5773a16，已包含无效更新版本修复。146测试（4可选公网跳过）、真实VM、八项Release性能门禁与CI36299347690通过；应用/DMG公证、严格验签、票据、哈希、DMG/tar版本通过，VM启用Gatekeeper安装检查通过。本机正常启动与更新成功/Return关闭已复核。证据VERIFICATION-2026092714.md；旧2713记录仅作历史证据。当前仍缺VM GUI与本表其余完整交互要求，不能判整体完成。

2714新增会话实际表单：空表单保存禁用、Tab名称→主机地址、Escape取消会话仍2个；70000端口显示1–65535错误且保存禁用，恢复22并切Agent可保存（未提交）。Nord错误表单实际图片确认错误文字与固定底部取消/保存按钮未裁切；session-new-flow-2714.json与session-invalid-port-2714.jpeg。此验证未覆盖全部主题、全键盘或实际输入法。

2714表单Tab遍历12步已记录session-tab-flow-2714.json：可确认名称、地址、密码、标签之间循环，部分步骤工具未提供focused元素，未覆盖认证按钮、开关与底部按钮；不能宣称全键盘通过。当前系统键盘导航设置另行只读核查，不修改用户设置。

颜色选择无障碍修复：SessionEditModal颜色按钮新增selected trait及已选中/未选中值。swift build通过；复用现有调试验收App，真实AX默认蓝色selected，点击绿色后仅绿色selected，其他未选中（main-command-smoke/color-ax-default.txt、color-ax-green.txt），未保存表单并退出。签名候选2714尚未包含此源码修复。

会话搜索复核：2714无匹配后清空恢复三个会话；空状态英文已改为中文原生ContentUnavailableView。Debug编译通过，复用调试App真实画面中文字换行完整、AX文案对应，清空后恢复会话（main-command-smoke/search-empty-localized.jpeg/.txt）。此修复尚未进入2714。

最新源码f9baef5对应CI36300245642已完成success，包含颜色选择AX与中文搜索空状态修复；候选2714仍基于5773a16，不能用最新CI声称候选包含后两项修复。真实拖拽验收中已连接VM并显示/tmp/apexterm-drag-2714合成源文件，尚未发生可验证跨窗口拖拽，不计通过。用户反馈电脑负载后已停止该VM和候选App，进程核查无本任务QA/VM残留，空闲内存78%、swap 0；resource-cleanup-current.json保留本轮资源与CI证据。后续先处理低负载核查，重型验收按需单实例执行。

会话编辑回归修复：指定私钥会话不再在打开/保存表单时被隐式转换为Agent；新增仅对原私钥会话显示的指定私钥选项，保存保留keychainRef与passphraseRef。未编辑的跳板机、保活间隔、创建和最近连接时间也保留。颜色AX名称改为中文颜色名。ProductFeatureTests八项通过，新增测试覆盖有/无口令引用及主动切换认证；全量147测试零失败、11环境相关跳过（VM关闭），日志tests-session-retention-full.log无warning/error。尚需实际表单保存、最新CI及新版候选验收，不将单元测试视为GUI通过。

私钥会话实际GUI保存补证：复用单一Verification.app，合成私钥会话打开时指定私钥选中，修改名称并点击保存。session-private-key-saved.json逐项断言证明私钥与口令引用、jumpServerId、47秒保活、创建和最近连接时间均保留；session-private-key-before.txt记录实际AX。普通会话仍只有密码/Agent，颜色中文AX名称也已确认（session-current-color-ax.txt）。退出命令虽返回工具超时，随后ps确认QA/VM进程均无残留。该验证仅使用合成数据，不等于真实私钥连接验收。

私钥会话主动切换补证：真实点击Agent并保存，session-private-key-to-agent.json确认authMethod变为agent且跳板机/保活/时间保持不变，原私钥保留结果另存session-private-key-retained.json。视觉检查发现验收App初始session场景未触发onChange尺寸配置，窗口恢复900×450使固定表单裁切；现仅验收工具启动session时明确设560×560。重新链接成功，session-private-key-size-corrected.jpeg显示标题、认证选项及固定底部按钮完整可见，画面为非激活外观，仍不计激活状态通过。5a3742a当前CI36300632345正在Debug Build，测试及Release尚待执行。

资源与门禁更新：专用VM内存从16384MB调为8192MB（CPU仍6），vm-resource-budget.json记录原值与恢复命令。8GB真实VM运行147测试零失败、4可选公网跳过，7项VM测试通过且结束自动停止；vm-8gb-session-regression.log无warning/error。当前优化构建八项基准九个阈值全部通过（RSS99.92MB、内部按键4.74μs），release-benchmarks-session-retention.log。5a3742a CI36300632345已success。候选构建及VM门禁Swift命令限制jobs2，候选精确旧产物清理逻辑保持；完整打包门禁仍需下一轮实际执行。

当前签名候选2026092715基于545b976，应用/重制HFS+ DMG公证Accepted、票据/严格验签/哈希及DMG挂载内容版本均通过，证据VERIFICATION-2026092715.md。初次默认文件系统DMG挂载导致提交阻塞并最终格式失败，非公证成功；脚本明确HFS+、未挂载断言及镜像校验，防止重现。签名候选本机搜索/颜色AX/取消按钮/主窗口退出通过；Escape连续读取超时，线程采样主线程系统事件等待，未判死锁或通过。VM安装及原计划其余验收仍待完成。


当前真实负载 2715 收尾：1800.171 秒工作负载完成，125 次输入回显与 42 次文件往返内容检查，失败列表为空；申请输出 999920 行，不能作为独立接收行数。监督进程 exit 1：正常退出超过截止时间（real-soak-2715-runtime.log）。实际 QA 应用及虚拟机进程已消失，Tart 状态 stopped。混合负载 RSS 峰值 277.58 MB，末三分钟中位约 267.55–267.73 MB，超过 SOP 250 MB；不能计完整稳定性通过。详见 soak/real-2715-result.json 与 real-2715-memory-final.json。后续需定位退出链路与内存/布局开销；尚未覆盖 IME、拖拽及实际帧 P95。

预算解释复核：计划将 RSS≤250 MB 用于受控基准，真实工作负载单独报告。2715 的受控 Release 基准 RSS101.47 MB 已通过；真实负载峰值277.58 MB不能单独判定预算失败或泄漏。完整稳定性仍未通过，原因是长测正常退出超过监督截止时间且仍欠选区等实际交互证据。新版诊断在模拟5秒、VM真实5秒、用户指定192.168.50.226真实10秒负载中均正常退出（exit0），上传/下载状态completed且字节一致；短测不替代30分钟验收。

SFTP路径同步修正：currentPath变化时，路径框未聚焦或输入仍等于旧路径就同步到新路径；真正编辑中的草稿保留。SFTPOperationsTests 8项通过，实际焦点/目录切换窗口验证仍待执行。本次产品源码变化使545b976/2715候选成为历史包，不能作为最终源码候选交付；收敛后须清理上一轮生成产物并重建签名候选。

路径修正实际窗口证据（Debug QA、192.168.50.226）：启动时路径字段聚焦但未编辑，远端主目录探测后字段正确同步/Users/chenxu，文件列表相符（path-sync-226-focused.txt）；输入测试目录并Return后仅显示qa-payload.bin 256KB（path-sync-226-submitted.txt）。CmdQ正常退出，exec69260 exit0。草稿在异步目录变化时保留的实际场景仍未覆盖。全量swift test --jobs 2退出0，无失败与编译警告，环境相关集成测试跳过，日志full-tests-path-sync.log。

指定机器真实键盘与OSC7联动：Debug QA终端点击后通过实际键盘输入printf标记、cd测试目录及显式OSC7；独立QA_LINK_226回显可见，路径与仅含256KB qa-payload.bin的文件表同步（terminal-linkage-226.txt/jpeg）。这是显式OSC7与真实PTY键盘路由证明，不等同于所有shell自然cd探测、IME或拖拽验收。CmdQ正常退出，exec46483 exit0。

窗口标题解析修正：拒绝包含命令分隔符/空格的身份前缀及URI双斜线，保留host:/path与user@host: ~/中文目录。回归测试与全量swift test通过（full-tests-title-directory.log），命令sleep+printf在执行期间不再产生错误路径（title-fixed-226-before.txt）。真实cd+OSC7+pwd后终端输出/提示符、路径和256KB文件表一致（title-fixed-cd-226.txt/jpeg），CmdQ退出0。草稿在异步通知后保留已有path-draft-226.txt；该行为尚未替代IME/拖拽或所有shell自然提示符验证。

当前源码在用户指定192.168.50.226执行PublicServerIntegrationTests：4项0失败，真实PTY、无代理指标、SFTP列表/随机临时文件上传下载、自然cd目录同步通过（integration-226-current.log，6.36秒）。这是指定实体主机证据，非Tart门禁、非GUI拖拽、非30分钟稳定性替代。

011f5ad Release实体机30分钟负载完成：114次输入回显、38次任务状态completed且字节相同的文件往返，76条传输记录，失败列表为空；输出申请910400行（不是独立接收总数）。SSH断开后等待30秒，应用正常退出exit0，PID45839已消失；真实负载及退出结果real-226-current-result.json，内存汇总real-226-current-memory-final.json。此结果不替代IME、拖拽、选区完整性、实际帧P95或Tart最终候选门禁。

长测内存解释限制：QAProcessTelemetry每秒保留全部samples并序列化重写，RSS含增长的验证仪表开销。011f5ad峰值221.64MB不能直接推断产品单独内存曲线；需独立外部采样/有界仪表对照。工作负载114输入/38往返及正常exit0事实不受此说明改变，禁止将此项等同整个稳定性/性能阶段完成。

当前Animation Hitches短时探测：记录器exit0，render705条、surface swap702条、displayed surface701条、frame lifetime703条；导出表无可靠测试应用归属，未执行规定交互，不能将全局合成层生命周期/刷新周期作为应用P95。frame-current-probe-analysis.json记录未通过归属核验。导出TOC环境段已移除；原始trace含启动环境，不分享、不打包。后续采样应使用最小启动环境并提供可证明的应用surface映射。

当前Release QA在指定机器实际右键下载256KB测试文件：可见记录包含正确远端路径与Downloads目标，传输完成；本地/远端SHA256一致（sftp-click-download-226-proof.json、sftp-download-record-226.txt）。收起传输sheet后CmdQ exit0；sheet打开时CmdQ未退出，不能计直接退出通过。此项是点击下载，不计拖拽。双向拖拽fixture已准备，界面上传授权待回复。

最新候选2026092716基于12bbf6901d56891f25ea7c102cc5783dbd81aa19，候选构建exit0，Tart真实链路与全量测试、八项Release性能门禁、安全扫描、严格验签通过。应用与DMG公证均Accepted、票据有效，两份分发包SHA256独立复核一致。DMG只读挂载确认卷标ApexTerm Candidate、应用及Applications链接，包内与tar版本均1.3.0/2026092716（candidate/package-2716-inspection.json）。此项不覆盖最终候选GUI与VM启用Gatekeeper安装验收，也不替代本表剩余交互项目。

2716正常候选实际GUI补证：中文无匹配空状态、清空搜索恢复3会话、空表单保存禁用、Escape关闭新建sheet且会话仍3个均通过（candidate/gui-2716-basic-proof.json及对应AX记录）；CmdQ后进程核查无候选App。旧2715 Escape超时不再代表当前结果；此项不覆盖其他模态、全部键盘流程或真实连接。

2716更新实际窗口：菜单检查更新返回“已是最新版本”且显示1.3.0，Return关闭结果sheet、恢复主窗口，CmdQ后进程消失（candidate/update-flow-2716.json及两份AX记录）。请求在首次捕获前完成，未观察加载态或失败态，不能将成功结果扩展为全部更新状态通过。

更新状态受控渲染补证：QA工具新增update场景，只在工具中设置UpdateManager状态，不修改产品网络配置。Release链接通过；实际AX确认checking含进度指示及中文文案、failed含警告/关闭/重试。点击重试调用真实检查并转为updateAvailable（QA包缺版本元数据，默认当前1.2.0；不得视为候选2716版本错误）。两轮正常退出exit0。证据qa/update-checking-current.txt、update-failed-current.txt、update-retry-current.txt。模拟失败不是真实HTTP失败证明，直接顶层视图也不证明sheet关闭动作；这些范围仍待补证。

更新失败sheet关闭补证：QA场景改为SwiftUI真实sheet承载未修改的UpdateSheetView。模拟failed状态下Escape关闭、重新打开后点击关闭按钮亦关闭，均恢复宿主窗口；CmdQ exit0。证据qa/update-failure-sheet.txt、update-failure-escape.txt、update-failure-close-button.txt。关闭路径已有直接证据，网络失败仍为模拟注入，不扩展为实际HTTP失败验收。Release验收工具重新链接通过。

更新失败sheet视觉复核：update-failure-sheet.jpeg中标题、错误文案及关闭/重试按钮完整可见，无裁切；当前一次截图不覆盖12主题或激活/非激活全部组合。更新检查5项测试再次通过（update-tests-current.log），覆盖注入HTTP503、网络错误、无效响应及请求去重；这是受控fetch测试，非真实服务器故障。sheet打开时CmdQ未退出，Escape关闭后CmdQ exit0，故正常退出证据明确限定关闭模态之后。

2716指定实体机分发验证：通过SSH/SCP将tar放入192.168.50.226独立/tmp/apexterm-candidate-2716.tV7qYPiM，远端SHA256与本地清单一致，解包版本2026092716，严格深度验签通过。该机器Gatekeeper为assessments enabled，实际spctl接受Notarized Developer ID（candidate/physical-226-2716-verification.log与proof.json）。未替换用户Applications，未启动远端GUI；此证据不覆盖实际安装后的界面与完整流程。

2716实体机启动smoke：确认bundle ID com.apexterm.candidate对应独立会话目录；通过SSH启动实际签名可执行文件，PID51046存活5秒，随后仅终止本轮测试进程，返回-15并核对进程消失（candidate/physical-226-2716-launch.json）。证明能启动及短时存活，不证明远端窗口内容、正常CmdQ退出或完整GUI验收。

进程外RSS对照启动：新增sample_process_memory.py以ps在外部逐行写JSONL、不保留样本，并检查进程启动身份；真实10秒负载加30秒退出等待exit0，内部telemetry文件未生成（soak/external-short-result.json）。当前1800秒对照PID70907、exec85191运行中，禁用QA内部采样，已观察真实输入/传输与新progress，external-long-memory.jsonl持续写入。尚未完成，不将当前RSS或初始样本判为长期趋势通过。

IME静态审计线索：TerminalViewBridge.swift的setMarkedText只设置currentMarkedText/currentMarkedRange；全文件引用搜索未见组合文本绘制，draw仅super与光标，markedRange按已有textStorage尾部减组合长度返回。此为需要真实输入法验证的潜在组合阶段缺陷，不能用insertText提交UTF8正确代替组合可见性和候选位置验收。长测期间未修改产品绘制代码，避免改变当前对照条件。

组合输入回调新增2项回归测试通过：预编辑不发送远端字节且不覆盖输出、候选提交中文/emoji仅发送一次UTF8、丢弃组合不发送输入（ime-composition-tests.log）。不覆盖实际系统输入法、候选定位或组合文本可见性，markedRange静态线索仍未解决。本轮短时swift测试与进程外长测并行发生，后续内存结果须记录此环境干扰，不宣称全程完全空闲。

进程外30分钟对照已完成：117次输入、39轮任务completed且字节一致往返、78条记录、零失败；正常退出exit0，PID70907消失。内部telemetry文件未生成，外部1804样本峰值217.95MB；末三分钟中位214.16、217.02、217.06MB，仍有末段上升，不能宣称完全平稳或无泄漏。证据soak/external-long-result.json、external-long-memory-final.json、external-long-memory.jsonl。短时Swift测试并行及QA工作负载开销已记录；与上一轮仪表不同，不据此计算严格改善比例。输出935360为申请行数，不是独立接收计数。

实体机真实终端复制补证：实际键盘执行printf ASCII标记，选择输出中QA_SELECTION_226__END，经CmdC复制、搜索框CmdV粘贴内容完全一致（qa/selection-real-226.txt、selection-copy-paste-226.txt）；清空搜索、CmdQ exit0。type_text中的中文未进入远端命令，不能计中文输入通过，也未归因于产品或输入法。此项不覆盖负载期间选区保留、输入法或全部复制场景。

2026-09-27 继续完整目标：02b1d7f专用Mac全量UI门禁31/31通过，零失败和跳过；报告ui-acceptance/20260927-205543-63739。当前终端IME审计确认组合文字此前只保存状态、未绘制；现新增独立组合覆盖层，不修改终端历史或提前发送SSH输入，组合范围位于远端输出之后，候选矩形正确转换到屏幕坐标，并向输入法提供组合选区和虚拟组合子串。4项TerminalCompositionTests全部通过：组合阶段不发送、提交UTF8、取消不发送、真实绘制前后差异/取消恢复与候选范围。全量Swift测试无失败但11项环境集成跳过，Release构建无警告，QA宿主重新生成。此为修复与受控绘制证据，不能替代真实系统输入法候选、组合、提交验收。新产品代码使2716签名候选及02b1d7f的UI报告成为历史证据；最终候选须重新执行UI与全部打包门禁后构建。

2026-09-28 Finder 专测继续：`diag-finder-pty-cleanup` 下载拖拽后目标文件未落盘，未通过；上传真实截图显示远端 `ui-drag-payload.txt` 为 256.0 KB，测试却查询 AXTable 而实际原生文件列表为 AXOutline，断言已修正并经 Swift 6 编译通过。这张截图不替代内容哈希及完成记录验证。后续 Finder 专测关闭无关的监控轮询，真实 SSH 与 SFTP 保持。该轮 teardown 断开操作尚未证明消除孤儿进程，不计生命周期修复通过。

`diag-finder-pty-cleanup` 已正常结束并保存完整 xcresult：两项失败，不能算通过。下载首个 QA 退出后客户端 PID 46552 仍为孤儿；上传 QA 与其客户端退出，不能据此覆盖下载生命周期。已清理该确切孤儿。QA 断开操作改为遍历实际 State 标签/分屏，正常退出补同步 PTY 清理，Release QA Swift 6 构建通过（没有 Swift 编译警告）。`diag-finder-outline-live-cleanup` 已启动；下载先实际选中远端行再拖动，目前已越过本地落盘与字节一致性断言，哈希/可见完成记录及生命周期仍待最终结果。上传会自动打开进度 sheet，最新源码补充先核验完成记录并关闭该 sheet，再查询远端 AXOutline，不在 sheet 背后查找目录行；该补充尚待实跑。两轮已结束诊断的重复压缩包清理共释放 850702046 字节，完整 xcresult/截图/日志保留。

传输完成后 XCTest 多次等待应用空闲 60 秒，旧版进程采样包含重复绘制/提交路径；自定义传输图标使用 repeatForever。当前改为系统 ProgressView，仅活动任务存在时挂载，完成后替换静态图标；减少动态效果启用时保留静态活动标识。这是针对动画生命周期的修复，尚不能断言它就是所有空闲超时的根因。最新版 Release 编译与 QA 构建通过，全量 Swift 测试 152 项零失败、11 项环境相关跳过；八项 Release 性能基准全部通过，RSS 峰值 100.70 MB、内部按键 4.95 μs；旧的 `diag-finder-outline-live-cleanup` 仍使用修复前二进制，不能用于证明新图标的 UI 或性能验收。

2026-09-28 最新复验：`diag-finder-outline-live-cleanup` 两项最终失败，完整 xcresult 已收集。下载实际落盘、262144 字节一致性、远端 SHA256 和可见完成记录断言通过，但关闭 Finder 窗口清理失败，因此整项不算通过。最新测试使用 SDK 标准 XCUIIdentifierCloseWindow，上传补自动进度 sheet 的完成与关闭断言；`diag-finder-system-spinner-final` 使用最新系统进度图标二进制复验两项，结果待定。三个已结束远端诊断目录经报告 Info.plist 哈希和 QA 身份匹配、无活动进程核查后，仅清理生成的压缩包、DerivedData 和 QA.app，释放 1398005976 字节；完整报告和测试源码保留。正式版本发布继续跳过。

Finder 最新结果：`diag-finder-system-spinner-final` 上传完整通过（77.537 秒），包含 262144 字节真实 SHA256 与可见记录、清理；下载目标未落盘，失败。`diag-finder-download-hover` 调整落点、速度和停留后仍失败，完整 xcresult/附件已保存，不能据此证明动画修改影响拖拽。新增实际 source/Finder/app CGRect 与 Finder AX 树附件，`diag-finder-download-geometry` 单项正在执行以定位事件落点；全量 36 项仍未通过。

下载专测 `diag-finder-download-geometry` 最终成功：1 项、零失败，80.592 秒，报告与 summary 已保存。真实落盘、262144 字节一致、远端 SHA256、可见完成记录、Finder 窗口关闭与 fixture 清理通过；QA/workspace 进程事后为空（process-after.json），这不单独证明所有 SSH 子进程生命周期。几何附件显示 Finder=(22,150,920,436)、App=(502,219,960,680)，使用 Finder 内偏移(350,200)、低速拖拽并停留 1 秒。此前同条件专测仍曾失败，因此稳定性必须由完整门禁继续验证。当前 `release-current-36-full-gate.log` 对应当前源码 36 项完整门禁正在执行；不能提前计通过。四轮已收集诊断的重复输入/结果压缩包清理释放 1166206912 字节，完整报告保留。

CPU 测量工具已新增 `scripts/verification/sample_process_cpu.py`：以进程外累计 CPU 时间差除以单调时钟耗时，报告单核百分比；检查 PID 启动身份、保护既有输出，目标退出则拒绝有效结果。短时自有 sleep/单核忙循环校准分别为 0%/约 95.23%，非有限及负时长提前拒绝，目标提前退出校准也拒绝。工具不自动声称验收通过，后续仍须实际核对四类空闲场景及至少 60 秒、同条件基线；这些校准不证明 ApexTerm CPU 达标。
