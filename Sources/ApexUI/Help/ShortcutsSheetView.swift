import SwiftUI
import ApexCore

/// Keyboard Shortcuts Cheat Sheet modal driven by `ApexShortcutRegistry`
public struct ShortcutsSheetView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    
    private struct ShortcutItem: Identifiable {
        let id: String
        let keys: [String]
        let description: String
    }
    
    private struct ShortcutGroup: Identifiable {
        let id: String
        let title: String
        let icon: String
        let items: [ShortcutItem]
    }
    
    private let groups: [ShortcutGroup]
    
    public init() {
        self.groups = ApexShortcutCategory.allCases.compactMap { category in
            let defs = ApexShortcutRegistry.entries(in: category)
            guard !defs.isEmpty else { return nil }
            let items = defs.map { def in
                ShortcutItem(id: def.id, keys: def.keys, description: def.description)
            }
            return ShortcutGroup(id: category.rawValue, title: category.title, icon: category.iconName, items: items)
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "command")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                    .accessibilityHidden(true)
                
                Text(L10n.menuShortcuts)
                    .font(.title2.bold())
                    .accessibilityIdentifier("shortcuts.title")
                
                Spacer()
                
                ApexIconButton(
                    icon: "xmark",
                    label: "关闭",
                    size: 24,
                    iconSize: 11
                ) {
                    dismiss()
                }
                .accessibilityIdentifier("shortcuts.close.header")
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.subtleSurface)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Image(systemName: group.icon)
                                    .foregroundColor(ApexStyle.accent)
                                    .accessibilityHidden(true)
                                Text(group.title)
                                    .font(.headline)
                            }
                            .accessibilityAddTraits(.isHeader)
                            
                            VStack(spacing: 6) {
                                ForEach(group.items) { item in
                                    HStack {
                                        Text(item.description)
                                            .font(.system(size: 13))
                                            .foregroundColor(ApexStyle.primary)
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 4) {
                                            ForEach(item.keys, id: \.self) { key in
                                                Text(key)
                                                    .apexKeycap()
                                            }
                                        }
                                        .fixedSize()
                                        .layoutPriority(1)
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, ApexStyle.s2)
                                    .background(ApexStyle.primary.opacity(0.02))
                                    .cornerRadius(6)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(item.description)，快捷键 \(item.keys.joined(separator: " "))")
                                }
                            }
                        }
                    }
                }
                .padding(ApexStyle.s4)
            }
            .frame(minWidth: 420, idealWidth: 580, maxWidth: 680, minHeight: 240, idealHeight: 460, maxHeight: 620)
            
            Divider()
            
            HStack {
                Spacer()
                ApexActionButton(
                    "关闭",
                    tint: ApexStyle.secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("shortcuts.close.footer")
            }
            .padding(ApexStyle.s4)
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
            .accessibilityHidden(true)
        )
    }
}
