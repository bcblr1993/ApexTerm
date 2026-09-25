import XCTest
import Darwin
import MachO
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

final class FullPerformanceBenchmarkTests: XCTestCase {
    
    private func getResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
    
    /// 1. 终端环形缓冲区 100,000 行超高吞吐测试
    func testBenchmark1_RingBufferThroughputAndLatency() {
        let maxLines = 10_000
        let ringBuffer = TerminalRingBuffer(maxLines: maxLines)
        
        let lineCount = 100_000
        let sampleLine = "2026-09-25T16:58:00.123Z [INFO] worker-pool-42 [tid=9821]: HTTP request 200 OK duration=4.2ms bytes=14502\n"
        let sampleBytes = sampleLine.utf8.count
        let totalBytes = sampleBytes * lineCount
        
        // Prepare batches to simulate real socket chunk reads
        let batchSize = 1000
        var batchChunk = ""
        batchChunk.reserveCapacity(sampleBytes * batchSize)
        for _ in 0..<batchSize {
            batchChunk += sampleLine
        }
        let totalBatches = lineCount / batchSize
        
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<totalBatches {
            ringBuffer.appendStream(batchChunk)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let linesPerSec = Double(lineCount) / elapsed
        let mbPerSec = (Double(totalBytes) / (1024 * 1024)) / elapsed
        let latencyPerLineNs = (elapsed / Double(lineCount)) * 1_000_000_000
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 1] 终端日志写入与吞吐性能测试 (RingBuffer)")
        print("  - 总写入行数:     \(lineCount) 行")
        print("  - 数据吞吐量:     \(String(format: "%.2f", Double(totalBytes) / (1024 * 1024))) MB")
        print("  - 总耗时:         \(String(format: "%.4f", elapsed)) 秒")
        print("  - 吞吐速率:       \(String(format: "%.0f", linesPerSec)) 行/秒 (\(String(format: "%.2f", mbPerSec)) MB/秒)")
        print("  - 单行平均耗时:   \(String(format: "%.1f", latencyPerLineNs)) 纳秒 (ns)")
        print("=======================================================\n")
        
        XCTAssertEqual(ringBuffer.committedLineCount, maxLines)
        XCTAssertEqual(ringBuffer.totalCommittedCount, Int64(lineCount))
        #if DEBUG
        XCTAssertGreaterThan(linesPerSec, 30_000, "Throughput should exceed 30,000 lines/sec in unoptimized debug build")
        #else
        XCTAssertGreaterThan(linesPerSec, 80_000, "Throughput should exceed 80,000 lines/sec")
        #endif
    }
    
    /// 2. VTParser 24-bit TrueColor 与 256 颜色极速解析性能
    func testBenchmark2_VTParserColorParsingThroughput() {
        let parser = VTParser()
        let count = 10_000
        
        var stream = ""
        stream.reserveCapacity(count * 45)
        for i in 0..<count {
            let r = i % 256
            let g = (i * 3) % 256
            let b = (i * 7) % 256
            stream += "\u{001B}[38;2;\(r);\(g);\(b)m[Span-\(i)]\u{001B}[0m "
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        let spans = parser.parseANSI(stream)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let spansPerSec = Double(spans.count) / elapsed
        let microsecPerSpan = (elapsed / Double(spans.count)) * 1_000_000
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 2] ANSI / TrueColor 颜色序列解析性能")
        print("  - 解析 Span 数:   \(spans.count) spans")
        print("  - 总耗时:         \(String(format: "%.4f", elapsed)) 秒")
        print("  - 解析速度:       \(String(format: "%.0f", spansPerSec)) spans/秒")
        print("  - 单 Span 延迟:   \(String(format: "%.3f", microsecPerSpan)) 微秒 (μs)")
        print("=======================================================\n")
        
        XCTAssertGreaterThan(spans.count, count)
        XCTAssertGreaterThan(spansPerSec, 50_000, "ANSI parser should exceed 50,000 spans/sec")
    }
    
