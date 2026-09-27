import AppKit
import Darwin
import MachO

// QA bundles live under <repository>/outputs/macos27/qa; Finder launches need no working-directory assumption.
let qaRepositoryRoot: URL = (0..<4).reduce(Bundle.main.bundleURL) { url, _ in url.deletingLastPathComponent() }

@MainActor
final class QAProcessTelemetry {
    private var timer: Timer?
    private var samples: [[String: Any]] = []
    private let started = ProcessInfo.processInfo.systemUptime
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }
    private func sample() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.contentView != nil }
        samples.append(["elapsed": ProcessInfo.processInfo.systemUptime - started,
                        "cpuSeconds": cpu, "rssMB": result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0,
                        "keyWindow": windows.contains { $0.isKeyWindow },
                        "appActive": NSApplication.shared.isActive,
                        "firstResponderClass": NSApplication.shared.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                        "windowCount": windows.count])
        let path = ProcessInfo.processInfo.environment["APEX_QA_TELEMETRY"]
            ?? qaRepositoryRoot.appendingPathComponent("outputs/macos27/qa/telemetry-\(Bundle.main.bundleIdentifier ?? "app").json").path
        let file = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
