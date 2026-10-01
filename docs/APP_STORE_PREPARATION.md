# App Store 构建准备

本分支用于独立开发商店分发能力，不能把这里的局部测试结果当作正式商店包验收。

商店包的 `Info.plist` 必须设置 `ApexDistributionChannel=appStore`。该渠道的启动过程不会请求 GitHub 更新，设置及菜单的更新入口打开 App Store；更新管理器也会阻止显式官网包下载和已暂存应用替换。普通分发默认仍为 `direct`。

`Resources/AppStore/ApexTerm.entitlements` 是主程序的基础沙盒权限；独立 SSH helper 使用 `SSHHelper.entitlements` 继承主程序沙盒。商店签名时，应用标识、Team 与钥匙串 access group 必须按匹配且有效的 provisioning profile 写入，不能用权限模板冒充签名身份或有效 profile。

`Resources/AppStore/PrivacyInfo.xcprivacy` 声明实际使用的应用自有 UserDefaults，尚需按最终 Mach-O 与 helper 审核其他 API。隐私声明不等于隐私问卷已填写或后台已经接受构建。

已接入持久文件书签：私钥浏览与下载目录选择保存用户授权，目录或私钥移动时解析到新路径；SSH/SCP 操作及传输队列保持授权直到完成或取消。单文件和批量下载使用设置里的目录，商店渠道首次缺少目录授权时要求用户选择目录。书签存储和队列生命周期已有单元测试，这些测试在非沙盒进程中运行，不能替代真实沙盒包的验证。

Apple 的 App Sandbox inheritance 文档明确子进程只继承静态权限；对启动后选择的文件需传递数据或书签。商店调用链现在将普通跨进程书签写入应用私有临时目录中的0600授权请求，不复制私钥正文；`ApexSSHBridge` 在同一进程内解析书签后 `exec` 系统 SSH/SCP。SCP 的 `-S` 指向同一个 helper，让内部 SSH 子进程重新解析授权。请求文件保持到进程结束或取消后删除；PTY 请求保持到连接终止。缺少 helper 或授权请求时拒绝执行，不回退为裸路径调用。

普通官网下载包没有使用这个组件，商店包必须另行捆绑并用 `SSHHelper.entitlements` 签名 `ApexSSHBridge` 及 sshpass。当前普通 CLI 测试验证了协议、请求权限/拒绝符号链接、实际 helper exec 和内部 SSH 入口；它们仍不证明 App Sandbox 下动态权限跨 exec 及真实 SFTP 成功，需最终 VM 签名包验证。跳板 SSH 的独立私钥/口令和 SSH agent 也需要补齐沙盒验收。

本阶段全量 `swift test`：316项、0 failures、14个未配置远程环境的集成测试skip，编译0 warning/error。另有7项新增私钥/传输租约生命周期回归通过。跳过的集成测试及非沙盒单元测试不能当作正式发布质量门禁全通过。

仍需完成 SSH 配置/known_hosts 与控制 socket 的沙盒路径处理、商店专用打包与签名、最终沙盒包在 Tart `macos27` 中的完整 UI/SSH/SFTP 验收，以及上传后的 App Store Connect 检查。正式发布仍需遵守主干、全量测试、签名与安全扫描门禁。

官方资料：

- https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest

子进程权限依据：https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html#//apple_ref/doc/uid/TP40011195-CH3-SW11

当前跨进程书签文档：https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox

书签传递 helper 阶段最终验证：`swift test` 335项、0 failures、14项未配置远程环境的skip，0编译warning/error；授权/进程边界专项35/35通过。helper临时请求使用`O_CREAT|O_EXCL`与0600权限，防止覆盖已有文件；读取拒绝符号链接、其他用户可读文件、未知协议及超大内容。路径修正只针对SSH本地文件选项及SCP本地文件操作数，远端命令保持原样。测试均不是签名沙盒验收。