    /// 3. 内存驻留集 (RSS) 与防暴涨安全水位测试 (Memory Bounds)
    @MainActor
    func testBenchmark3_MemoryFootprintAndBoundedRetention() {
        let initialRss = getResidentMemoryBytes()
        
        let ringBuffer = TerminalRingBuffer(maxLines: 50_000)
        let view = NativeTerminalView()
        view.ringBuffer = ringBuffer
        
        // Feed 100,000 lines of logs into the terminal view
        let sample = "2026-09-25T16:58:00 [DEBUG] Cluster node worker telemetry heartbeat ok status=UP\n"
        for _ in 0..<100 {
            var chunk = ""
            chunk.reserveCapacity(sample.utf8.count * 1000)
            for _ in 0..<1000 {
                chunk += sample
            }
            ringBuffer.appendStream(chunk)
            view.refresh()
        }
        
        let peakRss = getResidentMemoryBytes()
        let textStorageLen = view.textStorage?.length ?? 0
        let rssMB = Double(peakRss) / (1024 * 1024)
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 3] 内存驻留集 (RSS) 与字符截断水位测试")
        print("  - 初始内存 (RSS): \(String(format: "%.2f", Double(initialRss) / (1024 * 1024))) MB")
        print("  - 峰值内存 (RSS): \(String(format: "%.2f", rssMB)) MB")
        print("  - 存储字符长度:   \(textStorageLen) 字符 (熔断上限: 2,500,000)")
        print("=======================================================\n")
        
