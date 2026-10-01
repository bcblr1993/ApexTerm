// Restores only input sources temporarily created by the real-IME UI fixture.
import Carbon
import Foundation
func identifier(_ source: TISInputSource) -> String {
    Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}
func enabled() -> Set<String> {
    guard let list = TISCreateInputSourceList(nil, false) else { return [] }
    return Set((list.takeRetainedValue() as NSArray).map { identifier($0 as! TISInputSource) })
}
func source(_ id: String) -> TISInputSource? {
    guard let list = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true),
          let object = (list.takeRetainedValue() as NSArray).firstObject else { return nil }
    return (object as! TISInputSource)
}
guard CommandLine.arguments.count == 2 else { exit(64) }
if CommandLine.arguments[1] == "--snapshot" {
    guard let current = TISCopyCurrentKeyboardInputSource() else { exit(4) }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: [
        "enabled": Array(enabled()), "selected": identifier(current.takeRetainedValue())]))
    exit(0)
}
guard let data = Data(base64Encoded: CommandLine.arguments[1]),
      let configuration = try JSONSerialization.jsonObject(with: data) as? [Any], configuration.count == 2,
      let originalID = configuration[0] as? String,
      let originalEnabled = configuration[1] as? [String] else { exit(64) }
let baseline = Set(originalEnabled)
for _ in 0..<4 {
    for id in baseline.subtracting(enabled()) {
        if let input = source(id) { guard TISEnableInputSource(input) == noErr else { exit(5) } }
    }
    if let original = source(originalID) { guard TISSelectInputSource(original) == noErr else { exit(2) } }
    let added = enabled().subtracting(baseline).filter {
        $0 == "com.apple.keylayout.PinyinKeyboard" || $0 == "com.apple.inputmethod.SCIM" || $0.hasPrefix("com.apple.inputmethod.SCIM.")
    }.sorted { $0.count > $1.count }
    for id in added {
        if let input = source(id) { guard TISDisableInputSource(input) == noErr else { exit(3) } }
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
}
guard let current = TISCopyCurrentKeyboardInputSource() else { exit(4) }
let result: [String: Any] = ["enabled": Array(enabled()), "selected": identifier(current.takeRetainedValue())]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
