# UI 自动化与发布门禁

最新签名候选源码 `1b1bcb0` 完整报告为 `20260928-011558-21195`：36 passed、0 failed、0 skipped。后续快捷键首屏专测 `shortcuts-visibility-20260928-020509` 通过，12 主题标题及上下关闭按钮可见性已增加断言并审阅截图。

最近完成的完整门禁 `20260928-023520-36976` 为 37 passed、0 failed、0 skipped，入口 stage=passed；258 个附件已导出核验，44 个产品源码哈希与测试源码事后一致。随后修正保留历史时的关闭提示和真实断线后的 toolbar 刷新，增加原生 CPU/内存历史图表与自适应详情高度。

当前未提交源码清单为 38 项。`testMonitoringStatesAreExplicit` 覆盖实时、过期、等待、关闭、关闭保留历史、断线保留历史；图表六状态专测 `metrics-chart-20260928` 已通过，实时图表截图已审阅。新增 `testRealSSHMonitoringDisconnectAndReconnect` 使用真实 SSH 采样、断开、历史提示、重连，并要求新采样时间晚于重连操作，专测 `real-monitor-fresh-20260928` 已通过并导出 JSON。当前完整门禁 `20260928-033023-49254` 已失败：12 passed、2 failed、0 skipped，仅执行 14 个结果，未完成 38 项覆盖。一项为真实拼音提交失败，另一项为 Runner 开启 Automation Mode 超时；隔离复测也在执行测试前遭遇认证阻塞。不得计为通过；全主题详情必须含可见历史图表。诊断子集不替代完整门禁，下文旧数量与运行状态是历史记录。

2026-09-28 当前完整门禁已通过：`20260928-003341-13677`，36 passed、0 failed、0 skipped，入口 stage=passed、exit_code=0；用例清单/名称/测试源码校验通过，45 个源码与 QA 产物哈希事后未变，远端 QA 二进制与本地一致。双向 Finder 拖拽、真实拼音、真实 SSH/SFTP、终端系统指标、12 主题及其余操作完整执行。此报告证明当前 UI 门禁，不替代原计划性能/无障碍或最新签名候选安装验收。下文运行中与失败描述为历史过程。

最新已验证完整报告 `20260927-230435-96848`（源码 `200f538`）：33 passed、0 failed、0 skipped，入口与清单校验通过。随后接入 Finder 双向真实拖拽和终端滚动系统指标，当前 36 项，新增三项已各自实跑通过；当前源码的完整 36 项门禁正在执行，尚未计通过。本次按用户要求跳过正式发布，不打 tag、不上传发布包。

每次正式发布与签名候选构建必须执行 `bash scripts/test_ui_acceptance.sh`。入口已接入 `scripts/build_app.sh` 和 `scripts/build_candidate.py`，任何编译、权限、连接或断言失败都停止后续打包，不允许跳过。两个构建入口在清理旧产物或启动虚拟机之前先执行--preflight-only；预检查通过只证明前置条件，不替代后面的全量UI执行。CI编译测试工程；发布门禁必须实际执行窗口测试。设置APEX_UI_RUNNER_HOST与APEX_UI_RUNNER_USER可在专用Mac执行；设置APEX_UI_TEST_VM则使用已启动并解锁的Tart虚拟机。两种远程模式均在目标机重编译Runner以匹配其Xcode版本，单进程运行并收集成功或失败的xcresult，再由同一个严格结果门禁验收。

测试工程为 `UITests/ApexTermUITests.xcodeproj`，使用XCUITest实际点击、输入和键盘操作。隔离QA宿主链接当前Release产品模块，每次自动化启动使用UUID独立会话目录，恢复QA默认偏好，不读取正式应用会话库。偏好重置要求QA应用标识前缀，避免应用标识配置错误时改写正式偏好。系统主题和安全权限不由脚本静默修改。真实拼音用例临时启用 Apple 系统拼音父项/模式，测试后恢复原选择与完整输入源集合；清理包含 macOS 自动生成的备用拼音布局，并在独立进程复核，清理失败同样导致门禁失败。报告按每次运行独立保存到 `outputs/ui-acceptance/<时间>-<PID>/UI.xcresult`，包含截图、断言和失败日志；前置条件检查即创建报告，run-status.txt记录失败阶段与退出码，测试源码快照和SHA256随报告保存，运行期间测试源码变化会拒绝打包，构建和执行分别留日志；不进入分发包或Git。

