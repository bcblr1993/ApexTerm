import Foundation
import Darwin
import ApexCore

// Resolve file capabilities immediately before exec, including the SSH process
// spawned internally by scp via its -S option. No extra helper process is left alive.
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var tool = "ssh"
    if arguments.first == "--tool" {
        guard arguments.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
        tool = arguments[1]
        arguments.removeFirst(2)
    }
    guard tool == "ssh" || tool == "scp",
          let path = ProcessInfo.processInfo.environment[ChildProcessFileGrants.environmentKey] else {
        throw CocoaError(.fileReadNoPermission)
    }
    let payload = try ChildProcessFileGrants.read(from: URL(fileURLWithPath: path))
    let grants = try payload.resolve()
    var started: [URL] = []
    for grant in grants where grant.url.startAccessingSecurityScopedResource() { started.append(grant.url) }
    defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
    let localPathIndices = try ChildProcessGrantPayload.localFileArgumentIndices(in: arguments, tool: tool)
    arguments = ChildProcessGrantPayload.rebaseArguments(arguments, using: grants, at: localPathIndices)
    let executable = "/usr/bin/" + tool
    let cArguments = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { cArguments.forEach { free($0) } }
    let result = withExtendedLifetime(grants) { execv(executable, cArguments) }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
} catch {
    // Do not print arguments, bookmark bytes, passwords or private file paths.
    FileHandle.standardError.write(Data("ApexTerm SSH file authorization failed.\n".utf8))
    exit(1)
}
