import Foundation
import ApexCore
import ApexSSH

final class EchoProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var expected = ""
    private var text = ""
    private var started: UInt64 = 0
    private var elapsed: Double?
    func arm(_ marker: String) { lock.withLock { expected = marker; text = ""; elapsed = nil; started = DispatchTime.now().uptimeNanoseconds } }
    func append(_ data: Data) {
        lock.withLock {
            text += String(decoding: data, as: UTF8.self)
            if !expected.isEmpty && elapsed == nil && text.contains(expected) {
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            }
            if text.count > 8192 { text = String(text.suffix(4096)) }
        }
    }
    var result: Double? { lock.withLock { elapsed } }
}

@main struct MeasurePTYEcho {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["APEX_TEST_VM_HOST"], let user = env["APEX_TEST_VM_USER"] else {
            throw NSError(domain: "PTYProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Set APEX_TEST_VM_HOST and APEX_TEST_VM_USER"])
        }
        let session = Session(name: "latency-probe", host: host, username: user,
                              authMethod: .password(keychainRef: ""), agentlessMonitorEnabled: false)
        let client = NativeSSHSession(session: session)
        let probe = EchoProbe()
        client.setOutputHandler { probe.append($0) }
        try await client.connect()
        try await Task.sleep(for: .seconds(2))
        // Disable remote input echo: markers must come from the shell command's output.
        try await client.sendInput(Data("stty -echo\r".utf8))
        try await Task.sleep(for: .milliseconds(300))
        var samples: [Double] = []
        for index in 0..<110 {
            let marker = "APEX_ECHO_\(UUID().uuidString)"
            probe.arm(marker)
            try await client.sendInput(Data("printf '%s\\n' '\(marker)'\r".utf8))
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while probe.result == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .microseconds(250)) }
            guard let elapsed = probe.result else {
                await client.disconnect()
                throw NSError(domain: "PTYProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "PTY roundtrip timed out"])
            }
            if index >= 10 { samples.append(elapsed) }
            try await Task.sleep(for: .milliseconds(20))
        }
        await client.disconnect()
        let sorted = samples.sorted()
        let report: [String: Any] = ["sampleCount": samples.count, "warmupCount": 10,
            "p50Milliseconds": sorted[(sorted.count - 1) / 2], "p95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "maxMilliseconds": sorted.last!, "samplesMilliseconds": samples,
            "scope": "NativeSSHSession sendInput to remote PTY command output callback; excludes terminal display frame"]
        let output = env["APEX_PTY_REPORT"] ?? "outputs/macos27/pty-echo.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("PTY output roundtrips: \(samples.count), P50 \(report["p50Milliseconds"]!) ms, P95 \(report["p95Milliseconds"]!) ms")
    }
}
