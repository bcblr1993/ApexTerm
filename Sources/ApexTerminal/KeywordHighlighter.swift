import Foundation
import ApexCore

public struct HighlightMatch: Sendable, Equatable {
    public let range: NSRange
    public let colorHex: String
    public let trigger: Trigger
}

/// Evaluates configured Triggers against terminal text lines
public final class KeywordHighlighter: @unchecked Sendable {
    private var triggers: [Trigger] = []
    private var compiledRegexes: [(Trigger, NSRegularExpression)] = []
    private let lock = NSLock()
    
    public init(triggers: [Trigger] = []) {
        setTriggers(triggers)
    }
    
    public func setTriggers(_ triggers: [Trigger]) {
        lock.lock()
        defer { lock.unlock() }
        self.triggers = triggers
        self.compiledRegexes.removeAll()
        
        for trigger in triggers where trigger.isEnabled {
            let options: NSRegularExpression.Options = trigger.isCaseSensitive ? [] : [.caseInsensitive]
            if let regex = try? NSRegularExpression(pattern: trigger.regexPattern, options: options) {
                compiledRegexes.append((trigger, regex))
            }
        }
    }
    
    /// Finds all trigger matches in the given string
    public func findMatches(in text: String) -> [HighlightMatch] {
        lock.lock()
        defer { lock.unlock() }
        
        var matches: [HighlightMatch] = []
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        
        for (trigger, regex) in compiledRegexes {
            let results = regex.matches(in: text, options: [], range: fullRange)
            for res in results {
                switch trigger.action {
                case .highlight(let hex):
                    matches.append(HighlightMatch(range: res.range, colorHex: hex, trigger: trigger))
                default:
                    break
                }
            }
        }
        return matches
    }
}
