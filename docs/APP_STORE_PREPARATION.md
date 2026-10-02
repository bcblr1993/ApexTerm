# App Store 构建准备

本分支用于独立开发商店分发能力，不能把这里的局部测试结果当作正式商店包验收。

关于窗口提供可访问的「隐私政策」链接，指向官网 ApexTerm 专属政策页面。现有官网页面仍需按实际行为修正：指定私钥保留在用户选择的本地文件中，钥匙串保存密码与私钥口令；官网下载渠道会访问 GitHub 检查更新，商店渠道使用 App Store。上传前必须核对政策正文及 App Store Connect 的隐私信息，不能仅凭链接存在宣称这些检查已完成。

商店包的 `Info.plist` 必须设置 `ApexDistributionChannel=appStore`。该渠道的启动过程不会请求 GitHub 更新，设置及菜单的更新入口打开 App Store；更新管理器也会阻止显式官网包下载和已暂存应用替换。普通分发默认仍为 `direct`。

`Resources/AppStore/ApexTerm.entitlements` 是主程序的基础沙盒权限；独立 SSH helper 使用 `SSHHelper.entitlements` 继承主程序沙盒。商店签名时，应用标识、Team 与钥匙串 access group 必须按匹配且有效的 provisioning profile 写入，不能用权限模板冒充签名身份或有效 profile。

`Resources/AppStore/PrivacyInfo.xcprivacy` 声明实际使用的应用自有 UserDefaults（CA92.1），以及容器内文件元数据（C617.1）和用户选择文件的元数据（3B52.1）。`fstat` 用于授权请求和信任文件的权限/大小检查，文件大小查询用于传输进度；这些信息不用于追踪。尚需按最终 Mach-O 与 helper 审核其他 API。隐私声明不等于隐私问卷已填写或后台已经接受构建。

已接入持久文件书签：私钥浏览与下载目录选择保存用户授权，目录或私钥移动时解析到新路径；SSH/SCP 操作及传输队列保持授权直到完成或取消。单文件和批量下载使用设置里的目录，商店渠道首次缺少目录授权时要求用户选择目录。书签存储和队列生命周期已有单元测试，这些测试在非沙盒进程中运行，不能替代真实沙盒包的验证。

Apple 的 App Sandbox inheritance 文档明确子进程只继承静态权限；对启动后选择的文件需传递数据或书签。商店调用链现在将普通跨进程书签写入应用私有临时目录中的0600授权请求，不复制私钥正文；`ApexSSHBridge` 在同一进程内解析书签后 `exec` 系统 SSH/SCP。SCP 的 `-S` 指向同一个 helper，让内部 SSH 子进程重新解析授权。请求文件保持到进程结束或取消后删除；PTY 请求保持到连接终止。缺少 helper 或授权请求时拒绝执行，不回退为裸路径调用。

普通官网下载包没有使用这个组件，商店包必须另行捆绑并用 `SSHHelper.entitlements` 签名 `ApexSSHBridge` 及 sshpass。普通 CLI 测试验证了协议、请求权限/拒绝符号链接、实际 helper exec 和内部 SSH 入口。另在 macos27 运行了独立、ad hoc 签名的 Foundation 沙盒命令行探针：未授权文件读取被拒绝、用户文件书签在 helper exec 系统 SSH 后仍有效，SSH 从选中配置实际读取 Port 2222，PTY 分配成功、请求删除成功。探针未启动UI，测试目录和独立容器已删除。这证明该机制在有效沙盒中可用，仍不等于正式商店包的 UI/SSH/SFTP 验收。跳板 SSH 的独立私钥/口令和 SSH agent 也需要补齐沙盒验收。

本阶段全量 `swift test`：316项、0 failures、14个未配置远程环境的集成测试skip，编译0 warning/error。另有7项新增私钥/传输租约生命周期回归通过。跳过的集成测试及非沙盒单元测试不能当作正式发布质量门禁全通过。

