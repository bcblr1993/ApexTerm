# ApexTerm 内部候选 2026092716 验证报告

版本1.3.0，构建2026092716；应用源码12bbf6901d56891f25ea7c102cc5783dbd81aa19。此候选包含SFTP路径框同步与SSH窗口标题目录解析修复。后续修改仅限验收工具和文档，未改变候选产品源码。

候选构建exit0。Tart真实门禁执行148项测试，4项可选公网测试跳过，零失败；7项VM集成测试通过。8项Release基准通过，构建日志无Swift warning/error。VM结束后停止。原始证据：outputs/macos27/build-candidate-current.log。

应用和DMG公证均Accepted，票据验证通过。应用严格深度验签通过。DMG只读挂载卷标ApexTerm Candidate，包含应用与Applications链接，Info.plist版本1.3.0/2026092716；tar包内构建号一致。两份分发包SHA256独立核对一致。证据：candidate/package-2716-inspection.json、notarization.json、notarization-dmg.json、SHA256SUMS.txt。

指定实体机192.168.50.226独立临时目录接收tar，远端哈希一致、版本正确、严格深度验签通过。该机器Gatekeeper启用并接受Notarized Developer ID。未覆盖用户已安装应用，未验证远端GUI启动。证据：candidate/physical-226-2716-proof.json与verification.log。

本机正常候选窗口：中文搜索空状态及清空恢复、空会话表单保存禁用、Escape取消且会话数保持3、更新检查返回当前1.3.0已最新、Return关闭更新sheet均通过。关闭模态后CmdQ，进程消失。证据：candidate/gui-2716-basic-proof.json、update-flow-2716.json与对应AX记录。

实体机30分钟混合SSH/SFTP验收使用011f5ad产品源码，与候选中产品修复一致：114次输入、38次任务completed且字节一致的双向传输、零失败，等待断开后正常exit0。RSS峰值221.64MB含QA采样开销，不作为产品独立内存曲线证明。证据：soak/real-226-current-result.json、real-226-current-memory-final.json。

尚未完成：最终候选远端/VM实际GUI完整流程、双向拖拽、IME、选区完整性、全部主题/窗口/页面状态及系统无障碍、可归属应用的实际绘制帧P95及同条件基线、独立内存趋势。更新加载与失败界面已有受控工具证据，真实网络失败未验证。CI尚未证明覆盖当前本地源码。整体目标保持未完成，详见macos27-remaining-acceptance.md；此报告不授权正式发布、打tag或合并。
