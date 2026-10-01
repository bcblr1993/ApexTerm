import Foundation

/// Terminal columns for a grapheme, independent of the process's C locale.
enum TerminalCharacterWidth {
    static func columns(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let base = scalars.first else { return 0 }
        if scalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .enclosingMark || $0.value == 0x200D }) { return 0 }
        if scalars.contains(where: { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }) { return 2 }
        let value = base.value
        if (0x1100...0x115F).contains(value) || value == 0x2329 || value == 0x232A ||
           (0x2E80...0xA4CF).contains(value) && value != 0x303F ||
           (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) ||
           (0xFE10...0xFE19).contains(value) || (0xFE30...0xFE6F).contains(value) ||
           (0xFF00...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value) ||
           (0x20000...0x3FFFD).contains(value) { return 2 }
        return 1
    }
}
