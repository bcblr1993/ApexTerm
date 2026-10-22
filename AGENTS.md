# AetherTerm macOS - Engineering, Verification & Release Standards (SOP)

本文档参考并对齐行业顶级开源项目（AetherRoute）工程规范，定义 AetherTerm 项目从日常开发、代码提交、自动化测试、质量门禁到正式签发构建的全生命周期标准作业程序（SOP）。AI 助手及所有参与开发者**必须无条件严格遵守**。

---

## 🛡️ 一、安全与零捆绑红线 (Zero-Bundle & Security Standards)

1. **严禁打包任何私有配置、服务器信息与凭证**：
   - 最终的分发安装包（`.app`、`.dmg`、`.tar.gz`）中**绝对严禁**包含任何开发者的私有服务器 IP、端口、登录用户名、密码、SSH 私钥（`id_rsa`, `*.pem`, `*.key`）以及本地测试会话库（`sessions*.json`）。
   - 代码库必须通过 `.gitignore` 彻底阻断任何含有真实凭据与网络端点的敏感文件。
2. **发布前静态安全扫描门禁**：
   - 发布打包流水线必须包含安全检查脚本，自动扫描 `Contents/MacOS` 与 `Contents/Resources`，确保 Mach-O 二进制与资源目录无任何私钥或敏感明文泄漏。

---

## 🌿 二、分支开发与 Git 提交规范 (Conventional Commits)

1. **分支基线与工作流**：
   - 功能开发与复杂重构在专门分支（如 `feature/*` 或 `fix/*`）进行；
   - 严禁在存在未追踪脏工作区（dirty working tree）或测试未通过的状态下执行正式构建与 Tag 打标；
   - 正式发布与 Tag 必须基于主干（`master` / `main`）生成。
2. **Conventional Commits 提交格式**：
   所有 Git 提交信息必须遵循语义化提交标准，格式为 `<type>(<scope>): <description>`：
   - `feat:` 新增功能（如 `feat(settings): 新增终端配色与字体选择面板`）
   - `fix:` 修复缺陷（如 `fix(terminal): 修复方向键行内移动光标错位问题`）
   - `test:` 新增或调整自动化测试用例（如 `test(product): 新增 AppSettings 与 SemVer 单元测试`）
   - `perf:` 性能与算法优化（如 `perf(buffer): 提升 ANSI 颜色解析吞吐至 200k spans/s`）
   - `refactor:` 代码重构（不改变外部功能）
   - `docs:` 文档与说明变更
   - `chore(release):` 版本发布、构建配置或依赖维护

---

## 📋 三、版本号与构建号规范 (Versioning & Build Numbers)

1. **语义化版本（Semantic Versioning）**：
   - 格式：`vMAJOR.MINOR.PATCH`（例如 `v1.2.0`）。
   - `PATCH`：纯 Bug 修复与小幅细节微调；
   - `MINOR`：新增产品特性、功能增强且向下兼容；
   - `MAJOR`：破坏性架构升级或底层协议重大重构。
2. **构建号（Build Number）**：
   - 格式：`YYYYMMDDNN`（例如 `2026092501` 表示 2026年9月25日第 1 次构建）。
   - 构建号必须全局单调递增，供 macOS 系统及内部更新管理器准确判定构建序列。
3. **版本号全局原子对齐**：
   每次发布前，必须确保以下三处版本信息严格一致：
   - `Info.plist`（`CFBundleShortVersionString` 与 `CFBundleVersion`）
   - `CHANGELOG.md` 顶端版本标题与发布日期
   - Git Tag（带注释的 Tag，如 `git tag -a v1.2.0 -m "Release v1.2.0"`）

---

## 🧪 四、全量自动化测试与质量门禁 (Pre-Release Quality Gates)

在执行任何发布构建（Release Build）前，**必须无条件通过全部自动化测试门禁**，任何单一测试失败立即熔断，严禁带病发布：

```bash
# 执行 Tart 虚拟机验收门禁与全量测试
./scripts/test_vm_acceptance.sh

# 必须 100% 通过（0 failures）
swift test
```

