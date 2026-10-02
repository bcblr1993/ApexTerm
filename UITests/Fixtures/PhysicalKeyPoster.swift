// Test-only physical keys for the real system IME. Never bundled with ApexTerm.
import AppKit
import CoreGraphics
import Darwin

@main
struct PhysicalKeyPoster {
    @MainActor
    static func main() {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0 else { exit(64) }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0,
              String(decoding: model.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("VirtualMac") else {
            fputs("Physical IME fixture requires the dedicated macOS VM.\n", stderr)
            exit(64)
        }
        guard CGPreflightPostEventAccess() else {
            fputs("Physical IME fixture requires Accessibility permission in the test VM.\n", stderr)
            exit(77)
        }
        guard CommandLine.arguments.count == 2 else { exit(64) }
        if CommandLine.arguments[1] == "--preflight" {
            print("APEX_PHYSICAL_KEY_OK --preflight")
            exit(0)
        }
        let keys: [CGKeyCode]
        switch CommandLine.arguments[1] {
        case "pinyin": keys = [6, 4, 31, 45, 5, 13, 14, 45] // zhongwen
        case "escape": keys = [53]
        case "space": keys = [49]
        case "return": keys = [36]
        default: exit(64)
        }
        guard let source = CGEventSource(stateID: .privateState) else { exit(70) }
        for key in keys {
            guard let target = ProcessInfo.processInfo.environment["APEX_UI_PHYSICAL_KEY_TARGET"],
                  target.hasPrefix("com.apexterm.qa.verification."),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target else {
                fputs("Physical IME fixture only targets the foreground isolated QA app.\n", stderr)
                exit(65)
            }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { exit(70) }
                event.flags = []
                event.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("APEX_PHYSICAL_KEY_OK \(CommandLine.arguments[1])")
    }
}