运行前需要解锁的macOS桌面、完整Xcode、允许Xcode通过用户认证临时开启Automation Mode的权限、可无交互SSH登录的专用测试机器。测试主机通过 `APEX_UI_TEST_HOST`、`APEX_UI_TEST_USER` 配置，不在代码内保留地址或凭据。缺少配置直接失败，真实连接测试没有skip回退。

```bash
APEX_UI_TEST_HOST=<测试主机> APEX_UI_TEST_USER=<测试用户> bash scripts/test_ui_acceptance.sh
```

| 验收类别 | 当前自动化入口 | 验证范围与剩余项 |
| --- | --- | --- |
| 会话搜索 | testSearchEmptyAndRecovery | 无匹配中文状态、清空恢复；已在专用Mac真实执行通过 |
| 会话表单 | testSessionEmptyInvalidPortAndCancel、testSessionValidPortRecoveryAndSave；ProductFeatureTests | 空表单禁用、无效端口、Escape取消；认证元数据保留有单元测试。已编写无效端口恢复有效、保存后计数增加及搜索可见断言；标签、颜色、复制表单和其余键盘路径待扩充 |
| 更新 | testUpdateFailureCloseAndReopen、testUpdateLoadingAndSuccess、testUpdateAvailableVersionNotesAndEscape；UpdateCheckTests | 实际sheet加载/失败/成功与关闭；另覆盖受控新版本标题、版本号、更新说明、按钮可点击及Escape关闭，不点击下载链接；HTTP错误、无效响应、去重有受控测试。真实故障注入待补 |
| 文件列表状态 | testSFTPEmptyLoadingAndFailureStates、testSFTPFilterEmptyClearAndEscape、testSFTPDirectoryFailureRetryRecovers、testSFTPPathDraftCancelEmptyAndSubmit、testSFTPHiddenFilesToggleAndKeyboardRecovery；SFTPOperationsTests | 空、加载、失败界面；新增过滤无匹配、清空恢复、匹配项/排除项及Escape收起恢复断言；新增一次失败后点击重试恢复文件列表且移除错误状态断言；新增路径草稿Escape还原、空白提交还原、有效路径去除首尾空格的窗口断言；新增菜单显示点文件、⌘⇧.隐藏点文件及普通文件保留断言；后端请求次数及终端联动仍待自动化验证 |
| 主题与页面 | testAllThemesAndPagesRender；ThemeSupportTests | 12主题×9页面及5个设置标签遍历，增加会话/编辑器/更新/传输/导入关键控件存在或可点击断言、设置标签选中及滑块/开关检查；已在专用Mac完整运行通过。截图采集不等同像素/裁切验证，需补截图基线与不同窗口尺寸 |
| 真实终端 | testRealSSHConfiguredHostIsMandatory、testTerminalDisconnectedReconnectRestoresInput；VMIntegrationTests、PublicServerIntegrationTests | 真实键盘→PTY→输出断言，并新增实际SSH客户端断开、点击重连及重连后新标记命令输出断言，尚未Runner实跑；另新增模拟连接实际disconnect、提示/重连按钮、恢复连接后键入可见断言，不代替真实主机重连；输入法候选、UTF8粘贴、选区负载保留、分屏关联与中断恢复边界待扩充 |
| 真实系统拼音 | testRealSSHBuiltinPinyinCompositionAndCommit | 真实 Apple 拼音键入、候选截图、提交前远端文本不变、候选提交后远端 read/printf 回显中文；输入源配置自动恢复。独立实体机用例通过（diag-native-ime-prebuilt-helper-current，1 passed、0 failed、0 skipped），原七项输入源与原选择恢复已核对；完整 33 项门禁已通过，新增 36 项清单待完整重跑 |
| 设置页输入焦点 | testMochaSettingsTabsRemainClickable | Mocha 六次标签切换真实点击及选中状态；实体机独立用例及完整全主题用例均已通过，其他应用菜单栏弹窗可遮挡测试 |
| 复制与组合回调 | TerminalCopyAndContextMenuTests、TerminalCompositionTests | 快捷键字节路由、组合提交/取消；回调测试不代替系统输入法 |
| SFTP完整流程 | testSFTPCreateFileCancelAndSuccessfulListing、testSFTPRenameCancelAndSuccessfulListing、testSFTPCreateFolderCancelAndSuccessfulListing、testSFTPDeleteConfirmationCancelAndRemoveOwnFixture；VMIntegrationTests、SFTPOperationsTests | 已编写隔离模拟目录的新建取消不产生条目、提交后条目可见且原条目保留断言；新增文件夹取消不产生条目、名称去除首尾空格、创建后可见及双击进入路径断言；新增重命名取消保留原名、成功后新名出现/旧名消失且无关条目保留断言；真实协议与字节完整性已有集成测试；新增仅删除本用例创建的模拟文件、取消确认保留条目、确认后移除且无关条目保留断言；双向拖拽、记录可见路径、新增真实SSH用例创建专用临时目录、GUI新建文件、远端test -f确认、GUI删除并rmdir清理断言，尚未实跑；双向字节传输、重复/失败/任务取消的GUI自动化待补 |
| 编辑器 | testEditorUnsavedCancelSaveAndClose、testEditorSaveFailureKeepsChanges、testEditorSaveFailureRetryRecovers、testEditorReloadCancelAndDiscard、testEditorReloadFailureRetryPreservesContent、testEditorChangesDuringSaveRemainUnsaved、testEditorKeyboardFindUndoAndSave；QuickEditorAndSFTPItemTests；主题页面截图 | 已编写真实sheet修改、未保存关闭取消、保存禁用/完成/关闭、失败保留内容断言；编译通过但Automation Mode未授权，尚未运行。已编写重载取消保留草稿/放弃后远端内容替换断言；另覆盖保存途中继续编辑后仍提示未保存、再次保存后关闭；新增原生查找不改变内容、撤销/重做及⌘S/⌘W流程断言；新增保存首次失败后再次保存成功、错误消失、内容保留、正常关闭且无未保存提示断言；另覆盖重载失败保留内容、再次重载成功替换远端内容并关闭；真实SSH用例另加入SFTP打开自有临时文件、编辑保存成功提示及SSH读取内容比对，尚未实跑；全部新增用例仍需实际Runner验收 |
| 传输任务中心 | testTransferRecordFiltersAndClearCompleted、testTransferCancelAndClearPreservesActiveTask | 受控成功上传与失败下载记录、全部/上传/下载筛选、清空成功记录而保留失败；另覆盖取消变为已取消、清空已取消记录保留活动任务；仅状态注入，不代表真实文件传输或底层任务停止通过，实际Runner尚未执行 |
| 主窗口 | testTerminalSplitOrientationAndClose；UIStateTests、SplitPaneIntegrationTests；主题页面截图 | 新增受控终端左右/上下分屏的窗口位置、两窗格计数及关闭后单窗格断言；状态与分屏模型已有单元测试；全屏、最小尺寸、非激活、分隔比例与标签关闭实际窗口断言待补 |
| OpenSSH导入 | testSSHConfigImportSelectionAndDuplicateRecovery、testSSHConfigImportSheetCancelDoesNotImport、testSSHConfigEmptyImportDisabledAndCancel | 隔离配置的全选/取消全选、空选择禁用、导入成功提示、会话可搜索及重复导入不增加计数；新增真实sheet Escape/取消关闭、重新打开及取消后会话计数不变且导入主机不可搜索断言；新增空配置中文空状态、禁用导入、无全选及取消返回；畸形配置错误页待补，当前用例尚未实际运行 |
| 系统无障碍 | 既有AX操作证据与主题对比度测试 | VoiceOver、全键盘访问、增强对比度、减少透明度/动态效果、系统外观尚未转为自动化；需隔离桌面及授权，不修改日常系统设置 |
| 性能稳定性 | test_vm_acceptance.sh、FullPerformanceBenchmarkTests；外部RSS采样工具 | 八项基准已有发布门禁；30分钟真实负载、应用归属帧P95与同条件基线尚需接入自动化报告与阈值 |

