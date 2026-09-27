# macOS 27 剩余验收清单

依据 macos27-alignment-plan.md 原始阶段 0–8 与覆盖矩阵。此表是待核验事项，不缩小目标；已有基础证据详见 macos27-implementation-verification.md，不能以缺少失败证明替代通过证据。

| 原计划要求 | 当前可用证据 | 仍需完成的证据 |
| --- | --- | --- |
| 同条件基线与优化比较 | baseline/controlled-idle.json、新版前台/后台摘要 | 条件不同的采样不可计算改善比例；帧时间同场景基线/新版结果 |
| 全窗口导航/尺寸/状态 | 主窗口12主题、分隔条动作、全屏进入退出、本体左右/上下分屏与⌘W关闭、⌘T新增/复制 | 最小尺寸、非激活、各分屏比例及状态组合逐项实际截图/键盘操作 |
| 终端真实交互 | VM PTY回显、真实SSH输入/⌘V粘贴与输出保留、合成窗口查找与焦点 | 2713正常启动真实连接、⌘V命令与回显及SFTP HOME已复核；实际输入法候选/组合/提交、复制及粘贴补充场景、断线重连与正确窗格关联；合成回调不可替代真实SSH |
| SFTP完整流程 | real-click-roundtrip-proof.json（点击上传下载131072B哈希一致）、集成测试、真实新建文件与编辑保存/重载/列表刷新、空目录及不存在目录错误 | 双向拖拽实际目录/记录与哈希；新建/重命名/删除、重复文件、失败/取消的真实窗口证据 |
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
