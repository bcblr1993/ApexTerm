import Foundation
import ApexCore

public struct HighlightMatch: Sendable, Equatable {
    public let range: NSRange
    public let colorHex: String
    public let trigger: Trigger
}

public struct TriggerActionEvent: Sendable, Equatable {
    public let trigger: Trigger
    public let matchedText: String
    public let range: NSRange

    public init(trigger: Trigger, matchedText: String, range: NSRange) {
        self.trigger = trigger
        self.matchedText = matchedText
        self.range = range
    }
}

/// Evaluates configured Triggers against terminal text lines
public final class KeywordHighlighter: @unchecked Sendable {
    private var triggers: [Trigger] = []
    private var compiledRegexes: [(Trigger, NSRegularExpression)] = []
    private var actionRegexes: [(Trigger, NSRegularExpression)] = []
    private var lastFiredAt: [UUID: Date] = [:]
    private let lock = NSLock()
    
    public init(triggers: [Trigger] = []) {
        setTriggers(triggers)
    }
    
    public func setTriggers(_ triggers: [Trigger]) {
        lock.lock()
        defer { lock.unlock() }
        self.triggers = triggers
        self.compiledRegexes.removeAll()
        self.actionRegexes.removeAll()
        var activeIDs: Set<UUID> = []
        
        for trigger in triggers where trigger.isEnabled {
            let options: NSRegularExpression.Options = trigger.isCaseSensitive ? [] : [.caseInsensitive]
            if let regex = try? NSRegularExpression(pattern: trigger.regexPattern, options: options) {
                compiledRegexes.append((trigger, regex))
                activeIDs.insert(trigger.id)
                switch trigger.action {
                case .sendResponse, .notify:
                    actionRegexes.append((trigger, regex))
                case .highlight:
                    break
                }
            }
        }
        lastFiredAt = lastFiredAt.filter { activeIDs.contains($0.key) }
    }
    
    /// Whether at least one enabled trigger pattern is compiled and ready to match.
    public var hasActiveTriggers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !compiledRegexes.isEmpty
    }

    /// Whether at least one enabled `.sendResponse` or `.notify` trigger is compiled.
    public var hasActiveActionTriggers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !actionRegexes.isEmpty
    }

    public func resetCooldowns() {
        lock.lock()
        defer { lock.unlock() }
        lastFiredAt.removeAll()
    }

    /// Finds all trigger matches in the given string
    public func findMatches(in text: String) -> [HighlightMatch] {
        lock.lock()
        defer { lock.unlock() }
        guard !compiledRegexes.isEmpty else { return [] }

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

    /// Evaluates `.sendResponse` and `.notify` triggers against plain terminal output with per-trigger cooldown throttling.
    public func evaluateActions(
        in text: String,
        now: Date = Date(),
        allowAutoResponse: Bool = true
    ) -> [TriggerActionEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !actionRegexes.isEmpty, !text.isEmpty else { return [] }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var events: [TriggerActionEvent] = []

        for (trigger, regex) in actionRegexes {
            if case .sendResponse = trigger.action, !allowAutoResponse {
                continue
            }
            let cooldown = max(0, trigger.cooldownSeconds)
            if let last = lastFiredAt[trigger.id], now.timeIntervalSince(last) < cooldown {
                continue
            }
            if let match = regex.firstMatch(in: text, options: [], range: fullRange), match.range.location != NSNotFound {
                lastFiredAt[trigger.id] = now
                let matchedText = nsString.substring(with: match.range)
                events.append(TriggerActionEvent(trigger: trigger, matchedText: matchedText, range: match.range))
            }
        }
        return events
    }
}
