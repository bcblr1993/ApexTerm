# 真实系统拼音的物理按键验收

完整 UI 门禁仍由 Tart `macos27` 中的 XCTest 驱动。拼音用例等待远端 `read` 就绪，并从隔离 QA 应用读取实际输入上下文与预编辑状态；不能仅凭测试进程缓存的输入源 ID 判定就绪。

验收配置必须设置 `APEX_UI_TEST_VM=macos27`；`APEX_UI_RUNNER_HOST` 留空，由 Tart 获取当前地址。`APEX_UI_TEST_HOST` 和 `APEX_UI_TEST_USER` 指定被测 SSH 服务器，不是 UI Runner。完整门禁和直接调用远端 Runner 都会在远程操作前拒绝缺失或其他 VM 名称；Runner 还会验证地址与 `VirtualMac` 机型，配置不符时停止，不能回退到宿主桌面。`--preflight-only` 只检查配置，不代表 XCTest 已获准或 UI 用例通过。

正式打包必须执行完整 UI 门禁。`APEX_UI_ACCEPTANCE_PREFLIGHT_ONLY=1` 会在打包、清理和编译开始前被拒绝，不能把配置预检作为发布验收。

本轮记录过 XCTest 单独合成按键时，预编辑串在 Escape 到达应用前先提交的失败。为独立验证真实系统事件，`PhysicalKeyPoster.swift` 使用固定物理键码输入 `zhongwen`、Escape、Space 和 Return。测试继续要求预编辑不进入 SSH、Escape 不发送预编辑或控制码、最终远端回显 `中文`，并保留候选截图与发送字节计数。

工具由 `scripts/build_ui_key_fixture.sh` 编译并使用现有 Developer ID 签名。远端 Runner 验证签名标识与团队，把工具安装到测试 VM 的 `~/.apexterm-ui-tools/PhysicalKeyQA.app`，随后执行权限预检。源码与产物只属于 UI 测试目录，不进入 ApexTerm 发布包。

安全范围：工具拒绝非 `VirtualMac` 环境；只有当前测试指定的唯一 QA bundle ID 位于前台时才发送固定按键。它不接受任意文本、任意键码或生产应用目标。安装过程拒绝符号链接、其他应用或签名不符的已有目录。

首次使用需要在测试 VM 的系统设置 → 隐私与安全性 → 辅助功能，为 `ApexTerm Physical Key QA` 授权。权限缺失时门禁立即停止；不修改 TCC 数据库，也不退回模拟拼音或跳过测试。稳定的 Developer ID 要求允许后续构建复用同一工具身份。

macos27 实测：直接经 SSH 执行工具时，TCC 的负责进程是 `sshd-keygen-wrapper`，即使工具已经获准也会被拒绝。因此预检和 XCTest 都通过 Launch Services 后台启动已签名的工具，保留终端前台和输入上下文。`open` 返回零不能证明子应用成功；每次启动使用独立临时输出，并要求工具在完成预检或全部按键后写出对应成功标记。拒绝权限、缺失输出和启动失败仍会熔断门禁。
