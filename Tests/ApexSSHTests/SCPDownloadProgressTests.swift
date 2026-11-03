import Foundation
import XCTest
@testable import ApexSSH

/// scp streams straight into the destination file and says nothing on stdout, so download progress
/// is derived by sampling the destination size on a timer. MockSSHSession synthesises fractions,
/// which is exactly why a "stuck at 0% then jumps to done" regression stayed invisible behind 487
/// green tests. These cases pin the sampling maths that the real transport now depends on.
final class SCPDownloadProgressTests: XCTestCase {

    /// The sampler must emit intermediate fractions while the destination is still filling, which is
    /// what the transfer drawer renders as a live percentage and speed.
    func testSamplerReportsIntermediateFractionsWhileDestinationGrows() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-progress-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let totalBytes: Int64 = 40_000
        let collector = ProgressCollector()
        let sampler = NativeSSHSession.makeFileSizeSampler(
            path: destination.path,
            totalBytes: totalBytes,
            progress: { collector.record($0) }
        )
        defer { sampler.cancel() }

        // Mimic scp creating the destination and appending the stream while the sampler is running.
        _ = FileManager.default.createFile(atPath: destination.path, contents: Data())
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        for _ in 0..<4 {
            try handle.write(contentsOf: Data(count: 10_000))
            try await Task.sleep(for: .milliseconds(260))
        }
        // One more tick so the completed destination is sampled before the sampler is torn down.
        try await Task.sleep(for: .milliseconds(260))

        let fractions = collector.fractions
        XCTAssertGreaterThan(fractions.count, 1, "Sampler must report intermediate progress, not just the terminal 1.0")
        XCTAssertEqual(fractions, fractions.sorted(), "Progress must never walk backwards")
        XCTAssertEqual(collector.maximum, 1.0, accuracy: 0.001, "A fully written destination must reach 100%")

        // Cancel and join before returning. The defer above only signals; without the join a
        // detached sampler can outlive the test and race the rest of the suite.
        sampler.cancel()
        await sampler.value
    }

    /// An unknown remote size cannot produce a meaningful fraction, so the sampler must stay silent
    /// instead of inventing progress that the drawer would render against a 0-byte total.
    func testSamplerStaysSilentWhenRemoteSizeIsUnknown() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-unknown-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data(count: 5_000).write(to: destination)

        let collector = ProgressCollector()
        let sampler = NativeSSHSession.makeFileSizeSampler(
            path: destination.path,
            totalBytes: 0,
            progress: { collector.record($0) }
        )
        await sampler.value

        XCTAssertTrue(collector.fractions.isEmpty, "An unknown total cannot produce a meaningful fraction")
    }

    /// scp creates the destination lazily, so a missing file is normal rather than an error.
    func testCurrentFileSizeReportsNilBeforeScpCreatesTheDestination() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(NativeSSHSession.currentFileSize(atPath: missing.path))
    }
}

/// Thread-safe sink for sampler callbacks, which arrive off the main actor.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ fraction: Double) {
        lock.withLock { storage.append(fraction) }
    }

    var fractions: [Double] { lock.withLock { storage } }
    var maximum: Double { fractions.max() ?? 0 }
}