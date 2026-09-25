# ApexTerm macOS - Engineering, Verification & Release Standards (SOP)

本文档参考并对齐行业顶级开源项目（AetherRoute）工程规范，定义 ApexTerm 项目从日常开发、代码提交、自动化测试、质量门禁到正式签发构建的全生命周期标准作业程序（SOP）。AI 助手及所有参与开发者**必须无条件严格遵守**。

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
# 必须 100% 通过（0 failures）
swift test
```

### 质量验收标准：
1. **单元与功能测试**：80+ 自动化测试用例全部绿色（涵盖 Core 核心、SSH 协议、Terminal 终端引擎、UI 状态与 ProductFeature）；
2. **8 大性能基准测试（Benchmarks）**：
   - [Benchmark 1] RingBuffer 写入吞吐：≥ 50,000 行/秒 (≥ 5.0 MB/秒)
   - [Benchmark 2] ANSI / TrueColor 颜色解析速度：≥ 150,000 spans/秒
   - [Benchmark 3] 内存水位与驻留集（RSS）：峰值 ≤ 250 MB，熔断截断正常
   - [Benchmark 4] 16 线程高并发争用写入吞吐：≥ 1,000,000 writes/秒
   - [Benchmark 5] 64 核 Linux 无代理系统指标解析速度：≥ 8,000 次/秒
   - [Benchmark 6] OpenSSH 500 主机批量解析吞吐：≥ 80,000 hosts/秒
   - [Benchmark 7] SFTP 任务中心 100 任务并发调度性能：≥ 800 tasks/秒
   - [Benchmark 8] 终端物理按键直通与全链路键入延迟：≤ 15.0 微秒 (μs)
3. **编译器状态**：Swift 6 模式下零警告（Zero Warnings）。

---

## 🔏 五、构建、Apple 签名与安全公证规范 (Code Signing Standards)

1. **架构原生针对性**：
   - 面向 Apple Silicon (arm64) 架构独立编译生产级可执行文件，开启完整编译器优化（`-O`）。
2. **Hardened Runtime 与 Developer ID 官方签名**：
   - 签名证书必须为官方证书：`Developer ID Application: YanNan Chen (5984KQD4D7)`；
   - 必须为所有附带独立工具（如 `sshpass`）及主应用执行完整的深层递归签名；
   - 签名校验断言：
     ```bash
     codesign --verify --deep --strict --verbose=2 /path/to/ApexTerm.app
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
7. 打带注释的 Git Tag：`git tag -a "v<VERSION>" -m "Release v<VERSION>"`。