        // Memory guard must prevent infinite growth
        XCTAssertLessThanOrEqual(textStorageLen, 2_600_000, "TextStorage should be strictly bounded")
        let growthMB = Double(max(0, peakRss - initialRss)) / (1024 * 1024)
        XCTAssertLessThan(growthMB, 100.0, "Memory growth under 100K-line burst should be well under 100MB")
        XCTAssertLessThan(rssMB, 180.0, "Total process RSS should remain lightweight")
    }
    
    /// 4. 16 线程高并发争用写入性能测试 (Concurrent Contention)
    func testBenchmark4_ConcurrentWritesLockContention() {
        let ringBuffer = TerminalRingBuffer(maxLines: 50_000)
        let threadCount = 16
        let writesPerThread = 2_000
        let totalWrites = threadCount * writesPerThread
        
        let group = DispatchGroup()
        let start = CFAbsoluteTimeGetCurrent()
        
        for t in 0..<threadCount {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                for i in 0..<writesPerThread {
                    ringBuffer.appendLine("Thread-\(t)-Line-\(i)")
                }
                group.leave()
            }
        }
        
        group.wait()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let writesPerSec = Double(totalWrites) / elapsed
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 4] 16 线程高并发锁争用写入测试")
        print("  - 并发线程数:     \(threadCount) 线程")
        print("  - 总并发写入量:   \(totalWrites) 次")
        print("  - 总耗时:         \(String(format: "%.4f", elapsed)) 秒")
        print("  - 并发写入吞吐:   \(String(format: "%.0f", writesPerSec)) writes/秒")
        print("=======================================================\n")
        
        XCTAssertEqual(ringBuffer.totalCommittedCount, Int64(totalWrites))
        XCTAssertGreaterThan(writesPerSec, 50_000, "Concurrent throughput under lock should exceed 50,000/s")
    }
    
    /// 5. 无代理监控解析耗时极速压测 (Agentless Monitor Parsing Speed)
    func testBenchmark5_AgentlessMetricsParsingSpeed() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 850000, total: 900000)
        var prevNet: AgentlessMonitor.NetTickState? = AgentlessMonitor.NetTickState(rx: 100000000, tx: 50000000)
        
        // 64-core Linux cluster output
        var lines = ["cpu  50000 2000 40000 900000 1000 500 200 0 0 0"]
        for c in 0..<64 {
            lines.append("cpu\(c) 800 30 600 14000 15 8 3 0 0 0")
        }
        lines.append("MemTotal:      131072000 kB\nMemFree:        32000000 kB\nMemAvailable:  90000000 kB\nBuffers: 2000000 kB\nCached: 40000000 kB")
        lines.append("eth0: 5000000000 3500000 0 0 0 0 0 0 2500000000 1800000 0 0 0 0 0 0")
        lines.append("---DF---\n/dev/sda1 1048576000 314572800 734003200 30% /\n---UPTIME---\n864000.00 55296000.00\n---LOAD---\n1.25 0.95 0.72 2/850 12345")
        let sample = lines.joined(separator: "\n")
        
        let iterations = 2000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = monitor.parseLinuxOutput(sample, prevCpu: &prevCpu, prevNet: &prevNet)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let parsesPerSec = Double(iterations) / elapsed
        let microsecPerParse = (elapsed / Double(iterations)) * 1_000_000
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 5] 64 核 Linux 无代理系统指标解析速度")
        print("  - 测试采样轮次:   \(iterations) 轮")
        print("  - 总耗时:         \(String(format: "%.4f", elapsed)) 秒")
        print("  - 解析速度:       \(String(format: "%.0f", parsesPerSec)) 次/秒")
        print("  - 单次解析延迟:   \(String(format: "%.2f", microsecPerParse)) 微秒 (μs)")
        print("=======================================================\n")
        
        XCTAssertLessThan(microsecPerParse, 500.0, "Average parse latency must be under 500 microseconds")
    }
    
    /// 6. OpenSSH 配置文件解析吞吐测试
    func testBenchmark6_SSHConfigParserSpeed() {
        var configText = ""
        let hostCount = 500
        for i in 0..<hostCount {
            configText += """
            Host srv-\(i) api-\(i).internal
                HostName 10.100.\(i / 255).\(i % 255)
                User admin
                Port \(2000 + i % 100)
                IdentityFile "~/.ssh/keys/id_rsa_\(i)"
            
            """
        }
        
        let iterations = 50
        let start = CFAbsoluteTimeGetCurrent()
        var totalParsed = 0
        for _ in 0..<iterations {
            let hosts = SSHConfigParser.parse(content: configText)
            totalParsed += hosts.count
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let hostsPerSec = Double(totalParsed) / elapsed
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 6] OpenSSH 配置批量解析吞吐 (500 主机集群)")
        print("  - 解析主机总数:   \(totalParsed) 主机项")
        print("  - 总耗时:         \(String(format: "%.4f", elapsed)) 秒")
        print("  - 解析速率:       \(String(format: "%.0f", hostsPerSec)) hosts/秒")
        print("=======================================================\n")
        
        XCTAssertGreaterThan(hostsPerSec, 20_000, "Should parse at least 20,000 hosts per second")
    }
    
    /// 7. 传输任务中心 100 任务并发调度耗时测试
    @MainActor
    func testBenchmark7_TransferManagerSchedulingOverhead() async throws {
        let manager = TransferManager()
        let session = MockSSHSession(session: Session(name: "bench", host: "127.0.0.1", username: "root"))
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("bench_file_\(UUID().uuidString)")
        try "benchmark payload".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let taskCount = 100
        var expectations: [XCTestExpectation] = []
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<taskCount {
            let exp = expectation(description: "Task \(i)")
            expectations.append(exp)
            manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/tmp/b_\(i)") {
                exp.fulfill()
            }
        }
        
        await fulfillment(of: expectations, timeout: 5.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let tasksPerSec = Double(taskCount) / elapsed
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 7] SFTP 任务中心 100 任务并发调度性能")
        print("  - 并发任务数:     \(taskCount) 个")
        print("  - 调度完成总耗时: \(String(format: "%.4f", elapsed)) 秒")
        print("  - 处理吞吐量:     \(String(format: "%.0f", tasksPerSec)) tasks/秒")
        print("=======================================================\n")
        
        XCTAssertEqual(manager.activeCount, 0)
    }
    
    /// 8. 终端打字输入延迟与活跃行渲染性能基准测试
    @MainActor
    func testBenchmark8_KeystrokeTypingLatencyAndRenderingOverhead() {
        let session = MockSSHSession(session: Session(name: "typing_bench", host: "127.0.0.1", username: "root"))
        let ringBuffer = TerminalRingBuffer(maxLines: 50_000)
        let terminalView = NativeTerminalView()
        terminalView.ringBuffer = ringBuffer
        
        session.setOutputHandler { data in
            if let text = String(data: data, encoding: .utf8) {
                ringBuffer.appendStream(text)
            }
        }
        
        let keystrokeCount = 10_000
        let testKeystrokes = "abcdefghijklmnopqrstuvwxyz0123456789 -la\n".map { String($0) }
        
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<keystrokeCount {
            let key = testKeystrokes[i % testKeystrokes.count]
            if let data = key.data(using: .utf8) {
                session.sendInputSync(data)
            }
            if i % 100 == 0 {
                terminalView.refresh()
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        let keysPerSec = Double(keystrokeCount) / elapsed
        let microsecPerKey = (elapsed / Double(keystrokeCount)) * 1_000_000
        
        print("\n=======================================================")
        print("📊 [BENCHMARK 8] 终端物理按键直通与微秒级打字延迟基准")
        print("  - 模拟按键写入数: \(keystrokeCount) 次")
        print("  - 端到端总耗时:   \(String(format: "%.4f", elapsed)) 秒")
        print("  - 键入吞吐速率:   \(String(format: "%.0f", keysPerSec)) keys/秒")
        print("  - 单键平均全链路: \(String(format: "%.2f", microsecPerKey)) 微秒 (μs)")
        print("=======================================================\n")
        
        // Ensure single keystroke latency is well below 1 millisecond (1000 microseconds)
        XCTAssertLessThan(microsecPerKey, 500.0, "Keystroke pipeline latency must be under 500 microseconds (0.5ms)")
    }
}

