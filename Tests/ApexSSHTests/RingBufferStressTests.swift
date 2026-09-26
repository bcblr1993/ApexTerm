import XCTest
@testable import ApexTerminal

final class RingBufferStressTests: XCTestCase {
    
    /// Test 1: Rapid 100,000-line streaming throughput and monotonic total counter
    func testHighThroughputStreaming100KLines() {
        let maxWindow = 5000
        let ringBuffer = TerminalRingBuffer(maxLines: maxWindow)
        
        final class SafeCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func inc() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        
        let counter = SafeCounter()
        ringBuffer.onUpdate = {
            counter.inc()
        }
        
        let totalLinesToFeed = 100_000
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Feed in batches of 1,000 lines
        let batchSize = 1000
        let batches = totalLinesToFeed / batchSize
        for b in 0..<batches {
            var chunk = ""
            chunk.reserveCapacity(batchSize * 30)
            for i in 0..<batchSize {
                let lineNum = b * batchSize + i
                chunk += "Log message #\(lineNum): [INFO] Worker process heartbeat ok\n"
            }
            ringBuffer.appendStream(chunk)
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        // Verify line counts
        XCTAssertEqual(ringBuffer.committedLineCount, maxWindow, "Circular window should be saturated at maxLines")
        XCTAssertEqual(ringBuffer.totalCommittedCount, Int64(totalLinesToFeed), "Lifetime committed count must track all 100K lines monotonically")
        XCTAssertGreaterThan(counter.value, 0, "Update notifications must fire")
        
        // Verify tail lines
        let tail = ringBuffer.tailLines(count: 3)
        XCTAssertEqual(tail.count, 3)
        XCTAssertEqual(tail[0], "Log message #99997: [INFO] Worker process heartbeat ok")
        XCTAssertEqual(tail[1], "Log message #99998: [INFO] Worker process heartbeat ok")
        XCTAssertEqual(tail[2], "Log message #99999: [INFO] Worker process heartbeat ok")
        
        // Performance assert: 100,000 lines processed in under 2.5 seconds
        PerformanceThreshold.assertLessThan(elapsed, 2.5, "100K lines streaming should complete rapidly")
    }
    
    /// Test 2: Wrap-around accuracy across multiple circular buffer cycles
    func testCircularWrapAroundAccuracy() {
        let ringBuffer = TerminalRingBuffer(maxLines: 5)
        
        for i in 1...23 {
            ringBuffer.appendLine("entry-\(i)")
            XCTAssertEqual(ringBuffer.totalCommittedCount, Int64(i))
        }
        
        XCTAssertEqual(ringBuffer.committedLineCount, 5)
        let all = ringBuffer.allLines()
        XCTAssertEqual(all, ["entry-19", "entry-20", "entry-21", "entry-22", "entry-23"])
        
        // tailLines corner cases
        XCTAssertEqual(ringBuffer.tailLines(count: 0), [])
        XCTAssertEqual(ringBuffer.tailLines(count: 2), ["entry-22", "entry-23"])
        XCTAssertEqual(ringBuffer.tailLines(count: 10), ["entry-19", "entry-20", "entry-21", "entry-22", "entry-23"])
    }
    
    /// Test 3: Concurrent write stress from multiple background threads
    func testConcurrentMultiThreadWrites() {
        let ringBuffer = TerminalRingBuffer(maxLines: 10_000)
        let threadCount = 8
        let writesPerThread = 1_000
        let group = DispatchGroup()
        
        for threadIdx in 0..<threadCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<writesPerThread {
                    ringBuffer.appendLine("T\(threadIdx)-\(i)")
                }
                group.leave()
            }
        }
        
        let waitResult = group.wait(timeout: .now() + 5.0)
        XCTAssertEqual(waitResult, .success, "Concurrent writes must complete without deadlocks")
        
        XCTAssertEqual(ringBuffer.totalCommittedCount, Int64(threadCount * writesPerThread))
        XCTAssertEqual(ringBuffer.committedLineCount, min(10_000, threadCount * writesPerThread))
    }
    
    /// Test 4: Escape sequence torture test (fragmented ANSI codes across chunk boundaries)
    func testFragmentedAnsiCodesAcrossStreamChunks() {
        let ringBuffer = TerminalRingBuffer(maxLines: 50)
        
        // Part 1: Start of ESC sequence "\u{001B}[3"
        ringBuffer.appendStream("Prefix text \u{001B}[3")
        // Part 2: End of sequence "1mRedText\u{001B}[0m Done\n"
        ringBuffer.appendStream("1mRedText\u{001B}[0m Done\n")
        
        XCTAssertEqual(ringBuffer.committedLineCount, 1)
        let lines = ringBuffer.allLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Prefix text"))
        XCTAssertTrue(lines[0].contains("RedText"))
        XCTAssertTrue(lines[0].contains("Done"))
    }
    
    /// Test 5: Interactive line editing (CR, BS, and clear sequences)
    func testInteractiveLineEditingStress() {
        let ringBuffer = TerminalRingBuffer(maxLines: 50)
        
        // Overwrite in place via \r (carriage return)
        ringBuffer.appendStream("Downloading: [ 10% ]\r")
        ringBuffer.appendStream("Downloading: [ 50% ]\r")
        ringBuffer.appendStream("Downloading: [ 100% ]\n")
        
        XCTAssertEqual(ringBuffer.committedLineCount, 1)
        XCTAssertEqual(ringBuffer.allLines()[0], "Downloading: [ 100% ]")
        
        // Rapid Backspace test
        ringBuffer.appendStream("cat /etc/passwdd")
        ringBuffer.appendStream("\u{08}") // backspace 'd'
        ringBuffer.appendStream("\n")
        
        XCTAssertEqual(ringBuffer.committedLineCount, 2)
        XCTAssertEqual(ringBuffer.allLines()[1], "cat /etc/passwd")
    }
}
