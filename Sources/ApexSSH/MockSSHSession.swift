import Foundation
import ApexCore

/// High-fidelity mock SSH session for UI preview, offline testing, and metrics simulation
public final class MockSSHSession: SSHSessionProtocol, @unchecked Sendable {
    public let session: Session
    public private(set) var connectionState: SSHConnectionState = .disconnected
    
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var metricsHandler: (@Sendable (ServerMetricsSnapshot) -> Void)?
    private var directoryChangeHandler: (@Sendable (String) -> Void)?
    
    private var metricsTimer: Timer?
    private var currentDirectory = "/root"
    private var inputBuffer = ""
    private let fileLock = NSLock()
    private var mockFiles: [String: Data] = [:]
    
    private var mockCpu = 12.5
    private var mockMemUsed: UInt64 = 4 * 1024 * 1024 * 1024 // 4GB
    private let mockMemTotal: UInt64 = 16 * 1024 * 1024 * 1024 // 16GB
    
    public init(session: Session) {
        self.session = session
    }
    
    public func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {
        self.outputHandler = handler
    }
    
    public func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {
        self.metricsHandler = handler
    }
    
    public func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {
        self.directoryChangeHandler = handler
    }
    
    public func triggerDirectoryChange(to path: String) {
        self.currentDirectory = path
        let osc7 = "\u{001B}]7;file://\(session.host)\(currentDirectory)\u{0007}"
        emit(osc7)
        self.directoryChangeHandler?(path)
    }
    
    public func connect() async throws {
        self.connectionState = .connecting(step: "Resolving \(session.host)...")
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        self.connectionState = .connecting(step: "Authenticating via \(session.authMethod)...")
        try await Task.sleep(nanoseconds: 100_000_000)
        
        self.connectionState = .connected
        
        // Welcome banner
        let banner = """
        \u{001B}[1;36m====================================================================\u{001B}[0m
        \u{001B}[1;32m  Welcome to \(session.name) (macOS / Apple Silicon Native SSH)\u{001B}[0m
        \u{001B}[0;37m  Kernel: Linux 6.6.0-generic aarch64 | ProMotion 120Hz Accelerated\u{001B}[0m
        \u{001B}[1;36m====================================================================\u{001B}[0m
        
        Last login: \(Date().description) from 192.168.1.100
        \u{001B}[1;32m\(session.username)@\(session.name)\u{001B}[0m:\u{001B}[1;34m~\u{001B}[0m# 
        """
        emit(banner)
        
        // Start streaming metrics if enabled
        if session.agentlessMonitorEnabled {
            startMetricsSimulation()
        }
    }
    
    public func disconnect() async {
        self.connectionState = .disconnected
        metricsTimer?.invalidate()
        metricsTimer = nil
    }
    
    public func sendInputSync(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        
        for char in text {
            if char == "\r" || char == "\n" {
                emit("\r\n")
                processCommand(inputBuffer.trimmingCharacters(in: .whitespaces))
                inputBuffer = ""
                emitPrompt()
            } else if char == "\u{7F}" || char == "\u{08}" { // Backspace
                if !inputBuffer.isEmpty {
                    inputBuffer.removeLast()
                    emit("\u{08} \u{08}")
                }
            } else if char == "\u{03}" { // Ctrl+C
                inputBuffer = ""
                emit("^C\r\n")
                emitPrompt()
            } else {
                inputBuffer.append(char)
                emit(String(char))
            }
        }
    }
    
    public func sendInput(_ data: Data) async throws {
        sendInputSync(data)
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        // Mock pty resize
    }
    