### 质量验收标准：
1. **Tart VM 虚拟机验收与集成测试**：
   - 每次发布版本前，通过 `./scripts/test_vm_acceptance.sh` 执行针对 Tart 虚拟机的真实链路与本地全量门禁；
   - 虚拟机集成测试覆盖真实 PTY 交互、SFTP 双向传输完整性、Linux Agentless 系统监控采集；
2. **单元与功能测试**：90+ 自动化测试用例全部绿色（涵盖 Core 核心、SSH 协议、Terminal 终端引擎、UI 状态、分屏与 ProductFeature）；
3. **8 大性能基准测试（Benchmarks）**：
   - [Benchmark 1] RingBuffer 写入吞吐：≥ 50,000 行/秒 (≥ 5.0 MB/秒)
   - [Benchmark 2] ANSI / TrueColor 颜色解析速度：≥ 150,000 spans/秒
   - [Benchmark 3] 内存水位与驻留集（RSS）：峰值 ≤ 250 MB，熔断截断正常
   - [Benchmark 4] 16 线程高并发争用写入吞吐：≥ 1,000,000 writes/秒
   - [Benchmark 5] 64 核 Linux 无代理系统指标解析速度：≥ 8,000 次/秒
   - [Benchmark 6] OpenSSH 500 主机批量解析吞吐：≥ 80,000 hosts/秒
   - [Benchmark 7] SFTP 任务中心 100 任务并发调度性能：≥ 800 tasks/秒
   - [Benchmark 8] 终端物理按键直通与全链路键入延迟：≤ 15.0 微秒 (μs)
4. **编译器状态**：Swift 6 模式下零警告（Zero Warnings）。
5. **在线更新与版本发布闭环门禁 (RG-07: Online Update Gate - 每版必测)**：
   - 每次发布打标并创建 GitHub Release 后，**必须无条件运行 `./scripts/verify_online_update.py <VERSION>` 验收在线更新链路**；
   - 必须通过 5 项端到端在线更新检查：
     1. GitHub Releases API (`https://api.github.com/repos/bcblr1993/ApexTerm/releases/latest`) 准确返回目标版本标签；
     2. Release Assets 完整性（DMG、tar.gz 与 SHA256SUMS.txt 齐全且体积正常）；
     3. 下载链接连通性（DMG 与 tar.gz 返回 HTTP 200/302，严禁 404）；
     4. 模拟客户端解压校验（解压后应用包存在、Bundle ID 为 `com.apexterm.app`、版本一致、主程序 Mach-O 具备可执行权限）；
     5. 远端 SHA256SUMS.txt 与本地构建清单逐字节对齐。
   - 任何一项校验失败立即熔断排查，严禁发布不可在线更新的死版本。
6. **窗口分屏磁吸与 UI 对齐规范门禁 (RG-08: Window Tiling & UI Alignment Gate - 每版必测)**：
   - 每次发布新版本前，**必须无条件通过 `TitlebarZoomAndUIRegressionTests`（含 TC-WIN-01 ~ TC-WIN-08）**；
   - 重点断言：
     1. 拖拽到屏幕边缘自动分屏/磁吸尺寸约束：`minWidth <= 640`, `minHeight <= 440`，保证各机型（1280x800, 1440x900 等）50/50 均匀对半均分，严禁因硬编码尺寸造成分屏占比失衡；
     2. 全局 UI 统一网格体系规范（`ApexStyle.s4 = 16pt` 基准线与无错位）；
     3. 顶部工作区操作按钮区（复制/分屏/指标/文件）右侧吸附与标题栏空白双击缩放。
   - 任何单项未通过立即熔断打包流水线。
7. **核心功能与扩展能力门禁 (RG-09: Core Capabilities & Extensions Gate - 每版必测)**：
   - 每次发布新版本前，**必须无条件通过核心扩展用例集（含 24 项自动化测试）**：
     1. `SSHTunnelTests`（含 TC-TUN-01 ~ TC-TUN-08）：覆盖 Local/Remote/Dynamic SOCKS5 端口转发配置合法性、OpenSSH `-L`/`-R`/`-D` 参数构建、端口冲突防范、自动启动与生命周期持久化；
     2. `QuickCommandBarTests`（含 TC-CMD-01 ~ TC-CMD-08）：覆盖常用运维命令预设、分类动态过滤、`{{var}}` 占位符提取与动态插值、`{{date}}` 解析与安全换行发送；
     3. `CommandPaletteTests`（含 TC-PAL-01 ~ TC-PAL-08）：覆盖全局 Spotlight 调色板搜索（`⌘P` / `⌘K`）、前缀路由（`>` 功能 / `@` 主机 / `/` 路径 / `#` 命令）、模糊匹配与权重排序、快捷键分发。
   - 任何单项未通过立即熔断打包流水线。
