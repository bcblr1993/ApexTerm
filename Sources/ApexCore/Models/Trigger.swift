import Foundation

/// Trigger action when a regex pattern matches terminal output
public enum TriggerAction: Codable, Sendable, Equatable, Hashable {
    case highlight(colorHex: String)
    case sendResponse(text: String)
    case notify(title: String)
}

/// A regex rule that monitors terminal stream and acts on matches
public struct Trigger: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var regexPattern: String
    public var isCaseSensitive: Bool
    public var action: TriggerAction
    public var isEnabled: Bool
    
    public init(
        id: UUID = UUID(),
        name: String,
        regexPattern: String,
        isCaseSensitive: Bool = false,
        action: TriggerAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.regexPattern = regexPattern
        self.isCaseSensitive = isCaseSensitive
        self.action = action
        self.isEnabled = isEnabled
    }
}
