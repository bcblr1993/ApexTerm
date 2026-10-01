# App Store 构建准备

本分支用于独立开发商店分发能力，不能把这里的局部测试结果当作正式商店包验收。

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