商店渠道已将 known_hosts 放在应用自有 Application Support 目录，保持0700/0600权限且拒绝符号链接/错误权限，不覆盖已有信任记录。SSH 显式指定该文件；控制 socket 使用应用临时目录并检查 Darwin 104字节边界，每个会话独立，关闭连接也通过授权 helper。应用的配置导入提供文件选择器，持有只读授权完成解析并记住上次选择；导入会话使用解析得到的显式字段，不隐式执行用户主目录的配置。官网下载渠道仍使用原有路径。

仍需完成跳板/agent的沙盒能力、商店专用打包与签名、最终沙盒包在 Tart `macos27` 中的完整 UI/SSH/SFTP 验收，以及上传后的 App Store Connect 检查。正式发布仍需遵守主干、全量测试、签名与安全扫描门禁。

官方资料：

- https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest

子进程权限依据：https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html#//apple_ref/doc/uid/TP40011195-CH3-SW11

当前跨进程书签文档：https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox

书签传递 helper 阶段最终验证：`swift test` 335项、0 failures、14项未配置远程环境的skip，0编译warning/error；授权/进程边界专项35/35通过。helper临时请求使用`O_CREAT|O_EXCL`与0600权限，防止覆盖已有文件；读取拒绝符号链接、其他用户可读文件、未知协议及超大内容。路径修正只针对SSH本地文件选项及SCP本地文件操作数，远端命令保持原样。测试均不是签名沙盒验收。

SSH路径阶段全量验证：342项、0 failures、14远程skip，0编译warning/error。配置导入界面随后通过编译及23项相关回归；选择器的实际UI验收等待VM完整商店包。OpenSSH实际`-G`检查覆盖带空格的信任路径，其他测试覆盖保留信任内容、权限、符号链接、UTF8 socket边界和远端命令不改变配置隔离。

文件元数据理由依据：https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype

OpenSSH配置依据：https://man.openbsd.org/ssh.1 和 https://man.openbsd.org/ssh_config.5

2026-10-02 主干同步后验证：全量 `swift test` 342项，328通过、14项因未配置外部环境跳过、0失败、0 Swift编译警告。另向真实 macos27 执行10项SSH/SFTP/Vim集成测试，全部通过；这些由主机测试进程发起，不代表最终沙盒包已通过验收。UI测试目标编译通过，但仍待实际运行；Xcode的AppIntents元数据工具提示本目标没有AppIntents.framework依赖。

拖拽导出现在等待主线程记录开始、完成或取消状态后再返回文件回调，防止取消回调已结束但传输列表仍显示进行中；16项相关回归通过。

商店签名准备已完成：Mac App Distribution和Mac Installer Distribution均在本机钥匙串中，分别通过独立临时文件/空安装包签名与验签；匹配本应用的Mac App Store provisioning profile通过App ID、Team、签名证书、有效期、调试权限及分发类型检查。私钥和临时签名夹具不在仓库中，临时文件已清理。这些检查不代表最终商店包、上传或审核通过。

签名沙盒包的只读检查已纳入仓库和 CI 的脚本回归：

```bash
python3 scripts/audit_app_store_bundle.py /path/to/ApexTerm.app --output /path/to/store-audit.json
```

校验应用与 profile 的 App ID、Team、证书绑定、有效期、macOS 商店分发类型、更新渠道、沙盒权限及 helper 继承；任一必需检查失败退出1并保留 JSON 诊断。`get-task-allow` 与 `com.apple.security.get-task-allow` 两种调试权限都会拒绝。隐私声明仅提供技术检查信息，仍需按最终 API 使用审核。15项脚本回归覆盖错误签名、失效/错误类型 profile、调试权限及缺少 bundle；用现有官网下载1.5.6包实测得到退出1，正确拒绝把官网下载包当作商店包。该工具不编译、安装或上传产品，检查通过也不能替代全量门禁与真实沙盒 UI 验收。

