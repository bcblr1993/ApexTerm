import SwiftUI
import ApexCore

/// Keyboard Shortcuts Cheat Sheet modal
public struct ShortcutsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    
    public init() {}
    
    private struct ShortcutItem: Identifiable {
        let id = UUID()
        let keys: [String]
        let description: String
    }
    
    private struct ShortcutGroup: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let items: [ShortcutItem]
    }
    
    private let groups: [ShortcutGroup] = [
        ShortcutGroup(
            title: "会话与标签管理",
            icon: "macwindow.on.rectangle",
            items: [
                ShortcutItem(keys: ["⌘", "T"], description: "复制当前会话 / 新建标签页"),
                ShortcutItem(keys: ["⌘", "⇧", "T"], description: "复制当前活动会话到新标签页"),
                ShortcutItem(keys: ["⌘", "W"], description: "关闭当前终端标签或当前活动分屏"),
                ShortcutItem(keys: ["⌘", "1...9"], description: "快速切换至指定编号的标签页"),
                ShortcutItem(keys: ["标签右键"], description: "复制会话、分屏、关闭其他/右侧标签")
            ]
        ),
        ShortcutGroup(
            title: "终端多分屏 (Split Panes)",
            icon: "rectangle.split.2x1",
            items: [
                ShortcutItem(keys: ["⌘", "D"], description: "垂直分屏 (左右并排)"),
                ShortcutItem(keys: ["⌘", "⇧", "D"], description: "水平分屏 (上下并列)")
            ]
        ),
        ShortcutGroup(
            title: "终端流与按键操作",
            icon: "terminal",
            items: [
                ShortcutItem(keys: ["⌘", "K"], description: "彻底清屏并重置回滚历史"),
                ShortcutItem(keys: ["⌃", "C"], description: "发送中断信号 (SIGINT)"),
                ShortcutItem(keys: ["⌃", "D"], description: "发送 EOF / 登出当前 Shell"),
                ShortcutItem(keys: ["⌃", "Z"], description: "挂起后台任务 (SIGTSTP)"),
                ShortcutItem(keys: ["⌃", "L"], description: "清空终端屏幕"),
                ShortcutItem(keys: ["⌘", "C"], description: "复制选中文本"),
                ShortcutItem(keys: ["⌘", "V"], description: "粘贴剪切板内容")
            ]
        ),
        ShortcutGroup(
            title: "鼠标高效交互 (PuTTY / Xshell 风格)",
            icon: "cursorarrow.rays",
            items: [
                ShortcutItem(keys: ["鼠标划选"], description: "自动复制到系统剪切板"),
                ShortcutItem(keys: ["鼠标右键"], description: "直接粘贴系统剪切板内容"),
                ShortcutItem(keys: ["⇧ + 右键"], description: "弹出完整右键上下文菜单"),
                ShortcutItem(keys: ["文件拖拽"], description: "自动上传至当前 SFTP 目录并贴入路径")
            ]
        ),
        ShortcutGroup(
            title: "应用与偏好",
            icon: "gearshape",
            items: [
                ShortcutItem(keys: ["⌘", ","], description: "打开偏好设置 (外观/字体/SFTP/备份)"),
                ShortcutItem(keys: ["⌘", "/"], description: "打开此快捷键速查表"),
                ShortcutItem(keys: ["⌘", "Q"], description: "退出 ApexTerm")
            ]
        )
    ]
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "command")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.accentColor)
                
                Text(L10n.menuShortcuts)
                    .font(.title2.bold())
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(ApexStyle.subtleSurface)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: group.icon)
                                    .foregroundColor(.accentColor)
                                Text(group.title)
                                    .font(.headline)
                            }
                            
                            VStack(spacing: 6) {
                                ForEach(group.items) { item in
                                    HStack {
                                        Text(item.description)
                                            .font(.system(size: 13))
                                            .foregroundColor(.primary)
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 4) {
                                            ForEach(item.keys, id: \.self) { key in
                                                Text(key)
                                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Color(nsColor: .controlBackgroundColor))
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                                    )
                                                    .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(Color.primary.opacity(0.02))
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(width: 580, height: 480)
            
            Divider()
            
            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding()
            .background(ApexStyle.subtleSurface)
        }
        .onExitCommand {
            dismiss()
        }
        .background(
            Button("") {
                dismiss()
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
        )
    }
}
