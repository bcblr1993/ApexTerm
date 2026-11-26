import Foundation

/// Trigger action when a regex pattern matches terminal output
public enum TriggerAction: Codable, Sendable, Equatable, Hashable {
    case highlight(colorHex: String)
    case sendResponse(text: String)
    case notify(title: String)
}

/// A regex rule that monitors terminal stream and acts on matches
public struct Trigger: Identifiable, Codable, Sendable, Equatable, Hashable {
    public static let defaultCooldownSeconds: TimeInterval = 5.0

    public var id: UUID
    public var name: String
    public var regexPattern: String
    public var isCaseSensitive: Bool
    public var action: TriggerAction
    public var isEnabled: Bool
    public var cooldownSeconds: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case regexPattern
        case isCaseSensitive
        case action
        case isEnabled
        case cooldownSeconds
    }

    public init(
        id: UUID = UUID(),
        name: String,
        regexPattern: String,
        isCaseSensitive: Bool = false,
        action: TriggerAction,
        isEnabled: Bool = true,
        cooldownSeconds: TimeInterval = Trigger.defaultCooldownSeconds
    ) {
        self.id = id
        self.name = name
        self.regexPattern = regexPattern
        self.isCaseSensitive = isCaseSensitive
        self.action = action
        self.isEnabled = isEnabled
        self.cooldownSeconds = max(0, cooldownSeconds)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.regexPattern = try container.decode(String.self, forKey: .regexPattern)
        self.isCaseSensitive = try container.decodeIfPresent(Bool.self, forKey: .isCaseSensitive) ?? false
        self.action = try container.decode(TriggerAction.self, forKey: .action)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let rawCooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldownSeconds) ?? Self.defaultCooldownSeconds
        self.cooldownSeconds = max(0, rawCooldown)
    }
}