`python3 scripts/build_store_qa.py` 生成独立的 Debug 沙盒测试应用，用于随后在 macos27 运行真实文件选择、SSH/SFTP和菜单测试。每次使用新的 `com.apexterm.qa.store.*` 标识，已有 QA 会话目录隔离逻辑也会生效；输出写入全新目录，已有文件或符号链接会直接拒绝。应用设置商店更新渠道，携带隐私清单与继承沙盒的两个 helper，并执行私密信息扫描、架构检查和深度验签。该工具不启动或安装应用，不复制会话库/私钥，不产生安装包，不上传；ad hoc 签名与0.0.0版本仅用于开发验收，仍需对正式商店签名包独立执行全部门禁。

2026-10-02 Debug 沙盒 QA 包实际构建、私密信息扫描、arm64检查及深度验签通过，已放入macos27独立测试目录；VM侧签名校验及三个可执行文件的SHA256均与原构建一致，尚未启动UI。脚本全量51项通过，含6项QA隔离与拒绝覆盖回归。

SSH agent能力探针在macos27有效ad hoc沙盒中观察到：独立测试目录中的空agent Unix socket连接返回EPERM；给该目录传入书签后，目录文件已可读，但socket仍返回EPERM；同一应用容器内的空agent socket可连接并完成空密钥列表协议。每组测试同时确认容器home和未授权文件拒绝，测试agent及容器/目录均已清理。这仅验证上述测试路径的IPC能力，未覆盖系统launchd agent、真实密钥认证或产品UI；不能把书签文件授权当作外部agent连接授权，也不能据此宣称商店agent功能已完成。

商店签名审计进一步要求两个捆绑 helper 使用本团队的商店分发证书，并核对各自实际签名叶证书是否位于应用 profile 的许可列表。签名校验返回零仍可能是 ad hoc、开发或 Developer ID 签名，不能直接作为本项目商店包的签名门禁通过。新增回归对每个 helper 单独覆盖错误团队、非商店证书、profile 未许可证书，并允许 profile 中不同的有效分发证书；旧实现会错误接受负面夹具，新实现拒绝。当前审计19项、全量脚本55项通过。这些是签名审计的合成回归，正式包签名、VM UI 验收和上传仍未完成。

嵌套代码签名说明：https://developer.apple.com/library/archive/technotes/tn2206/

上传元数据审计要求 `NSHumanReadableCopyright` 是非空字符串；缺失、空白或错误类型均阻断技术就绪检查。版权主体应依据应用实际权利归属填写，审计不会自动填入开发者账号姓名或虚构版权。Apple 对 macOS 上传的要求见 https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution 。新增负面回归后，审计20项、全量脚本56项通过；不代表构建已经上传或通过审核。

最新真实目标验证：本分支342项 Swift用例全部通过，0跳过、0失败，包含10项macos27 VM集成及4项真实Mac服务器集成，0 Swift编译警告。测试由主机CLI发起，不包含最终沙盒包的UI验收或Linux服务器验收；该结果不能替代商店签名包的独立门禁。

商店渠道的新建及已有会话现在允许选择「指定私钥」，使文件选择器和系统书签授权入口可达。官网渠道的新建认证选项及已有指定私钥编辑保持原有行为。新增回归后，真实目标全量 Swift 用例343项全部通过，0跳过、0失败、0 Swift编译警告；其中10项VM与4项Mac服务器集成。该结果仍不包含最终沙盒产品UI。

独立的 `UITests/StoreSandboxUITests.xcodeproj` 提供3项沙盒产品UI测试：关于窗口隐私入口、真实私钥选择器取消、关闭最后窗口后重新打开。该目标与完整43项官网渠道UI目标分离，已通过Swift 6构建，尚未运行。只能在macos27中对全新 `com.apexterm.qa.store.*` 沙盒QA应用运行，并在启动前验证实际沙盒签名；测试源码也拒绝非VirtualMac和非QA/非商店渠道应用。需持有同一个VM桌面互斥锁，不能与其他UI验收重叠。这3项即使通过，也不代表SSH/SFTP、真实密钥、agent或最终商店分发包验收完成。

2026-10-02 实际 Debug 沙盒 UI 首轮验证：关于隐私入口和关闭后重开主窗口均通过；私钥用例发现测试聚焦点落在侧边栏按钮，以及表单输入框缺少明确无障碍标识。已改用标题文字区域置前、恢复实际侧边栏状态，并为私钥输入框添加标签与稳定标识。源码更新后的343项真实目标 Swift 用例通过，0失败、0跳过、0警告；更新后的完整3项沙盒UI仍需独立验证。