历史状态：该阶段测试源码为 33 项，新增真实系统拼音和 Mocha 设置标签回归；33 项最终完整通过。下列 31 项记录属于更早源码。当前源码为 36 项，完整门禁正在执行；用户要求跳过正式发布，不打 Tag、不上传版本，实体机 UI 验证继续。

历史状态：2026-09-27在用户指定的专用Mac实际运行完整发布入口，31条UI测试全部通过，0失败、0跳过，严格数量与名称门禁通过。最终报告为`outputs/ui-acceptance/20260927-205543-63739`，run-status为passed、exit_code为0。实际覆盖12主题×9页面与5设置标签，编辑器查找、保存/重载失败重试及关闭，会话表单，SFTP目录与文件操作，SSH配置导入，分屏、传输记录和更新窗口；真实SSH/SFTP用例完成终端输入、断线重连、创建文件、编辑保存、SSH读取核对内容和清理自有临时文件。测试发现XCTest按钮焦点切换可能插入Tab，重载重试用例改用真实坐标鼠标点击并严格核对重载后的全文，完整套件已验证通过。连续键入两个空格会触发系统句号替换；裁剪测试使用首尾各一个空格验证应用裁剪逻辑，此项不构成关闭系统句号替换的证明。Tart不再启动，本轮在专用Mac执行。Automation Mode在空闲时disabled不代表没有执行权限：Xcode可能在执行期间临时启用，执行后关闭，因此预检查只记录此状态，实际执行与结果校验仍为强制门禁。脚本回归19项通过，8项Release性能基准达到阈值；普通Swift测试无失败但有11项集成环境跳过，不能等同完整集成验收。表中待补场景与原macOS27全流程验收仍需继续，31条通过不代表所有历史UI需求均已覆盖，也不代表新签名候选包已交付。

