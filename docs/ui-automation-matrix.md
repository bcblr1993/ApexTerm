# UI 自动化与发布门禁

每次正式发布与签名候选构建必须执行 `bash scripts/test_ui_acceptance.sh`。入口已接入 `scripts/build_app.sh` 和 `scripts/build_candidate.py`，任何编译、权限、连接或断言失败都停止后续打包，不允许跳过。两个构建入口在清理旧产物或启动虚拟机之前先执行--preflight-only；预检查通过只证明前置条件，不替代后面的全量UI执行。CI编译测试工程；本地发布机执行实际窗口测试，两者不可互相替代。

测试工程为 `UITests/ApexTermUITests.xcodeproj`，使用XCUITest实际点击、输入和键盘操作。隔离QA宿主链接当前Release产品模块，每次自动化启动使用UUID独立会话目录，恢复QA默认偏好，不读取正式应用会话库。偏好重置要求QA应用标识前缀，避免应用标识配置错误时改写正式偏好。系统主题、输入法、安全权限不由脚本静默修改。报告按每次运行独立保存到 `outputs/ui-acceptance/<时间>-<PID>/UI.xcresult`，包含截图、断言和失败日志；前置条件检查即创建报告，run-status.txt记录失败阶段与退出码，构建和执行分别留日志；不进入分发包或Git。

运行前需要解锁的macOS桌面、完整Xcode、已通过用户认证开启的Automation Mode、可无交互SSH登录的专用测试机器。测试主机通过 `APEX_UI_TEST_HOST`、`APEX_UI_TEST_USER` 配置，不在代码内保留地址或凭据。缺少配置直接失败，真实连接测试没有skip回退。

```bash
APEX_UI_TEST_HOST=<测试主机> APEX_UI_TEST_USER=<测试用户> bash scripts/test_ui_acceptance.sh
```