最新 macos27 实际 Debug 沙盒 UI 验证：3项全部通过，0失败、0跳过。关于隐私入口、关闭最后窗口后重新打开、真实NSOpenPanel取消且私钥路径不变均通过。测试按NSOpenPanel的固定标识定位，避免把按钮标题误当成AXLabel。启动前后深度验签及三个二进制SHA256一致，主程序保持App Sandbox，helper保持继承权限；仅测试Runner解除其沙盒限制。证据保留在调用聊天的 `outputs/store-sandbox-ui/20261002-101640`。仍未验证真实私钥/agent认证、SSH/SFTP全流程或最终商店签名包，也未上传/提交审核。

真实沙盒 CLI 验证发现 OpenSSH 建立复用监听时会追加 `.` 与16个随机字符；仅检查最终 socket 路径是否小于104字节会漏掉临时路径超长。现为临时后缀和NUL预留长度；容器临时路径过长时使用 `ControlPath=none`，保持正常认证与传输，不使用容器外共享 socket。这会使该路径下的命令分别建立连接。依据：[OpenSSH mux.c](https://github.com/openssh/openssh-portable/blob/master/mux.c) 和 [ControlPath 文档](https://man.openbsd.org/ssh_config.5#ControlPath)。

独立的 ad hoc 沙盒 CLI 探针随后验证：实际容器隔离、未授权文件拒绝、生产 `NativeSSHSession` 的 `.appStore` 调用链与继承权限 helper、真实 PTY 输出、Unicode 文件上传/目录查询/下载字节一致，以及远端夹具删除均通过。身份来自本次 SSH 连接转发到该独立容器内的临时 agent 代理，不复制私钥，不修改远端认证配置；代理已停止。此结果不证明系统外部 agent socket、实际私钥选择/口令、商店产品UI或最终分发签名包通过。证据在调用聊天 `outputs/release-v1.6.0/store-live-sandbox-probe-current/`。

socket修正后完整回归：345项 Swift 用例全部通过，0失败、0跳过、0 Swift编译警告，含10项实际macos27 VM和4项实际Mac服务器集成；8项优化性能基准全部通过。新增回归覆盖OpenSSH临时后缀的86/87字节边界、Unicode路径及系统SSH接受禁用复用。既有3项沙盒UI在该修正前通过，仍需对新的完整QA应用重新运行。

加密私钥的真实沙盒 CLI 验证发现 `sshpass` 的 `TIOCSCTTY` 被 App Sandbox 拒绝。商店渠道改由继承沙盒的 SSH bridge 提供 OpenSSH `SSH_ASKPASS_REQUIRE=force` 回调。口令仅在应用私有0600运行时授权请求中传递，连接或操作结束即删除，不放入启动参数、环境变量或分发资源；回调区分私钥口令和服务器密码，拒绝主机确认以及不匹配的认证提示。官网下载渠道保持原有调用链。依据：https://man.openbsd.org/ssh.1#SSH_ASKPASS 。

修复原型已在 macos27 的实际 ad hoc 沙盒中使用自行生成的加密私钥，完成真实 PTY 输出、Unicode 文件上传/目录查询/下载字节校验及夹具删除；未读取用户既有私钥或修改认证配置。新增5项回归覆盖认证请求权限和清理、非法口令、拒绝错误提示及启动参数不含口令；串行全量350项 Swift 用例通过，0失败、0跳过、0编译警告；56项脚本回归通过。首次并行运行出现1项性能阈值失败，保留失败日志，后续按原阈值串行复测通过。

独立的非交互钥匙串探针使用新建随机账号、禁止弹窗，创建返回 `errSecInteractionNotAllowed`（-25308）；没有创建凭据，也没有读取既有条目。因此加密私钥通过证据不包含真实钥匙串口令读取，且仍不是最终商店签名包、完整产品UI或上传验收。
