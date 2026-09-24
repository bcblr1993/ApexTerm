import Foundation

/// Represents a reusable command snippet with templating
public struct Snippet: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var command: String
    public var category: String
    public var autoExecute: Bool
    
    public init(
        id: UUID = UUID(),
        title: String,
        command: String,
        category: String = "General",
        autoExecute: Bool = false
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.autoExecute = autoExecute
    }
    
    /// Interpolates variables like {{host}}, {{user}}, {{date}} into command
    public func resolvedCommand(context: [String: String]) -> String {
        var result = command
        for (key, val) in context {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: val)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "{{date}}", with: formatter.string(from: Date()))
        return result
    }
}
