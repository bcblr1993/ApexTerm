# App Store 构建准备

本分支用于独立开发商店分发能力，不能把这里的局部测试结果当作正式商店包验收。

商店包的 `Info.plist` 必须设置 `ApexDistributionChannel=appStore`。该渠道的启动过程不会请求 GitHub 更新，设置及菜单的更新入口打开 App Store；更新管理器也会阻止显式官网包下载和已暂存应用替换。普通分发默认仍为 `direct`。

`Resources/AppStore/ApexTerm.entitlements` 是主程序的基础沙盒权限；独立 SSH helper 使用 `SSHHelper.entitlements` 继承主程序沙盒。商店签名时，应用标识、Team 与钥匙串 access group 必须按匹配且有效的 provisioning profile 写入，不能用权限模板冒充签名身份或有效 profile。

`Resources/AppStore/PrivacyInfo.xcprivacy` 声明实际使用的应用自有 UserDefaults，尚需按最终 Mach-O 与 helper 审核其他 API。隐私声明不等于隐私问卷已填写或后台已经接受构建。

仍需完成持久文件授权及 CLI 子进程中的授权生命周期、商店专用打包与签名、最终沙盒包在 Tart `macos27` 中的完整 UI/SSH/SFTP 验收，以及上传后的 App Store Connect 检查。正式发布仍需遵守主干、全量测试、签名与安全扫描门禁。

官方资料：

- https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest
