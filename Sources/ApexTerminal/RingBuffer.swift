import Foundation
import ApexCore

/// Individual styled terminal cell
public struct TerminalCell: Equatable, Sendable {
    public var char: Character
    public var fgHex: String?
    public var isBold: Bool
    public var ansiColorIndex: Int?
    var isContinuation = false
    var extraStyle = SGRStyle(foreground: nil, index: nil, bold: false)
    var style: SGRStyle {
        var result = extraStyle
        result.foreground = fgHex; result.index = ansiColorIndex; result.bold = isBold
        return result
    }
    
    public init(char: Character, fgHex: String? = nil, isBold: Bool = false, ansiColorIndex: Int? = nil) {
        self.char = char
        self.fgHex = fgHex
        self.isBold = isBold
        self.ansiColorIndex = ansiColorIndex
    }
}

/// Parsed remote clipboard write request delivered via OSC 52.
public struct OSC52WriteRequest: Sendable, Equatable {
    public let selection: String
    public let text: String
    public let byteCount: Int

    public init(selection: String, text: String, byteCount: Int) {
        self.selection = selection
        self.text = text
        self.byteCount = byteCount
    }
}

/// Safe parser for OSC 52 (`<selection>;<base64>`) payloads.
/// Rejects clipboard read queries (`?`) and enforces a strict decoded size limit.
public enum OSC52Parser {
    public static let defaultMaxDecodedBytes = 100 * 1024

    public static func parse(payload: String, maxDecodedBytes: Int = defaultMaxDecodedBytes) -> OSC52WriteRequest? {
        guard let semicolonIndex = payload.firstIndex(of: ";") else { return nil }
        let selection = String(payload[..<semicolonIndex])
        let dataSlice = payload[payload.index(after: semicolonIndex)...]
        let trimmed = dataSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        // Security guardrail: never allow remote processes to query or read local clipboard.
        if trimmed == "?" || trimmed.isEmpty { return nil }
        let compactBase64 = String(trimmed.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard !compactBase64.isEmpty else { return nil }
        if (compactBase64.count * 3) / 4 > maxDecodedBytes + 3 { return nil }
        guard let decoded = Data(base64Encoded: compactBase64),
              !decoded.isEmpty,
              decoded.count <= maxDecodedBytes else {
            return nil
        }
        guard let text = String(data: decoded, encoding: .utf8) else { return nil }
        return OSC52WriteRequest(selection: selection, text: text, byteCount: decoded.count)
    }
}

/// Parsed desktop notification delivered via OSC 9 or OSC 777.
public struct OSCDesktopNotification: Sendable, Equatable {
    public let title: String?
    public let body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

/// Safe parser for OSC 9 (`9;<body>`) and OSC 777 (`777;notify;<title>;<body>`) sequences.
/// Explicitly ignores ConEmu / Windows Terminal progress subcommands (`9;4;...`),
/// strips control characters, and bounds payloads to `maxPayloadBytes`.
public enum OSCNotificationParser {
    public static let maxPayloadBytes = 1024

    public static func parse(payload: String) -> OSCDesktopNotification? {
        if payload.hasPrefix("9;") {
            let rest = String(payload.dropFirst(2))
            // Ignore ConEmu / Windows Terminal OSC 9;4 progress reporting subcommands.
            if rest == "4" || rest.hasPrefix("4;") {
                return nil
            }
            let sanitizedBody = DesktopNotificationManager.sanitize(rest, maxUTF8Bytes: maxPayloadBytes)
            guard !sanitizedBody.isEmpty else { return nil }
            return OSCDesktopNotification(title: nil, body: sanitizedBody)
        }

        if payload.hasPrefix("777;") {
            let rest = String(payload.dropFirst(4))
            guard rest.hasPrefix("notify;") else { return nil }
            let notifyContent = String(rest.dropFirst("notify;".count))
            if let sep = notifyContent.firstIndex(of: ";") {
                let rawTitle = String(notifyContent[..<sep])
                let rawBody = String(notifyContent[notifyContent.index(after: sep)...])
                let title = DesktopNotificationManager.sanitize(rawTitle, maxUTF8Bytes: 256)
                let body = DesktopNotificationManager.sanitize(rawBody, maxUTF8Bytes: maxPayloadBytes)
                if body.isEmpty {
                    guard !title.isEmpty else { return nil }
                    return OSCDesktopNotification(title: nil, body: title)
                }
                return OSCDesktopNotification(title: title.isEmpty ? nil : title, body: body)
            } else {
                let body = DesktopNotificationManager.sanitize(notifyContent, maxUTF8Bytes: maxPayloadBytes)
                guard !body.isEmpty else { return nil }
                return OSCDesktopNotification(title: nil, body: body)
            }
        }

        return nil
    }
}

/// High-performance circular line buffer for terminal scrollback history with real-time update notifications
public final class TerminalRingBuffer: @unchecked Sendable {
    private var historyLimit: Int
    public var maxLines: Int { lock.withLock { historyLimit } }
    private var buffer: [String]
    private var head: Int = 0
    private var count: Int = 0
    private let lock = NSLock()
    private let streamLock = NSLock()
    private var streamDecoder = UTF8StreamDecoder()
    
    private var activeLine: String = ""
    private var isEditingActiveLine: Bool = false
    private var activeCells: [TerminalCell] = []
    private var belowActiveRows: [[TerminalCell]] = []
    private var cursorCol: Int = 0
    private var currentStyle = SGRStyle(foreground: nil, index: nil, bold: false)
    private var savedNormalStyle: SGRStyle? = nil
    private var currentFgHex: String? { get { currentStyle.foreground } set { currentStyle.foreground = newValue } }
    private var currentANSIIndex: Int? { get { currentStyle.index } set { currentStyle.index = newValue } }
    private var currentBold: Bool { get { currentStyle.bold } set { currentStyle.bold = newValue } }

    private func styledCell(_ char: Character) -> TerminalCell {
        var cell = TerminalCell(char: char, fgHex: currentFgHex, isBold: currentBold, ansiColorIndex: currentANSIIndex)
        cell.extraStyle = currentStyle
        return cell
    }
    private var pendingSequence: String = ""
    private let vtParser = VTParser()
    public let shellIntegration = ShellIntegrationTracker()
    private var screen: [[TerminalCell]]? = nil
    private var screenRows = 35
    private var screenColumns = 120
    private var screenRow = 0
    private var screenColumn = 0
    private var scrollTop = 0
    private var scrollBottom = 34
    private var savedScreenPosition: (Int, Int)?
    private var _screenRevision: Int64 = 0
    private var _isCursorHidden: Bool = false
    private var _isApplicationCursorKeys: Bool = false
    private var _mouseTrackingMode = 0
    private var _isSGRMouseEnabled = false

    public var mouseTrackingMode: Int { lock.lock(); defer { lock.unlock() }; return _mouseTrackingMode }
    public var isSGRMouseEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _isSGRMouseEnabled }

    public var screenRevision: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _screenRevision
    }

    public var isApplicationCursorKeys: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isApplicationCursorKeys
    }

    public var screenLines: [String]? {
        lock.lock(); defer { lock.unlock() }
        return screen?.map { renderCellsToString($0) }
    }

    /// Whether terminal is currently in alternate screen buffer mode (e.g. Vim, less, htop)
    public var isInAlternateScreen: Bool {
        lock.lock(); defer { lock.unlock() }
        return screen != nil
    }

    /// Current terminal dimensions (columns, rows)
    public var dimensions: (columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        return (screenColumns, screenRows)
    }

    public func setDimensions(columns: Int, rows: Int) {
        lock.lock()
        let newCols = max(1, columns)
        let newRows = max(1, rows)
        if screenColumns == newCols && screenRows == newRows {
            lock.unlock()
            return
        }
        screenColumns = newCols
        screenRows = newRows
        scrollTop = 0
        scrollBottom = max(0, newRows - 1)
        var needsUpdate = false
        if var grid = screen {
            grid = grid.prefix(screenRows).map {
                var row = Array($0.prefix(screenColumns))
                normalizeWideCells(&row)
                return row
            }
            while grid.count < screenRows { grid.append([]) }
            screen = grid
            screenRow = min(screenRow, screenRows - 1)
            screenColumn = min(screenColumn, screenColumns - 1)
            _screenRevision += 1
            needsUpdate = true
        }
        let updateHandler = onUpdate
        lock.unlock()
        if needsUpdate { updateHandler?() }
    }
    
    public var onUpdate: (@Sendable () -> Void)?
    public var onOSC52WriteRequest: (@Sendable (OSC52WriteRequest) -> Void)?
    public var onDesktopNotification: (@Sendable (_ title: String?, _ body: String) -> Void)?

    public static let synchronizedOutputWatchdogTimeout: Duration = .milliseconds(120)
    public static let maxUnclosedOSCChars: Int = 163_840
    
    public func setHistoryLimit(_ requestedLimit: Int) {
        lock.lock()
        let limit = max(1, requestedLimit)
        guard limit != historyLimit else { lock.unlock(); return }
        let retained = min(count, limit)
        let start = count - retained
        var resized = [String](repeating: "", count: limit)
        for offset in 0..<retained { resized[offset] = buffer[(head + start + offset) % historyLimit] }
        buffer = resized
        historyLimit = limit
        count = retained
        head = 0
        _isClearPending = true
        let update = onUpdate
        lock.unlock()
        update?()
    }

    public init(maxLines: Int = 10_000) {
        self.historyLimit = max(1, maxLines)
        self.buffer = [String](repeating: "", count: self.historyLimit)
    }
    
    private var _totalCommittedCount: Int64 = 0
    private var _minRewoundCommittedCount: Int64? = nil
    private var _isClearPending: Bool = false
    private var _isBellPending: Bool = false
    private var _isBracketedPasteEnabled: Bool = false
    private var _isSynchronizedOutputActive: Bool = false
    private var _syncOutputStartedAt: ContinuousClock.Instant? = nil

    /// Whether DEC synchronized output mode (?2026h) is currently active, auto-resetting past watchdog timeout.
    public var isSynchronizedOutputActive: Bool {
        isSynchronizedOutputActive(now: .now, timeout: Self.synchronizedOutputWatchdogTimeout)
    }

    public func isSynchronizedOutputActive(
        now: ContinuousClock.Instant,
        timeout: Duration = TerminalRingBuffer.synchronizedOutputWatchdogTimeout
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _isSynchronizedOutputActive else { return false }
        if let startedAt = _syncOutputStartedAt, startedAt.duration(to: now) >= timeout {
            _isSynchronizedOutputActive = false
            _syncOutputStartedAt = nil
            return false
        }
        return true
    }
    
    /// Whether the remote shell has enabled bracketed paste mode (DEC private mode 2004)
    public var isBracketedPasteEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isBracketedPasteEnabled
    }
    
    /// Atomically consume and reset clear pending flag
    public func consumeClearFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _isClearPending {
            _isClearPending = false
            return true
        }
        return false
    }

    /// Atomically consume the lowest committed line index invalidated by normal-mode cursor rewind.
    public func consumeRewindCommittedIndex() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let watermark = _minRewoundCommittedCount
        _minRewoundCommittedCount = nil
        return watermark
    }

    /// Atomically consume and reset pending terminal bell (\u{07}) flag
    public func consumeBellFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _isBellPending {
            _isBellPending = false
            return true
        }
        return false
    }
    
    /// Total lifetime committed line count (monotonically increasing)
    public var totalCommittedCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _totalCommittedCount
    }
    
    /// Committed historical line count in circular window (capped at historyLimit)
    public var committedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    /// Current cursor column position (0-indexed) on the active line
    public var cursorColumn: Int {
        lock.lock()
        defer { lock.unlock() }
        if screen != nil { return screenColumn }
        if isEditingActiveLine {
            return cursorCol
        } else {
            return activeLine.reduce(0) { $0 + TerminalCharacterWidth.columns($1) }
        }
    }
    
    /// Map cell columns to the UTF-16 offset used by AppKit's text storage.
    public var activeCursorUTF16Offset: Int {
        lock.lock(); defer { lock.unlock() }
        if isEditingActiveLine {
            return activeCells.prefix(cursorCol).filter { !$0.isContinuation }.reduce(0) { $0 + String($1.char).utf16.count }
        }
        return activeLine.utf16.count
    }

    /// Current cursor position (row, column) in 0-indexed coordinates
    public var cursorPosition: (row: Int, column: Int) {
        lock.lock()
        defer { lock.unlock() }
        if screen != nil {
            return (screenRow, screenColumn)
        } else {
            return (0, isEditingActiveLine ? cursorCol : activeLine.reduce(0) { $0 + TerminalCharacterWidth.columns($1) })
        }
    }

    /// Whether cursor visibility is suppressed by DECTCEM (\e[?25l)
    public var isCursorHidden: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCursorHidden
    }
    
    /// Current in-progress active line text (e.g. prompt and typed characters)
    public var currentActiveLine: String {
        lock.lock()
        defer { lock.unlock() }
        return activeRenderedLines().joined(separator: "\n")
    }
    
    /// Return committed lines from start index to count
    public func committedLines(from start: Int, count requestedCount: Int) -> [String] {
        lines(from: start, count: requestedCount)
    }
    
    /// Return the most recent N committed lines in chronological order
    public func tailLines(count requestedCount: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        guard requestedCount > 0 else { return [] }
        let fetchCount = min(requestedCount, count)
        guard fetchCount > 0 else { return [] }
        var result = [String]()
        result.reserveCapacity(fetchCount)
        let startOffset = count - fetchCount
        for i in 0..<fetchCount {
            let index = (head + startOffset + i) % historyLimit
            result.append(buffer[index])
        }
        return result
    }
    
    /// Decode raw PTY bytes without corrupting characters split across reads.
    public func appendData(_ data: Data) {
        streamLock.lock(); defer { streamLock.unlock() }
        let text = streamDecoder.decode(data)
        if !text.isEmpty { appendStream(text) }
    }

    public func finishStream() {
        streamLock.lock(); defer { streamLock.unlock() }
        let text = streamDecoder.finish()
        if !text.isEmpty { appendStream(text) }
    }

    /// Append streaming raw output from terminal PTY
    public func appendStream(_ text: String) {
        var osc52Requests: [OSC52WriteRequest] = []
        var desktopNotifications: [OSCDesktopNotification] = []
        lock.lock()
        defer {
            let updateHandler = onUpdate
            let osc52Handler = onOSC52WriteRequest
            let requestsToDeliver = osc52Requests
            let desktopNotificationHandler = onDesktopNotification
            let notificationsToDeliver = desktopNotifications
            lock.unlock()
            if let osc52Handler, !requestsToDeliver.isEmpty {
                for request in requestsToDeliver {
                    osc52Handler(request)
                }
            }
            if let desktopNotificationHandler, !notificationsToDeliver.isEmpty {
                for notification in notificationsToDeliver {
                    desktopNotificationHandler(notification.title, notification.body)
                }
            }
            updateHandler?()
        }
        
        // Ordinary ASCII log chunks can be committed in whole lines. Control sequences,
        // Unicode and cursor editing continue through the terminal state machine below.
        if screen == nil, pendingSequence.isEmpty, !isEditingActiveLine,
           currentStyle == SGRStyle(foreground: nil, index: nil, bold: false),
           text.utf8.allSatisfy({ $0 == 10 || ($0 >= 32 && $0 < 127) }) {
            let segments = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
            for (offset, segment) in segments.enumerated() {
                activeLine.append(String(decoding: segment, as: UTF8.self))
                if offset < segments.count - 1 { commitActiveLine() }
            }
            return
        }

        var fullText = text
        if !pendingSequence.isEmpty {
            fullText = pendingSequence + fullText
            pendingSequence = ""
        }
        var i = fullText.startIndex
        while i < fullText.endIndex {
            let ch = fullText[i]
            if ch == "\r\n" || ch == "\n" {
                if screen != nil {
                    if ch == "\r\n" { screenColumn = 0 }
                    screenNewline()
                } else { commitActiveLine() }
                i = fullText.index(after: i)
                continue
            } else if ch == "\r" {
                if screen != nil { screenColumn = 0; i = fullText.index(after: i); continue }
                ensureEditingMode()
                cursorCol = 0
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{08}" { // Backspace (BS) - moves cursor left without deletion
                if screen != nil { screenColumn = max(0, screenColumn - 1); i = fullText.index(after: i); continue }
                ensureEditingMode()
                cursorCol = max(0, cursorCol - 1)
                i = fullText.index(after: i)
                continue
            } else if ch == "\t" { // Tab - advance to multiple of 8
                if screen != nil { screenColumn = min(screenColumns - 1, (screenColumn / 8 + 1) * 8); i = fullText.index(after: i); continue }
                ensureEditingMode()
                let nextTab = (cursorCol / 8 + 1) * 8
                while cursorCol < nextTab {
                    putCell(styledCell(" "))
                }
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{07}" { // Bell
                _isBellPending = true
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{001B}" { // ESC sequence
                let escapeStart = i
                let next = fullText.index(after: i)
                if next == fullText.endIndex {
                    pendingSequence = String(fullText[escapeStart...])
                    break
                }
                
                let nextChar = fullText[next]
                if nextChar == "[" { // CSI Sequence
                    var j = fullText.index(after: next)
                    var csiParam = ""
                    var hasIntermediates = false
                    var foundFinal = false
                    while j < fullText.endIndex {
                        let c = fullText[j]
                        let ascii = c.asciiValue ?? 0
                        if ascii >= 0x30 && ascii <= 0x3F { // Parameter bytes
                            if hasIntermediates { break }
                            csiParam.append(c)
                            j = fullText.index(after: j)
                        } else if ascii >= 0x20 && ascii <= 0x2F { // Intermediate bytes
                            hasIntermediates = true
                            j = fullText.index(after: j)
                        } else if ascii >= 0x40 && ascii <= 0x7E { // Final byte
                            foundFinal = true
                            break
                        } else {
                            break
                        }
                    }
                    if !foundFinal {
                        if j == fullText.endIndex {
                            pendingSequence = String(fullText[escapeStart...])
                            break
                        }
                        i = j
                        continue
                    }
                    
                    let finalChar = fullText[j]
                    if csiParam.hasPrefix("?") {
                        handleDECPrivateMode(finalChar: finalChar, param: csiParam)
                    } else if csiParam.hasPrefix(">") || csiParam.hasPrefix("<") || csiParam.hasPrefix("=") || hasIntermediates {
                        // Private / extended CSI (modifyOtherKeys, Kitty keyboard, DECRQM, DECSCUSR) - ignore cleanly
                    } else if screen != nil {
                        handleScreenCSI(finalChar: finalChar, param: csiParam)
                    } else if finalChar == "m" {
                        var style = currentStyle
                        style.apply(param: csiParam)
                        currentStyle = style
                    } else {
                        ensureEditingMode()
                        handleCSI(finalChar: finalChar, param: csiParam)
                    }
                    i = fullText.index(after: j)
                    continue
                } else if "P^_X".contains(nextChar) {
                    // DCS/PM/APC/SOS payloads are controls, never visible terminal text.
                    let payloadStart = fullText.index(after: next)
                    if let terminator = fullText.range(of: "\u{1B}\\", range: payloadStart..<fullText.endIndex) {
                        i = terminator.upperBound
                        continue
                    }
                    if fullText.distance(from: payloadStart, to: fullText.endIndex) > Self.maxUnclosedOSCChars {
                        var dropEnd = payloadStart
                        while dropEnd < fullText.endIndex && fullText[dropEnd] != "\n" && fullText[dropEnd] != "\r\n" {
                            dropEnd = fullText.index(after: dropEnd)
                        }
                        i = dropEnd
                        continue
                    }
                    pendingSequence = String(fullText[escapeStart...])
                    break
                } else if nextChar == "c" {
                    resetTerminalState()
                    i = fullText.index(after: next)
                    continue
                } else if nextChar == "]" { // OSC Sequence
                    let payloadStart = fullText.index(after: next)
                    var j = payloadStart
                    var oscLen = 0
                    var exceededOscCap = false
                    while j < fullText.endIndex && fullText[j] != "\u{0007}" && fullText[j] != "\u{001B}" {
                        j = fullText.index(after: j)
                        oscLen += 1
                        if oscLen > Self.maxUnclosedOSCChars {
                            exceededOscCap = true
                            break
                        }
                    }
                    if exceededOscCap {
                        // Drop oversized unclosed OSC stream through end of payload/line so trailing bytes never print as text.
                        while j < fullText.endIndex && fullText[j] != "\u{0007}" && fullText[j] != "\n" && fullText[j] != "\r\n" {
                            if fullText[j] == "\u{001B}" {
                                let afterEsc = fullText.index(after: j)
                                if afterEsc < fullText.endIndex && fullText[afterEsc] == "\\" {
                                    j = fullText.index(after: afterEsc)
                                }
                                break
                            }
                            j = fullText.index(after: j)
                        }
                        if j < fullText.endIndex && fullText[j] == "\u{0007}" {
                            j = fullText.index(after: j)
                        }
                        i = j
                        continue
                    }
                    let payloadEnd = j
                    var oscAbortedByNewESC = false
                    if j < fullText.endIndex && fullText[j] == "\u{001B}" {
                        let afterEsc = fullText.index(after: j)
                        if afterEsc < fullText.endIndex && fullText[afterEsc] == "\\" {
                            j = afterEsc
                        } else if afterEsc == fullText.endIndex {
                            pendingSequence = String(fullText[escapeStart...])
                            break
                        } else {
                            oscAbortedByNewESC = true
                        }
                    }
                    if j == fullText.endIndex {
                        pendingSequence = String(fullText[escapeStart...])
                        break
                    }
                    let oscPayload = String(fullText[payloadStart..<payloadEnd])
                    if oscPayload.hasPrefix("52;") {
                        if let request = OSC52Parser.parse(payload: String(oscPayload.dropFirst(3))) {
                            osc52Requests.append(request)
                        }
                    } else if oscPayload.hasPrefix("9;") || oscPayload.hasPrefix("777;") {
                        if let notification = OSCNotificationParser.parse(payload: oscPayload) {
                            desktopNotifications.append(notification)
                        }
                    } else {
                        let currentActive = isEditingActiveLine ? renderCellsToString(activeCells) : activeLine
                        var fallbackLine: String? = nil
                        if oscPayload.hasPrefix("133;"),
                           currentActive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let cmdLine = shellIntegration.activeCommandLineIndex {
                            let oldestLifetime = Int(_totalCommittedCount) - count
                            if cmdLine >= oldestLifetime && cmdLine < Int(_totalCommittedCount) {
                                fallbackLine = buffer[(head + (cmdLine - oldestLifetime)) % historyLimit]
                            }
                        }
                        shellIntegration.handleOSCPayload(
                            oscPayload,
                            currentLineIndex: Int(_totalCommittedCount),
                            activeLineText: currentActive,
                            fallbackCommandLineText: fallbackLine
                        )
                    }
                    i = oscAbortedByNewESC ? j : fullText.index(after: j)
                    continue
                } else if "()*+-./%# ".contains(nextChar) {
                    // Charset designation has a third byte; it can arrive in another PTY packet.
                    let designator = fullText.index(after: next)
                    if designator == fullText.endIndex {
                        pendingSequence = String(fullText[escapeStart...])
                        break
                    }
                    i = fullText.index(after: designator)
                    continue
                } else {
                    // 2-byte escape sequence (e.g. ESC M, ESC =, ESC >, ESC 7, ESC 8)
                    // Consume both bytes so the second byte does not print as garbage
                    if screen != nil {
                        switch nextChar {
                        case "7": savedScreenPosition = (screenRow, screenColumn)
                        case "8":
                            if let savedScreenPosition {
                                screenRow = min(screenRows - 1, max(0, savedScreenPosition.0))
                                screenColumn = min(screenColumns - 1, max(0, savedScreenPosition.1))
                                _screenRevision += 1
                            }
                        case "M":
                            if screenRow == scrollTop, var grid = screen {
                                grid.remove(at: scrollBottom)
                                grid.insert([], at: scrollTop)
                                screen = grid
                            } else {
                                screenRow = max(0, screenRow - 1)
                            }
                            _screenRevision += 1
                        case "D": screenNewline()
                        case "E": screenColumn = 0; screenNewline()
                        default: break
                        }
                    } else if nextChar == "M" && count > 0 {
                        ensureEditingMode()
                        moveNormalCursorUp(1)
                    }
                    i = fullText.index(after: next)
                    continue
                }
            } else {
                if let ascii = ch.asciiValue, ascii < 32 || ascii == 0x7F {
                    i = fullText.index(after: i)
                    continue
                }
                if screen != nil {
                    screenPut(styledCell(ch))
                    i = fullText.index(after: i)
                    continue
                }
                if isEditingActiveLine {
                    putCell(styledCell(ch))
                } else if currentStyle != SGRStyle(foreground: nil, index: nil, bold: false) {
                    ensureEditingMode()
                    putCell(styledCell(ch))
                } else {
                    activeLine.append(ch)
                }
                i = fullText.index(after: i)
            }
        }
    }
    
    private func parseLineToCells(_ line: String) -> [TerminalCell] {
        guard !line.isEmpty else { return [] }
        var cells: [TerminalCell] = []
        let spans = vtParser.parseANSI(line)
        for span in spans {
            for c in span.text {
                var cell = TerminalCell(char: c, fgHex: span.foregroundColorHex, isBold: span.isBold, ansiColorIndex: span.ansiColorIndex)
                cell.extraStyle.background = span.backgroundColorHex
                cell.extraStyle.backgroundIndex = span.backgroundANSIColorIndex
                cell.extraStyle.italic = span.isItalic
                cell.extraStyle.underline = span.isUnderlined
                cell.extraStyle.strikethrough = span.isStrikethrough
                cell.extraStyle.inverse = span.isInverse
                cells.append(cell)
                if TerminalCharacterWidth.columns(c) == 2 {
                    var continuation = TerminalCell(char: " ")
                    continuation.isContinuation = true
                    cells.append(continuation)
                }
            }
        }
        return cells
    }

    private func ensureEditingMode() {
        guard !isEditingActiveLine else { return }
        isEditingActiveLine = true
        activeCells = parseLineToCells(activeLine)
        activeLine = ""
        cursorCol = activeCells.count
    }

    private func moveNormalCursorUp(_ lines: Int) {
        let steps = min(max(1, lines), count, max(1, screenRows - 1))
        guard steps > 0 else { return }
        for _ in 0..<steps {
            belowActiveRows.insert(activeCells, at: 0)
            let lastIndex = (head + count - 1) % historyLimit
            let popped = buffer[lastIndex]
            buffer[lastIndex] = ""
            count -= 1
            _totalCommittedCount -= 1
            _minRewoundCommittedCount = min(_minRewoundCommittedCount ?? _totalCommittedCount, _totalCommittedCount)
            activeCells = parseLineToCells(popped)
        }
    }

    private func moveNormalCursorDown(_ lines: Int) {
        let steps = min(max(1, lines), belowActiveRows.count)
        guard steps > 0 else { return }
        for _ in 0..<steps {
            commitFastLine(renderCellsToString(activeCells, trimAfterColumn: 0))
            activeCells = belowActiveRows.removeFirst()
        }
    }

    private func activeRenderedLines() -> [String] {
        guard isEditingActiveLine else {
            return activeLine.isEmpty ? [] : [activeLine]
        }
        let first = renderCellsToString(activeCells, trimAfterColumn: cursorCol)
        var below = belowActiveRows.map { renderCellsToString($0, trimAfterColumn: 0) }
        while let last = below.last, last.isEmpty {
            below.removeLast()
        }
        if !below.isEmpty {
            return [first] + below
        }
        return first.isEmpty ? [] : [first]
    }
    
    /// Clear a whole wide glyph if either of its cells is overwritten.
    private func eraseScreenCells(_ cells: inout [TerminalCell], from start: Int, through end: Int) {
        while cells.count < end { cells.append(TerminalCell(char: " ")) }
        for column in start..<end {
            clearGlyph(in: &cells, at: column)
            cells[column] = styledCell(" ")
        }
    }

    private func normalizeWideCells(_ cells: inout [TerminalCell]) {
        for index in cells.indices {
            if cells[index].isContinuation {
                if index == 0 || TerminalCharacterWidth.columns(cells[index - 1].char) != 2 {
                    cells[index] = TerminalCell(char: " ")
                }
            } else if TerminalCharacterWidth.columns(cells[index].char) == 2 {
                if index + 1 == cells.count || !cells[index + 1].isContinuation {
                    cells[index] = TerminalCell(char: " ")
                }
            }
        }
    }

    private func clearGlyph(in cells: inout [TerminalCell], at column: Int) {
        guard column >= 0 && column < cells.count else { return }
        if cells[column].isContinuation && column > 0 { cells[column - 1] = TerminalCell(char: " ") }
        if column + 1 < cells.count && cells[column + 1].isContinuation { cells[column + 1] = TerminalCell(char: " ") }
        cells[column] = TerminalCell(char: " ")
    }

    private func appendedGrapheme(_ character: Character, in cells: [TerminalCell], column: Int) -> (index: Int, character: Character, oldWidth: Int, newWidth: Int)? {
        var previous = column - 1
        guard previous >= 0, previous < cells.count else { return nil }
        if cells[previous].isContinuation { previous -= 1 }
        guard previous >= 0 else { return nil }
        let joined = String(cells[previous].char) + String(character)
        guard joined.count == 1, let merged = joined.first else { return nil }
        let oldWidth = column - previous
        return (previous, merged, oldWidth, TerminalCharacterWidth.columns(merged))
    }

    private func writeCell(_ cell: TerminalCell, into cells: inout [TerminalCell], column: Int) -> Int {
        let width = TerminalCharacterWidth.columns(cell.char)
        if let merged = appendedGrapheme(cell.char, in: cells, column: column) {
            if merged.newWidth > merged.oldWidth {
                while cells.count <= merged.index + 1 { cells.append(TerminalCell(char: " ")) }
                clearGlyph(in: &cells, at: merged.index + 1)
                var continuation = TerminalCell(char: " ")
                continuation.isContinuation = true
                cells[merged.index + 1] = continuation
            }
            cells[merged.index].char = merged.character
            return merged.newWidth - merged.oldWidth
        }
        if width == 0 {
            var previous = min(column - 1, cells.count - 1)
            if previous >= 0 && cells[previous].isContinuation { previous -= 1 }
            if previous >= 0, let combined = (String(cells[previous].char) + String(cell.char)).first { cells[previous].char = combined }
            return 0
        }
        while cells.count < column + width { cells.append(TerminalCell(char: " ")) }
        for offset in 0..<width { clearGlyph(in: &cells, at: column + offset) }
        cells[column] = cell
        if width == 2 {
            var continuation = TerminalCell(char: " ")
            continuation.isContinuation = true
            cells[column + 1] = continuation
        }
        return width
    }

    private func putCell(_ cell: TerminalCell) {
        cursorCol += writeCell(cell, into: &activeCells, column: cursorCol)
    }

    private func screenNewline() {
        if screenRow == scrollBottom, var grid = screen {
            if scrollTop < grid.count && scrollBottom < grid.count && scrollTop <= scrollBottom {
                grid.remove(at: scrollTop)
                grid.insert([], at: scrollBottom)
                screen = grid
            }
        } else {
            screenRow = min(screenRows - 1, screenRow + 1)
        }
        _screenRevision += 1
    }

    private func screenPut(_ cell: TerminalCell) {
        guard var grid = screen else { return }
        let merged = appendedGrapheme(cell.char, in: grid[screenRow], column: screenColumn)
        var cell = cell
        let width = merged.map { $0.newWidth - $0.oldWidth } ?? TerminalCharacterWidth.columns(cell.char)
        if width > 0 && screenColumn + width > screenColumns {
            if let merged {
                cell = grid[screenRow][merged.index]
                cell.char = merged.character
                clearGlyph(in: &grid[screenRow], at: merged.index)
                screen = grid
            }
            screenColumn = 0
            screenNewline()
            grid = screen!
        }
        guard TerminalCharacterWidth.columns(cell.char) <= screenColumns else { return }
        var row = grid[screenRow]
        screenColumn += writeCell(cell, into: &row, column: screenColumn)
        grid[screenRow] = row
        screen = grid
        _screenRevision += 1
    }

    private func handleDECPrivateMode(finalChar: Character, param: String) {
        let isSet = (finalChar == "h")
        let isReset = (finalChar == "l")
        guard isSet || isReset else { return }
        let modes = param.dropFirst().split(separator: ";").compactMap { Int($0) }
        for mode in modes {
            switch mode {
            case 1049, 1047, 47:
                if isSet {
                    if screen == nil {
                        savedNormalStyle = currentStyle
                    }
                    if mode == 1049 {
                        currentStyle = SGRStyle(foreground: nil, index: nil, bold: false)
                    }
                    screen = Array(repeating: [], count: screenRows)
                    screenRow = 0
                    screenColumn = 0
                    scrollTop = 0
                    scrollBottom = max(0, screenRows - 1)
                    savedScreenPosition = nil
                    _screenRevision += 1
                } else {
                    let wasInAltScreen = (screen != nil)
                    screen = nil
                    scrollTop = 0
                    scrollBottom = max(0, screenRows - 1)
                    _isCursorHidden = false
                    _isApplicationCursorKeys = false
                    if let saved = savedNormalStyle {
                        currentStyle = saved
                        savedNormalStyle = nil
                    } else if wasInAltScreen {
                        currentStyle = SGRStyle(foreground: nil, index: nil, bold: false)
                    }
                    _screenRevision += 1
                    if wasInAltScreen {
                        _isClearPending = true
                    }
                }
            case 1000, 1002, 1003:
                if isSet { _mouseTrackingMode = mode }
                else if _mouseTrackingMode == mode { _mouseTrackingMode = 0 }
            case 1006:
                _isSGRMouseEnabled = isSet
            case 1:
                _isApplicationCursorKeys = isSet
            case 2004:
                _isBracketedPasteEnabled = isSet
            case 2026:
                if isSet {
                    if !_isSynchronizedOutputActive {
                        _syncOutputStartedAt = .now
                    }
                    _isSynchronizedOutputActive = true
                } else {
                    _isSynchronizedOutputActive = false
                    _syncOutputStartedAt = nil
                }
            case 25:
                _isCursorHidden = !isSet
                _screenRevision += 1
            default:
                break
            }
        }
    }

    private func handleScreenCSI(finalChar: Character, param: String) {
        guard var grid = screen else { return }
        defer {
            if "JKP@X".contains(finalChar), var updated = screen {
                for row in updated.indices { normalizeWideCells(&updated[row]) }
                screen = updated
            }
        }
        let values = param.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = values.first ?? 0
        let amount = max(1, first)
        switch finalChar {
        case "m":
            var style = currentStyle
            style.apply(param: param)
            currentStyle = style
        case "H", "f":
            screenRow = min(screenRows - 1, max(0, amount - 1))
            screenColumn = min(screenColumns - 1, max(0, (values.count > 1 ? max(1, values[1]) : 1) - 1))
            _screenRevision += 1
        case "A": screenRow = max(0, screenRow - amount); _screenRevision += 1
        case "B": screenRow = min(screenRows - 1, screenRow + amount); _screenRevision += 1
        case "C": screenColumn = min(screenColumns - 1, screenColumn + amount); _screenRevision += 1
        case "D": screenColumn = max(0, screenColumn - amount); _screenRevision += 1
        case "E": screenRow = min(screenRows - 1, screenRow + amount); screenColumn = 0; _screenRevision += 1
        case "F": screenRow = max(0, screenRow - amount); screenColumn = 0; _screenRevision += 1
        case "G": screenColumn = min(screenColumns - 1, max(0, amount - 1)); _screenRevision += 1
        case "d": screenRow = min(screenRows - 1, max(0, amount - 1)); _screenRevision += 1
        case "J":
            if first == 2 || first == 3 {
                for row in grid.indices { eraseScreenCells(&grid[row], from: 0, through: screenColumns) }
            } else if first == 0 {
                eraseScreenCells(&grid[screenRow], from: screenColumn, through: screenColumns)
                if screenRow + 1 < screenRows {
                    for row in (screenRow + 1)..<screenRows { eraseScreenCells(&grid[row], from: 0, through: screenColumns) }
                }
            } else if first == 1 {
                if screenRow > 0 {
                    for row in 0..<screenRow { eraseScreenCells(&grid[row], from: 0, through: screenColumns) }
                }
                eraseScreenCells(&grid[screenRow], from: 0, through: min(screenColumns, screenColumn + 1))
            }
            screen = grid; _screenRevision += 1
        case "K":
            if first == 2 { eraseScreenCells(&grid[screenRow], from: 0, through: screenColumns) }
            else if first == 0 { eraseScreenCells(&grid[screenRow], from: screenColumn, through: screenColumns) }
            else if first == 1 { eraseScreenCells(&grid[screenRow], from: 0, through: min(screenColumns, screenColumn + 1)) }
            screen = grid; _screenRevision += 1
        case "r":
            let top = (values.count > 0 && values[0] > 0) ? values[0] : 1
            let bottom = (values.count > 1 && values[1] > 0) ? values[1] : screenRows
            scrollTop = max(0, min(screenRows - 1, top - 1))
            scrollBottom = max(scrollTop, min(screenRows - 1, bottom - 1))
            screenRow = 0
            screenColumn = 0
        case "L":
            if screenRow >= scrollTop && screenRow <= scrollBottom {
                let limit = min(amount, scrollBottom - screenRow + 1)
                for _ in 0..<limit {
                    grid.insert([], at: screenRow)
                    if scrollBottom + 1 < grid.count {
                        grid.remove(at: scrollBottom + 1)
                    } else if !grid.isEmpty {
                        grid.removeLast()
                    }
                }
                screen = grid; _screenRevision += 1
            }
        case "M":
            if screenRow >= scrollTop && screenRow <= scrollBottom {
                let limit = min(amount, scrollBottom - screenRow + 1)
                for _ in 0..<limit {
                    grid.remove(at: screenRow)
                    grid.insert([], at: scrollBottom)
                }
                screen = grid; _screenRevision += 1
            }
        case "S":
            let limit = min(amount, scrollBottom - scrollTop + 1)
            for _ in 0..<limit {
                if scrollTop < grid.count {
                    grid.remove(at: scrollTop)
                    grid.insert([], at: scrollBottom)
                }
            }
            screen = grid; _screenRevision += 1
        case "T":
            let limit = min(amount, scrollBottom - scrollTop + 1)
            for _ in 0..<limit {
                if scrollBottom < grid.count {
                    grid.remove(at: scrollBottom)
                    grid.insert([], at: scrollTop)
                }
            }
            screen = grid; _screenRevision += 1
        case "P":
            if screenRow < grid.count {
                var row = grid[screenRow]
                if screenColumn < row.count {
                    let toRemove = min(amount, row.count - screenColumn)
                    row.removeSubrange(screenColumn..<(screenColumn + toRemove))
                    grid[screenRow] = row
                    screen = grid; _screenRevision += 1
                }
            }
        case "@":
            if screenRow < grid.count {
                var row = grid[screenRow]
                if screenColumn > row.count {
                    row.append(contentsOf: repeatElement(TerminalCell(char: " "), count: screenColumn - row.count))
                }
                let blanks = Array(repeating: styledCell(" "), count: min(amount, screenColumns))
                row.insert(contentsOf: blanks, at: min(screenColumn, row.count))
                if row.count > screenColumns {
                    row = Array(row.prefix(screenColumns))
                }
                grid[screenRow] = row
                screen = grid; _screenRevision += 1
            }
        case "X":
            if screenRow < grid.count {
                var row = grid[screenRow]
                let end = min(screenColumn + amount, screenColumns)
                if screenColumn > row.count {
                    row.append(contentsOf: repeatElement(TerminalCell(char: " "), count: screenColumn - row.count))
                }
                while row.count < end {
                    row.append(TerminalCell(char: " "))
                }
                for c in screenColumn..<min(end, row.count) {
                    clearGlyph(in: &row, at: c)
                    row[c] = styledCell(" ")
                }
                grid[screenRow] = row
                screen = grid; _screenRevision += 1
            }
        case "s":
            savedScreenPosition = (screenRow, screenColumn)
        case "u":
            if let saved = savedScreenPosition {
                screenRow = min(screenRows - 1, max(0, saved.0))
                screenColumn = min(screenColumns - 1, max(0, saved.1))
                _screenRevision += 1
            }
        default: break
        }
    }
    
    private func handleCSI(finalChar: Character, param: String) {
        defer {
            if "JKP@X".contains(finalChar) { normalizeWideCells(&activeCells) }
        }
        switch finalChar {
        case "h":
            if param == "?2004" {
                _isBracketedPasteEnabled = true
            }
        case "l":
            if param == "?2004" {
                _isBracketedPasteEnabled = false
            }
        case "m": // SGR Color & Style
            var style = currentStyle
            style.apply(param: param)
            currentStyle = style
        case "J": // Erase in Display
            let mode = Int(param) ?? 0
            if mode == 0 {
                ensureEditingMode()
                if cursorCol < activeCells.count {
                    activeCells.removeSubrange(cursorCol..<activeCells.count)
                }
                belowActiveRows.removeAll(keepingCapacity: true)
            } else if mode == 2 || mode == 3 {
                head = 0
                count = 0
                _totalCommittedCount = 0
                _minRewoundCommittedCount = nil
                activeLine = ""
                activeCells.removeAll(keepingCapacity: true)
                belowActiveRows.removeAll(keepingCapacity: true)
                isEditingActiveLine = false
                cursorCol = 0
                shellIntegration.reset()
                _isClearPending = true
            }
        case "K": // Erase in Line
            if param.isEmpty || param == "0" {
                // Erase from cursor to end of line
                if cursorCol < activeCells.count {
                    activeCells.removeSubrange(cursorCol..<activeCells.count)
                }
            } else if param == "1" {
                // Erase from start of line to cursor
                let limit = min(cursorCol + 1, activeCells.count)
                for k in 0..<limit {
                    activeCells[k] = TerminalCell(char: " ", fgHex: nil, isBold: false)
                }
            } else if param == "2" {
                // Erase entire line
                activeCells.removeAll(keepingCapacity: true)
            }
        case "C": // Cursor Forward (Right)
            let n = max(1, Int(param) ?? 1)
            cursorCol += n
        case "D": // Cursor Backward (Left)
            let n = max(1, Int(param) ?? 1)
            cursorCol = max(0, cursorCol - n)
        case "A": // Cursor Up
            moveNormalCursorUp(max(1, Int(param) ?? 1))
        case "B": // Cursor Down
            moveNormalCursorDown(max(1, Int(param) ?? 1))
        case "E": // Cursor Next Line
            moveNormalCursorDown(max(1, Int(param) ?? 1))
            cursorCol = 0
        case "F": // Cursor Previous Line
            moveNormalCursorUp(max(1, Int(param) ?? 1))
            cursorCol = 0
        case "G": // Cursor Horizontal Absolute
            let col = max(1, Int(param) ?? 1)
            cursorCol = max(0, col - 1)
        case "H", "f": // Cursor Position
            if param.contains(";") {
                let parts = param.split(separator: ";")
                if parts.count >= 2, let col = Int(parts[1]) {
                    cursorCol = max(0, col - 1)
                }
            } else {
                cursorCol = 0
            }
        case "@": // Insert Character (ICH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol > activeCells.count {
                let pad = cursorCol - activeCells.count
                activeCells.append(contentsOf: repeatElement(TerminalCell(char: " ", fgHex: nil, isBold: false), count: pad))
            }
            let blanks = Array(repeating: styledCell(" "), count: n)
            activeCells.insert(contentsOf: blanks, at: min(cursorCol, activeCells.count))
        case "P": // Delete Character (DCH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol < activeCells.count {
                let toRemove = min(n, activeCells.count - cursorCol)
                activeCells.removeSubrange(cursorCol..<(cursorCol + toRemove))
            }
        case "X": // Erase Character (ECH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol < activeCells.count {
                let toErase = min(n, activeCells.count - cursorCol)
                for k in cursorCol..<(cursorCol + toErase) {
                    activeCells[k] = TerminalCell(char: " ", fgHex: nil, isBold: false)
                }
            }
        default:
            break
        }
    }
    
    private func commitActiveLine() {
        if isEditingActiveLine {
            let line = renderCellsToString(activeCells, trimAfterColumn: cursorCol)
            commitFastLine(line)
            if !belowActiveRows.isEmpty {
                activeCells = belowActiveRows.removeFirst()
                cursorCol = 0
            } else {
                activeCells.removeAll(keepingCapacity: true)
                isEditingActiveLine = false
                cursorCol = 0
            }
        } else {
            commitFastLine(activeLine)
            activeLine = ""
        }
    }
    
    private func commitFastLine(_ line: String) {
        let index = (head + count) % historyLimit
        if count < historyLimit {
            buffer[index] = line
            count += 1
        } else {
            buffer[head] = line
            head = (head + 1) % historyLimit
        }
        _totalCommittedCount += 1
    }
    
    private func renderCellsToString(_ cells: [TerminalCell], trimAfterColumn: Int = 0) -> String {
        // Trim trailing erasure spaces at or past cursorCol (e.g. from \b \b or erase operations)
        var effectiveCount = cells.count
        while effectiveCount > trimAfterColumn && cells[effectiveCount - 1].char == " " && !cells[effectiveCount - 1].isContinuation && cells[effectiveCount - 1].style.background == nil && cells[effectiveCount - 1].style.backgroundIndex == nil && !cells[effectiveCount - 1].style.inverse {
            effectiveCount -= 1
        }
        guard effectiveCount > 0 else { return "" }
        var result = ""
        result.reserveCapacity(effectiveCount + 16)
        let defaultStyle = SGRStyle(foreground: nil, index: nil, bold: false)
        var previousStyle = defaultStyle
        for cell in cells.prefix(effectiveCount) where !cell.isContinuation {
            let style = cell.style
            if style != previousStyle {
                result.append(style.escapeSequence)
                previousStyle = style
            }
            result.append(cell.char)
        }
        if previousStyle != defaultStyle { result.append("\u{1B}[0m") }
        return result
    }
    
    /// Append a single line into circular buffer
    public func appendLine(_ line: String) {
        lock.lock()
        commitFastLine(line)
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
    
    /// Append multiple lines
    public func appendLines(_ lines: [String]) {
        lock.lock()
        for line in lines {
            let index = (head + count) % historyLimit
            if count < historyLimit {
                buffer[index] = line
                count += 1
            } else {
                buffer[head] = line
                head = (head + 1) % historyLimit
            }
        }
        _totalCommittedCount += Int64(lines.count)
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
    
    /// Return all active lines in chronological order
    public func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        let trailing = activeRenderedLines()
        var result = [String]()
        result.reserveCapacity(count + trailing.count)
        for i in 0..<count {
            let index = (head + i) % historyLimit
            result.append(buffer[index])
        }
        result.append(contentsOf: trailing)
        return result
    }
    
    /// Return lines from offset to count for incremental rendering
    public func lines(from start: Int, count requestedCount: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        guard start >= 0, start < count, requestedCount > 0 else { return [] }
        let available = count - start
        let fetchCount = min(requestedCount, available)
        var result = [String]()
        result.reserveCapacity(fetchCount)
        for i in 0..<fetchCount {
            let index = (head + start + i) % historyLimit
            result.append(buffer[index])
        }
        return result
    }
    
    /// Get the total number of lines in the buffer
    public var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count + activeRenderedLines().count
    }
    
    /// Returns the number of backing array slots currently holding non-empty strings (for memory reclamation verification).
    public var nonEmptyBackingSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
    }

    private func resetTerminalState() {
        head = 0; count = 0; _totalCommittedCount = 0; _minRewoundCommittedCount = nil
        buffer = [String](repeating: "", count: historyLimit)
        activeLine = ""; activeCells.removeAll(keepingCapacity: false)
        belowActiveRows.removeAll(keepingCapacity: false)
        isEditingActiveLine = false; cursorCol = 0
        currentStyle = SGRStyle(foreground: nil, index: nil, bold: false)
        savedNormalStyle = nil
        pendingSequence = ""; screen = nil
        screenRow = 0; screenColumn = 0
        scrollTop = 0; scrollBottom = screenRows - 1
        savedScreenPosition = nil
        _isCursorHidden = false; _isApplicationCursorKeys = false
        _isBracketedPasteEnabled = false; _mouseTrackingMode = 0; _isSGRMouseEnabled = false
        _isBellPending = false
        _isSynchronizedOutputActive = false
        _syncOutputStartedAt = nil
        shellIntegration.reset()
        _screenRevision += 1; _isClearPending = true
    }

    /// Clear all lines and immediately release backing scrollback string memory
    public func clear() {
        lock.lock()
        head = 0
        count = 0
        _totalCommittedCount = 0
        _minRewoundCommittedCount = nil
        buffer = [String](repeating: "", count: historyLimit)
        activeLine = ""
        activeCells.removeAll(keepingCapacity: false)
        belowActiveRows.removeAll(keepingCapacity: false)
        isEditingActiveLine = false
        cursorCol = 0
        pendingSequence = ""
        currentStyle = SGRStyle(foreground: nil, index: nil, bold: false)
        savedNormalStyle = nil
        _isBellPending = false
        _isClearPending = true
        _isSynchronizedOutputActive = false
        _syncOutputStartedAt = nil
        shellIntegration.reset()
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }

    /// Extracts plain-text output for a specific OSC 133 `CommandExecutionRecord` from the current buffer window.
    public func extractOSC133CommandOutput(for record: CommandExecutionRecord) -> String? {
        lock.lock()
        let totalCommitted = Int(_totalCommittedCount)
        let retainedCount = count
        let oldestLifetimeIndex = max(0, totalCommitted - retainedCount)
        let startIdx = max(0, record.outputStartLine - oldestLifetimeIndex)
        let rawEndLifetime = record.outputEndLine ?? totalCommitted
        let endIdx = min(retainedCount, max(startIdx, rawEndLifetime - oldestLifetimeIndex))
        guard startIdx < endIdx else {
            lock.unlock()
            return nil
        }
        var rawLines: [String] = []
        rawLines.reserveCapacity(endIdx - startIdx)
        for offset in startIdx..<endIdx {
            let bufIndex = (head + offset) % historyLimit
            rawLines.append(buffer[bufIndex])
        }
        lock.unlock()

        let cleaned = rawLines.map { line in
            vtParser.parseANSI(line).map(\.text).joined()
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Extracts plain-text output for the most recent completed OSC 133 command execution record.
    public func extractLastOSC133CommandOutput() -> String? {
        guard let last = shellIntegration.lastCompletedRecord else { return nil }
        return extractOSC133CommandOutput(for: last)
    }
}