8. **运维深度监控与安全审计门禁 (RG-10: Process Inspector, SSH Key Vault & Session Audit Logging Gate - 每版必测)**：
   - 每次发布新版本前，**必须无条件通过深度运维用例集（含 24 项新增自动化测试）**：
     1. `ProcessInspectorTests`（含 TC-PROC-01 ~ TC-PROC-08）：覆盖 Top 45 进程指标解析、内存 KiB/MiB 换算、核心关键进程保护判定（PID 1、systemd、init、sshd、当前 Shell 自身防自杀）、进程信号分发（SIGTERM 15、SIGKILL 9、SIGHUP 1）、systemd 服务状态解析；
     2. `SSHKeyVaultTests`（含 TC-KEY-01 ~ TC-KEY-08）：覆盖集中式 Ed25519/RSA/ECDSA 密钥保险库、SHA256 公钥指纹计算、Keychain 隔离存储私钥与口令、一键免密部署脚本（umask 077/chmod 700/600）生成与防重复导入；
     3. `SessionAuditLoggingTests`（含 TC-LOG-01 ~ TC-LOG-08）：覆盖异步全量 PTY 流录制、ANSI 转义序列与控制符过滤、50MB 日志自动切割轮转、上一条执行命令输出精准提取（`⌘⌥C`）与边缘提示符识别。
   - 任何单项未通过立即熔断打包流水线。
9. **iCloud 云端多设备同步与容灾门禁 (RG-11: iCloud Multi-Device Sync & Cloud Vault Gate - 每版必测)**：
   - 每次发布新版本前，**必须无条件通过 `iCloudSyncTests`（含 TC-ICLOUD-01 ~ TC-ICLOUD-08）**：
     1. `TC-ICLOUD-01`：会话、命令片段、触发器、SFTP 书签与 SSH 隧道全量 Payload 序列化与 ISO8601 Roundtrip 校验；
     2. `TC-ICLOUD-02`：安全红线校验，断言绝无明文密码与私钥 PEM 泄露至云端（严格基于钥匙串引用隔离）；
     3. `TC-ICLOUD-03`：首次初始化云端上传链路；
     4. `TC-ICLOUD-04`：跨设备（Mac A 与 Mac B）智能双向无损合并（Smart Merge）；
     5. `TC-ICLOUD-05`：本地覆盖云端（Force Upload）策略生效校验；
     6. `TC-ICLOUD-06`：云端覆盖本地（Force Download）策略生效校验；
     7. `TC-ICLOUD-07`：云端损坏文件容灾防御与原子备份（`cloud_vault.backup.json`）回滚断言；
     8. `TC-ICLOUD-08`：同步状态流转（idle -> syncing -> success/error）与响应式反馈。
   - 任何单项未通过立即熔断打包流水线。
10. **OpenSSH 证书文件认证与自动发现门禁 (RG-12: SSH Certificate Authentication Gate - 每版必测)**：
   - 每次发布新版本前，**必须无条件通过 `SSHCertificateAuthenticationTests`（含 TC-CERT-01 ~ TC-CERT-08）**：
     1. `TC-CERT-01`：证书认证会话模型序列化、JSON Roundtrip 编码解码与字段访问器校验；
     2. `TC-CERT-02`：OpenSSH 命令行 `-i <keyPath>` 与 `-o CertificateFile=<certPath>` 认证参数构建；
     3. `TC-CERT-03`：OpenSSH 配置文件 `~/.ssh/config` 中 `CertificateFile` 指令解析与会话转换；
     4. `TC-CERT-04`：SSH 隧道（Local/Remote/Dynamic SOCKS5）带证书认证的进程构建验证；
     5. `TC-CERT-05`：iCloud 云端同步零捆绑与脱敏校验（私钥 PEM 阻断脱敏，证书路径与凭证引用保全）；
     6. `TC-CERT-06`：证书文件智能就近自动发现算法（`<key>-cert.pub` 自动绑定与回退）；
     7. `TC-CERT-07`：OpenSSH 证书格式解析与类型元数据断言（Ed25519/RSA/ECDSA 证书识别与普通公钥防误认）；
     8. `TC-CERT-08`：旧版本历史无证书会话的向下无缝兼容。
   - 任何单项未通过立即熔断打包流水线。

