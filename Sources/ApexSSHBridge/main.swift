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
    let environment = ProcessInfo.processInfo.environment
    if arguments.count == 1, environment["SSH_ASKPASS"] == CommandLine.arguments[0],
       environment["SSH_ASKPASS_REQUIRE"] == "force" {
        guard let authentication = payload.authentication,
              authentication.accepts(prompt: arguments[0], hint: environment["SSH_ASKPASS_PROMPT"]) else {
            throw CocoaError(.fileReadNoPermission)
        }
        FileHandle.standardOutput.write(Data((authentication.secret + "\n").utf8))
        exit(0)
    }
    if payload.authentication != nil {
        setenv("SSH_ASKPASS", CommandLine.arguments[0], 1)
        setenv("SSH_ASKPASS_REQUIRE", "force", 1)
    }
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
    FileHandle.standardError.write(Data("AetherTerm SSH file authorization failed.\n".utf8))
    exit(1)
}
