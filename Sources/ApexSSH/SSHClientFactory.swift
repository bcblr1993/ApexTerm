import Foundation
import ApexCore

/// Factory to instantiate the appropriate SSHSessionProtocol implementation for a Session
public enum SSHClientFactory {
    public static func makeClient(
        for session: Session,
        distributionChannel: DistributionChannel = .current
    ) -> SSHSessionProtocol {
        if session.isLocal {
            return LocalTerminalSession(session: session)
        } else if session.host == "192.0.2.10" {
            return MockSSHSession(session: session)
        } else {
            return NativeSSHSession(session: session, distributionChannel: distributionChannel)
        }
    }
}
