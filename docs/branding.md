# AetherTerm 命名与兼容

产品展示统一为 AetherTerm，副标题为「原生 SSH 终端与 SFTP 工作台」，所属品牌为 Aether Native。

菜单、关于页、备份导出建议名、官网入口与正式 DMG 使用新名称。源码仓库仍为 bcblr1993/ApexTerm，Swift 模块和可执行文件名保留，以避免扩大工程迁移范围。

升级保持 com.apexterm.app、Application Support/ApexTerm、com.apexterm.ssh.credentials、窗口恢复键和主题存储原值不变。候选和 QA 目录仍隔离，避免误读正式会话。新更新器同时接受两种 app 目录名。

历史更新器优先下载 tar.gz 并固定查找 ApexTerm.app，因此正式 tar.gz 内部保留该目录名（显示名仍为 AetherTerm）；DMG 使用 AetherTerm.app。旧版原位升级会保留用户原有安装目录名；新安装采用新名称。这一兼容布局在正式发版前必须用实际旧版本验证。

官网迁移至 /apps/aetherterm/，中文与英文旧路径及其文档、历史版本和 JSON 接口全部 301 重定向。历史 Release 地址保持可用，旧官网同步通知的 apexterm id 映射到 aetherterm。

官网主题预览来自独立 QA 应用的真实 SwiftUI/AppKit 界面，使用合成会话和演示输出，默认在 Tart macos27 捕获；经用户明确授权，也可通过采集脚本的 `--host` 参数在运行 macOS 27 的远程 Mac 上采集。远程桌面需已登录，并授予采集应用所需的屏幕录制权限。应用主题预览独立于网站浅色/深色外观。