后续新增UI修复必须在表中找到对应场景或新增场景，并将真实窗口行为纳入断言。无需真实网络的受控UI状态和真实SSH/SFTP场景分别记录，所有release-required场景应由同一入口执行。截屏、人眼历史记录、窄单元测试均不代替实际窗口行为断言。

结果门禁：xcresulttool导出summary后，verify_ui_results.py要求Passed、当前全部测试数量一致、零失败/跳过/预期失败。结果校验的3项Python测试通过，实际Automation Mode失败xcresult也已实测被拒绝。另逐条核对测试名称及结果，重复测试不能替代漏跑测试。此校验是执行完整性检查，不等于全量历史UI需求覆盖证明。

本机目标配置：入口自动读取被Git忽略的`.ui-acceptance.env`，仅配置测试端点与用户，不存储密码或私钥。环境变量可覆盖默认配置，APEX_UI_CONFIG_FILE可指定其他配置文件。远程SSH使用临时agent转发，测试启动时传递有效SSH_AUTH_SOCK；不复制私钥。运行结束后SSH转发随连接关闭，诊断目录保留供审阅。该配置不进入应用资源。

远程运行每轮为QA宿主分配独立应用标识，XCUITest通过绝对应用路径启动；qa-host.json记录路径、应用标识和可执行文件SHA256，避免Launch Services缓存导致误测旧宿主。结果压缩后一次传回，诊断子集仅供修复定位；发布入口不传选择器，必须执行全部测试并严格验证数量、名称、失败与跳过。

CI兼容性补证：c2c680f的CI36321964220在脚本回归失败。已在本机/usr/bin优先PATH复现：Bash3.2配合EXIT trap时，缺少主机的`${VAR:?}`参数展开错误最终返回0，Bash5返回1。发布门禁改为显式空值检查和exit1，并在测试中覆盖PATH默认bash及/bin/bash。19项脚本回归、系统Bash下4项门禁回归全部通过。此修复确保缺少配置拒绝发布，而非放宽测试；云端仍需新提交实际通过。

Finder 独立证据：上传 `diag-finder-system-spinner-final` 77.537 秒通过；下载 `diag-finder-download-geometry` 80.592 秒通过。两者均断言实际文件内容 SHA256、262144 字节一致性、可见完成记录及清理；下载之前有不稳定失败，须继续由完整门禁验证。终端系统滚动指标单项已有独立通过证据，但不等同于显示帧 P95、端到端输入延迟或长期内存验收。
