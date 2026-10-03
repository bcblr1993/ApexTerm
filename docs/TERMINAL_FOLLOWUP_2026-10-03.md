# 2026-10-03 终端交互与刷新修复

## 改动

- 组合键编码按 Shift、Option、Control 的完整组合生成 xterm 参数，覆盖方向键、Home、End、Delete、PageUp、PageDown 和 F1…F12。未修复代码在新增三项回归中产生 170 个失败断言，修复后通过。编码依据：[XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)。
- Vim 等备用屏幕中的 Option＋左右键发送编辑器的 Alt 方向键序列，避免被解释为 Escape 后的 shell 按词移动命令。普通 shell 的 Option＋左右键及 Option 删除快捷键保留原行为。
- 备用屏幕缓存未变化行的富文本，局部变化仅重建相应行；主题、字体、关键词规则、行数和会话变化使缓存失效。回归检查选区、颜色、TrueColor、缩小视口和重新进入备用屏幕。
- VM 传输包为重启测试应用固定工作目录内路径，支持位于其他目录甚至仓库外的报告。新增测试实际打包并解包外部目录的应用，再核对内容。

## 性能测量

同一台开发机、Debug 构建、40 行 × 120 列彩色备用屏幕，XCTest 每次测量执行 100 次光标移动及刷新，10 次测量取平均：

| 实现 | 平均耗时 | 相对标准差 |
| --- | ---: | ---: |
| 修复前 | 0.612 秒 | 17.3% |
| 复用未变化行后 | 0.168 秒 | 22.3% |

这组测量耗时减少约 72.5%，只包含缓冲与 AppKit 视图刷新调用，不代表网络延迟、屏幕呈现帧率或长期功耗。原始报告为 `outputs/terminal-ui-followup-render-before.log` 与 `outputs/terminal-ui-followup-render-after.log`（开发工作区的独立诊断输出）。

最终代码全量复测再次测得平均 0.175 秒，相对标准差 27.3%；测量存在明显的环境抖动。

## 已验证

- 终端专项：45 项通过，随后补充了备用屏幕主题切换与 Option 退格行为回归。
- 脚本：74 项通过，包含自定义报告目录应用传输的真实归档往返。
- 最终代码的全量 Swift 测试：291 项 ApexSSHTests + 66 项 ApexCoreTests，共 357 项通过，0 失败、0 跳过；包含 10 项 VM 集成及 4 项真实服务器测试。
- 10 项 VM 集成覆盖真实 SSH PTY、Vim 编辑、保存与多次尺寸回传，SFTP 字节校验、特殊文件名、监控和进程清理。
- 最终 Release 测试二进制在 Tart `macos27` 执行 8 项优化基准，0 失败，全部发布阈值通过；传输前后的 SHA-256 一致，机型验证为 VirtualMac。Swift 编译无警告。

| 基准指标 | macos27 实测 |
| --- | ---: |
| RingBuffer | 1,779,615 行/秒、179.90 MB/秒 |
| ANSI | 379,889 spans/秒 |
| 峰值 RSS | 104.44 MB |
| 并发写入 | 1,642,038 writes/秒 |
| 监控解析 | 13,653 次/秒 |
| SSH 主机解析 | 133,546 hosts/秒 |
| SFTP 调度 | 952 tasks/秒 |
| Mock 输入链路 | 7.81 微秒/键 |

第八项只测 Mock 会话内部输入路径。证据：`outputs/terminal-ui-followup-current-code-gate.log`、`outputs/terminal-ui-followup-vm-benchmark/benchmarks.log`、`outputs/terminal-ui-followup-vm-benchmark/thresholds.txt`、`outputs/terminal-ui-followup-vm-benchmark/run.json`、`outputs/terminal-ui-followup-script-tests-final.log`。

零跳过复测中有一次因长历史刷新和 ANSI 解析墙钟时间超限而失败；当时开发机负载读数为 732，两个用例随后保持原阈值单独通过，全量复测也通过。失败日志保留为 `outputs/terminal-ui-followup-final-swift-under-load.log`，不能用单项补跑覆盖失败记录或宣称没有出现过超时。

开发机的最终 `test_vm_acceptance.sh` 在全部 357 项功能测试通过后，因 4 项性能阈值未达标而退出 1，不能记为该入口完整通过：监控解析 3,013 次/秒、SSH 主机解析 68,555 hosts/秒、SFTP 调度 694 tasks/秒、Mock 输入 15.86 微秒。随后同一二进制在 VM 中全数达标，支持环境负载影响测量的判断；未降低门槛，也未修改发布入口以绕开失败。

## 尚未完成的 UI 验收

完整 UI 仍必须在 Tart `macos27` 执行。本轮自定义报告目录错误已解决，后续运行 `outputs/terminal-ui-followup/fixed/20261003-204302-14407/UI.xcresult` 因系统“Enable UI Automation”验证未完成而启动超时，运行器报告 `Timed out while enabling automation mode.`，43 项产品 UI 用例尚未执行。

已通过测试不能替代完整 UI 验收。上一轮主题菜单有限坐标断言与 XCTest 失败处理停滞，以及真实系统拼音、Finder 双向拖拽和窗口截图矩阵，仍待完成系统验证后复测。

## 清理

本轮两次失败 UI 运行及独立性能运行的确切 VM 工作目录均已验证无相关进程或工作目录引用后删除；共享的物理按键工具保留。本地对应的传输归档、临时应用、编译辅助程序和一次性目标配置已清理，日志、源码快照、xcresult 及诊断报告保留。清理只覆盖这三次运行有所有权记录的残留。

改动位于 `bcblr/fix-terminal-ui-followup`，更新日志记为 Unreleased。本报告不改变已提交 Apple 审核的构建及此前发布结论。