---

## 🔏 五、构建、Apple 签名与安全公证规范 (Code Signing Standards)

1. **架构原生针对性**：
   - 面向 Apple Silicon (arm64) 架构独立编译生产级可执行文件，开启完整编译器优化（`-O`）。
2. **Hardened Runtime 与 Developer ID 官方签名**：
   - 签名证书必须为官方证书：`Developer ID Application: YanNan Chen (5984KQD4D7)`；
   - 必须为所有附带独立工具（如 `sshpass`）及主应用执行完整的深层递归签名；
   - 签名校验断言：
     ```bash
     codesign --verify --deep --strict --verbose=2 /path/to/AetherTerm.app
     ```
     必须输出 `valid on disk` 且 `satisfies its Designated Requirement`。
3. **安全分发校验**：
   - 每次打包必须同时产出 `.dmg` 磁盘镜像、`.tar.gz` 独立包以及 `SHA256SUMS.txt` 校验清单。

---

## 📝 六、CHANGELOG 维护规范 (Standard Release Notes)

每次发布必须在 `CHANGELOG.md` 顶端依序记录更新条目，并统一采用以下分类结构：
- **✨ 新增特性 (Features)**：具体功能技术说明与用户获益；
- **⚡️ 体验优化 (Improvements)**：UI/UX 微调、性能提升与交互改进；
- **🐞 问题修复 (Bug Fixes)**：具体异常现象、排查根因与底层修复方案；
- **🧪 质量门禁与性能对比 (Verification & Benchmarks)**：测试用例数量、通过率与 Benchmark 实测数据。

---

## 🔄 七、标准发布流水线执行清单 (Release Execution Checklist)

每次准备发布新版本时，AI 助手严格按以下顺序自动化执行：

1. `git status` 确认工作区干净，无未暂存残留；
2. 运行 `swift test` 确保 100% 通过测试门禁；
3. 更新 `CHANGELOG.md`，添加当前版本的完整更新日志；
4. 运行发布打包脚本：`./scripts/build_app.sh <VERSION> <BUILD>`；
5. 脚本自动完成：清理缓存 -> 测试门禁 -> Release 编译 -> 捆绑与 Info.plist 对齐 -> Developer ID 签名 -> 深度验签 -> 产出 DMG 与 SHA256SUMS -> 本地安装验证；
6. 提交 Git 变更：`git commit -m "chore(release): 发布 v<VERSION> 正式版"`；
7. 打带注释的 Git Tag：`git tag -a "v<VERSION>" -m "Release v<VERSION>"`；
8. **推送主干与 Tag 至 GitHub**：
   ```bash
   git push origin master && git push origin "v<VERSION>"
   ```
9. **创建 GitHub Release 并上传分发资产**：
   ```bash
   gh release create "v<VERSION>" \
     .build/AetherTerm-v<VERSION>-macos-arm64.dmg \
     .build/AetherTerm-v<VERSION>-macos-arm64.tar.gz \
     .build/SHA256SUMS.txt \
     --title "AetherTerm v<VERSION>" \
     --notes "..."
   ```
10. **在线更新全链路闭环验收门禁（每版必测）**：
    ```bash
    python3 scripts/verify_online_update.py <VERSION>
    ```
    断言 GitHub API 返回、分发包下载连通性、更新包解压验证、Bundle 规范及 SHA-256 清单 100% 绿色通过；
11. **官方网站同步核验**：
    确认官方网站触发同步并部署上线，核验 `releases.yaml` 与官网下载链接。

## 产品名称兼容

产品展示名为 AetherTerm，官网 id 为 aetherterm。源码仓库、Swift 模块、主可执行文件、Bundle ID、会话目录和钥匙串标识保留历史兼容值，详见 docs/branding.md。正式 DMG 使用 AetherTerm.app；tar 更新包保留旧更新器要求的 ApexTerm.app 内部目录。