    private func processCommand(_ cmd: String) {
        if cmd.isEmpty { return }
        
        if cmd == "clear" {
            emit("\u{001B}[2J\u{001B}[H")
        } else if cmd.hasPrefix("cd ") {
            let target = cmd.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if target == ".." {
                let parts = currentDirectory.split(separator: "/")
                if parts.count > 1 {
                    currentDirectory = "/" + parts.dropLast().joined(separator: "/")
                } else {
                    currentDirectory = "/"
                }
            } else if target.hasPrefix("/") {
                currentDirectory = target
            } else if target == "~" {
                currentDirectory = "/root"
            } else {
                currentDirectory = currentDirectory == "/" ? "/\(target)" : "\(currentDirectory)/\(target)"
            }
            
            // Emit OSC 7 path change sequence to trigger SFTP auto-sync!
            let osc7 = "\u{001B}]7;file://\(session.host)\(currentDirectory)\u{0007}"
            emit(osc7)
            directoryChangeHandler?(currentDirectory)
        } else if cmd == "ls" || cmd == "ll" {
            let listing = """
            \u{001B}[1;34mbin\u{001B}[0m   \u{001B}[1;34metc\u{001B}[0m   \u{001B}[1;34mhome\u{001B}[0m  \u{001B}[1;34mlib\u{001B}[0m    \u{001B}[1;34mopt\u{001B}[0m   \u{001B}[1;34mroot\u{001B}[0m  \u{001B}[1;34msys\u{001B}[0m   \u{001B}[1;34musr\u{001B}[0m
            \u{001B}[1;34mdev\u{001B}[0m   \u{001B}[1;34mboot\u{001B}[0m  \u{001B}[1;34mdata\u{001B}[0m  \u{001B}[1;34mmedia\u{001B}[0m  \u{001B}[1;34mproc\u{001B}[0m  \u{001B}[1;34mrun\u{001B}[0m   \u{001B}[1;34mtmp\u{001B}[0m   \u{001B}[1;34mvar\u{001B}[0m
            -rw-r--r--  1 root root  1.2K Sep 25 05:30 docker-compose.yml
            -rw-r--r--  1 root root  4.8M Sep 25 05:32 access.log
            """
            emit(listing + "\r\n")
        } else if cmd == "df -h" {
            let df = """
            Filesystem      Size  Used Avail Use% Mounted on
            /dev/nvme0n1p2  100G   24G   72G  25% /
            tmpfs           7.8G     0  7.8G   0% /dev/shm
            /dev/nvme0n1p1  512M  6.1M  506M   2% /boot/efi
            """
            emit(df + "\r\n")
        } else if cmd == "systemctl status nginx" {
            let nginxStatus = """
            ● nginx.service - A high performance web server and a reverse proxy server
                 Loaded: loaded (/lib/systemd/system/nginx.service; enabled; vendor preset: enabled)
                 Active: \u{001B}[1;32mactive (running)\u{001B}[0m since Fri 2026-09-25 05:00:00 CST
                   Docs: man:nginx(8)
                Process: 1204 ExecStart=/usr/sbin/nginx -g daemon on; master_process on; (code=exited, status=0/SUCCESS)
               Main PID: 1205 (nginx)
                  Tasks: 5 (limit: 18882)
                 Memory: 18.4M
                    CPU: 125ms
                 CGroup: /system.slice/nginx.service
                         ├─1205 "nginx: master process /usr/sbin/nginx -g daemon on; master_process on;"
                         └─1206 "nginx: worker process"
            """
            emit(nginxStatus + "\r\n")
        } else {
            emit("bash: \(cmd): command simulated successfully.\r\n")
        }
    }
    
    private func emitPrompt() {
        let prompt = "\u{001B}[1;32m\(session.username)@\(session.name)\u{001B}[0m:\u{001B}[1;34m\(currentDirectory == "/root" ? "~" : currentDirectory)\u{001B}[0m# "
        emit(prompt)
    }
    
    private func emit(_ str: String) {
        if let data = str.data(using: .utf8) {
            outputHandler?(data)
        }
    }
    
