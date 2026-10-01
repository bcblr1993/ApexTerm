import XCTest
import Foundation
@testable import ApexSSH

final class PTYInputWriteTests: XCTestCase {
    func testFiftyThousandLineWritePreservesAllBytes() async throws {
        let pipe = Pipe()
        let payload = Data(String(repeating: "中文 paste payload\n", count: 50_000).utf8)
        let writer = Task.detached {
            NativeSSHSession.writePTYInput(payload, to: pipe.fileHandleForWriting.fileDescriptor)
            try pipe.fileHandleForWriting.close()
        }
        let received = pipe.fileHandleForReading.readDataToEndOfFile()
        try await writer.value
        XCTAssertEqual(received, payload)
    }
}