| 验收类别 | 当前自动化入口 | 验证范围与剩余项 |
| --- | --- | --- |
| 会话搜索 | testSearchEmptyAndRecovery | 无匹配中文状态、清空恢复；当前实现仍需实际Runner运行验证 |
| 会话表单 | testSessionEmptyInvalidPortAndCancel、testSessionValidPortRecoveryAndSave；ProductFeatureTests | 空表单禁用、无效端口、Escape取消；认证元数据保留有单元测试。已编写无效端口恢复有效、保存后计数增加及搜索可见断言；标签、颜色、复制表单和其余键盘路径待扩充 |
| 更新 | testUpdateFailureCloseAndReopen、testUpdateLoadingAndSuccess；UpdateCheckTests | 实际sheet加载/失败/成功与关闭；HTTP错误、无效响应、去重有受控测试。真实故障注入待补 |
| 文件列表状态 | testSFTPEmptyLoadingAndFailureStates、testSFTPFilterEmptyClearAndEscape、testSFTPDirectoryFailureRetryRecovers、testSFTPPathDraftCancelEmptyAndSubmit、testSFTPHiddenFilesToggleAndKeyboardRecovery；SFTPOperationsTests | 空、加载、失败界面；新增过滤无匹配、清空恢复、匹配项/排除项及Escape收起恢复断言；新增一次失败后点击重试恢复文件列表且移除错误状态断言；新增路径草稿Escape还原、空白提交还原、有效路径去除首尾空格的窗口断言；新增菜单显示点文件、⌘⇧.隐藏点文件及普通文件保留断言；后端请求次数及终端联动仍待自动化验证 |
| 主题与页面 | testAllThemesAndPagesRender；ThemeSupportTests | 12主题×9页面及5个设置标签遍历，增加会话/编辑器/更新/传输/导入关键控件存在或可点击断言、设置标签选中及滑块/开关检查；尚未实际运行。截图采集不等同像素/裁切验证，需补截图基线与不同窗口尺寸 |
| 真实终端 | testRealSSHConfiguredHostIsMandatory；VMIntegrationTests、PublicServerIntegrationTests | 真实键盘→PTY→输出断言；输入法候选、UTF8粘贴、选区负载保留、重连与分屏关联待扩充 |
| 复制与组合回调 | TerminalCopyAndContextMenuTests、TerminalCompositionTests | 快捷键字节路由、组合提交/取消；回调测试不代替系统输入法 |
| SFTP完整流程 | testSFTPCreateFileCancelAndSuccessfulListing、testSFTPRenameCancelAndSuccessfulListing、testSFTPCreateFolderCancelAndSuccessfulListing、testSFTPDeleteConfirmationCancelAndRemoveOwnFixture；VMIntegrationTests、SFTPOperationsTests | 已编写隔离模拟目录的新建取消不产生条目、提交后条目可见且原条目保留断言；新增文件夹取消不产生条目、名称去除首尾空格、创建后可见及双击进入路径断言；新增重命名取消保留原名、成功后新名出现/旧名消失且无关条目保留断言；真实协议与字节完整性已有集成测试；新增仅删除本用例创建的模拟文件、取消确认保留条目、确认后移除且无关条目保留断言；双向拖拽、记录可见路径、真实主机文件操作、重复/失败/任务取消的GUI自动化待补 |
| 编辑器 | testEditorUnsavedCancelSaveAndClose、testEditorSaveFailureKeepsChanges、testEditorSaveFailureRetryRecovers、testEditorReloadCancelAndDiscard、testEditorReloadFailureRetryPreservesContent、testEditorChangesDuringSaveRemainUnsaved、testEditorKeyboardFindUndoAndSave；QuickEditorAndSFTPItemTests；主题页面截图 | 已编写真实sheet修改、未保存关闭取消、保存禁用/完成/关闭、失败保留内容断言；编译通过但Automation Mode未授权，尚未运行。已编写重载取消保留草稿/放弃后远端内容替换断言；另覆盖保存途中继续编辑后仍提示未保存、再次保存后关闭；新增原生查找不改变内容、撤销/重做及⌘S/⌘W流程断言；新增保存首次失败后再次保存成功、错误消失、内容保留、正常关闭且无未保存提示断言；另覆盖重载失败保留内容、再次重载成功替换远端内容并关闭；全部新增用例仍需实际Runner验收 |
| 传输任务中心 | testTransferRecordFiltersAndClearCompleted | 受控成功上传与失败下载记录、全部/上传/下载筛选、清空成功记录而保留失败；仅状态注入，不代表真实文件传输通过，实际Runner尚未执行 |
| 主窗口 | testTerminalSplitOrientationAndClose；UIStateTests、SplitPaneIntegrationTests；主题页面截图 | 新增受控终端左右/上下分屏的窗口位置、两窗格计数及关闭后单窗格断言；状态与分屏模型已有单元测试；全屏、最小尺寸、非激活、分隔比例与标签关闭实际窗口断言待补 |
| OpenSSH导入 | testSSHConfigImportSelectionAndDuplicateRecovery、testSSHConfigImportSheetCancelDoesNotImport | 隔离配置的全选/取消全选、空选择禁用、导入成功提示、会话可搜索及重复导入不增加计数；新增真实sheet Escape/取消关闭、重新打开及取消后会话计数不变且导入主机不可搜索断言；畸形配置错误页待补，当前用例尚未实际运行 |
| 系统无障碍 | 既有AX操作证据与主题对比度测试 | VoiceOver、全键盘访问、增强对比度、减少透明度/动态效果、系统外观尚未转为自动化；需隔离桌面及授权，不修改日常系统设置 |
| 性能稳定性 | test_vm_acceptance.sh、FullPerformanceBenchmarkTests；外部RSS采样工具 | 八项基准已有发布门禁；30分钟真实负载、应用归属帧P95与同条件基线尚需接入自动化报告与阈值 |

当前状态：测试工程已在Xcode27/Swift6编译通过；实际执行被“Timed out while enabling automation mode”阻塞，系统确认Automation Mode disabled且需要用户认证。没有将零条执行或编译成功计为UI通过。上述待补项表示全量UI自动化仍未完成，本门禁是可执行基础，不能据此声称历史UI验收全部覆盖。

后续新增UI修复必须在表中找到对应场景或新增场景，并将真实窗口行为纳入断言。无需真实网络的受控UI状态和真实SSH/SFTP场景分别记录，所有release-required场景应由同一入口执行。截屏、人眼历史记录、窄单元测试均不代替实际窗口行为断言。

结果门禁：xcresulttool导出summary后，verify_ui_results.py要求Passed、当前全部测试数量一致、零失败/跳过/预期失败。结果校验的3项Python测试通过，实际Automation Mode失败xcresult也已实测被拒绝。另逐条核对测试名称及结果，重复测试不能替代漏跑测试。此校验是执行完整性检查，不等于全量历史UI需求覆盖证明。