    private func startMetricsSimulation() {
        Task { @MainActor [weak self] in
            while true {
                guard let self = self, self.connectionState == .connected else { break }
                
                // Fluctuating dynamic values for charts
                let deltaCpu = Double.random(in: -3.5...4.5)
                self.mockCpu = min(max(self.mockCpu + deltaCpu, 4.0), 85.0)
                
                let rxRate = Double.random(in: 150_000...3_500_000) // 150KB/s - 3.5MB/s
                let txRate = Double.random(in: 40_000...800_000)
                
                let deltaMem = Int64.random(in: -50_000_000...80_000_000)
                let newMem = Int64(self.mockMemUsed) + deltaMem
                self.mockMemUsed = UInt64(max(min(newMem, Int64(self.mockMemTotal - 500_000_000)), 2 * 1024 * 1024 * 1024))
                
                let snapshot = ServerMetricsSnapshot(
                    timestamp: Date(),
                    cpuUsagePercent: self.mockCpu,
                    cpuCores: 8,
                    memoryTotalBytes: self.mockMemTotal,
                    memoryUsedBytes: self.mockMemUsed,
                    memoryCachedBytes: 2 * 1024 * 1024 * 1024,
                    networkRxBytesPerSec: rxRate,
                    networkTxBytesPerSec: txRate,
                    diskTotalBytes: 100 * 1024 * 1024 * 1024,
                    diskUsedBytes: 26 * 1024 * 1024 * 1024,
                    loadAvg1m: Double.random(in: 0.4...1.8),
                    loadAvg5m: 1.1,
                    loadAvg15m: 0.9,
                    uptimeSeconds: 86400 * 14,
                    topProcesses: [
                        ProcessMetricItem(pid: 1248, user: "root", cpuPercent: Double.random(in: 8.5...24.2), memPercent: 3.2, command: "nginx: worker process"),
                        ProcessMetricItem(pid: 3412, user: "node", cpuPercent: Double.random(in: 5.1...18.4), memPercent: 8.5, command: "node server.js"),
                        ProcessMetricItem(pid: 892, user: "mysql", cpuPercent: Double.random(in: 2.0...6.0), memPercent: 14.2, command: "mysqld"),
                        ProcessMetricItem(pid: 4120, user: "redis", cpuPercent: Double.random(in: 0.5...2.5), memPercent: 1.8, command: "redis-server"),
                        ProcessMetricItem(pid: 9811, user: "root", cpuPercent: Double.random(in: 0.1...1.5), memPercent: 0.8, command: "sshd: root@pts/0")
                    ]
                )
                
                self.metricsHandler?(snapshot)
                try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s update interval
            }
        }
    }
    
    // SFTP mock
    private var mockDirectoryItems: [String: [SFTPItem]] = [:]
    
    private func normalizedDirPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    
    private func getInitialItems(for path: String) -> [SFTPItem] {
        let p = path.hasSuffix("/") ? path : "\(path)/"
        return [
            SFTPItem(name: "..", path: (path as NSString).deletingLastPathComponent, isDirectory: true),
            SFTPItem(name: ".bashrc", path: "\(p).bashrc", isDirectory: false, size: 3771, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -86400 * 5)),
            SFTPItem(name: ".profile", path: "\(p).profile", isDirectory: false, size: 807, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -86400 * 10)),
            SFTPItem(name: "bin", path: "\(p)bin", isDirectory: true, size: 4096, permissions: 0o755, modificationDate: Date(timeIntervalSinceNow: -86400 * 30)),
            SFTPItem(name: "etc", path: "\(p)etc", isDirectory: true, size: 4096, permissions: 0o755, modificationDate: Date(timeIntervalSinceNow: -86400 * 20)),
            SFTPItem(name: "var", path: "\(p)var", isDirectory: true, size: 4096, permissions: 0o755, modificationDate: Date(timeIntervalSinceNow: -86400 * 15)),
            SFTPItem(name: "nginx.conf", path: "\(p)nginx.conf", isDirectory: false, size: 2840, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -3600 * 4)),
            SFTPItem(name: "docker-compose.yml", path: "\(p)docker-compose.yml", isDirectory: false, size: 1420, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -3600 * 12)),
            SFTPItem(name: "access.log", path: "\(p)access.log", isDirectory: false, size: 14_850_000, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -60)),
            SFTPItem(name: "error.log", path: "\(p)error.log", isDirectory: false, size: 34_200, permissions: 0o644, modificationDate: Date(timeIntervalSinceNow: -300)),
            SFTPItem(name: "deploy.sh", path: "\(p)deploy.sh", isDirectory: false, size: 380, permissions: 0o755, modificationDate: Date(timeIntervalSinceNow: -86400 * 2))
        ]
    }
    
    private func withFileLock<T>(_ body: () -> T) -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return body()
    }
    
    public func listDirectory(path: String) async throws -> [SFTPItem] {
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms latency
        let key = normalizedDirPath(path)
        return withFileLock {
            if let existing = mockDirectoryItems[key] {
                return existing
            }
            let initial = getInitialItems(for: key)
            mockDirectoryItems[key] = initial
            return initial
        }
    }
    
    public func removeFile(remotePath: String) async throws {
        let parent = normalizedDirPath((remotePath as NSString).deletingLastPathComponent)
        withFileLock {
            var current = mockDirectoryItems[parent] ?? getInitialItems(for: parent)
            current.removeAll(where: { $0.path == remotePath })
            mockDirectoryItems[parent] = current
        }
    }
    
    public func removeDirectory(remotePath: String, recursive: Bool) async throws {
        let parent = normalizedDirPath((remotePath as NSString).deletingLastPathComponent)
        withFileLock {
            var current = mockDirectoryItems[parent] ?? getInitialItems(for: parent)
            current.removeAll(where: { $0.path == remotePath })
            mockDirectoryItems[parent] = current
        }
    }
    
    public func createDirectory(remotePath: String) async throws {
        let parent = normalizedDirPath((remotePath as NSString).deletingLastPathComponent)
        let name = (remotePath as NSString).lastPathComponent
        withFileLock {
            var current = mockDirectoryItems[parent] ?? getInitialItems(for: parent)
            if !current.contains(where: { $0.path == remotePath }) {
                current.append(SFTPItem(name: name, path: remotePath, isDirectory: true, size: 4096, permissions: 0o755, modificationDate: Date()))
            }
            mockDirectoryItems[parent] = current
        }
    }
    
    public func createFile(remotePath: String) async throws {
        let parent = normalizedDirPath((remotePath as NSString).deletingLastPathComponent)
        let name = (remotePath as NSString).lastPathComponent
        withFileLock {
            var current = mockDirectoryItems[parent] ?? getInitialItems(for: parent)
            if !current.contains(where: { $0.path == remotePath }) {
                current.append(SFTPItem(name: name, path: remotePath, isDirectory: false, size: 0, permissions: 0o644, modificationDate: Date()))
            }
            mockDirectoryItems[parent] = current
        }
    }
    
    public func rename(oldPath: String, newPath: String) async throws {
        let parent = normalizedDirPath((oldPath as NSString).deletingLastPathComponent)
        let newName = (newPath as NSString).lastPathComponent
        withFileLock {
            var current = mockDirectoryItems[parent] ?? getInitialItems(for: parent)
            if let idx = current.firstIndex(where: { $0.path == oldPath }) {
                let old = current[idx]
                current[idx] = SFTPItem(name: newName, path: newPath, isDirectory: old.isDirectory, isSymlink: old.isSymlink, size: old.size, permissions: old.permissions, modificationDate: Date())
            }
            mockDirectoryItems[parent] = current
        }
    }
    
    private func getMockFile(at path: String, fallback: Data) -> Data {
        withFileLock {
            mockFiles[path] ?? fallback
        }
    }
    
    private func setMockFile(at path: String, data: Data) {
        withFileLock {
            mockFiles[path] = data
        }
    }
    
    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 10_000_000)
            progress(Double(step) / 5.0)
        }
        let sample = "# ApexTerm 模拟会话示例文件\n# 路径：\(remotePath)\n"
        let data = getMockFile(at: remotePath, fallback: Data(sample.utf8))
        try data.write(to: localURL, options: .atomic)
    }
    
    public func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        let data = try Data(contentsOf: localURL)
        for step in 1...5 {
            try await Task.sleep(nanoseconds: 10_000_000)
            progress(Double(step) / 5.0)
        }
        setMockFile(at: remotePath, data: data)
    }
}
