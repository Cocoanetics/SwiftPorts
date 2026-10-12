import NIOCore
import NIOSSH

final class ServerAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let policy: InProcessSSHServer.AuthenticationPolicy

    init(policy: InProcessSSHServer.AuthenticationPolicy) {
        self.policy = policy
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch self.policy {
        case .acceptAnyPublicKey:
            responsePromise.succeed(.success)
        case .rejectAll:
            responsePromise.succeed(.failure)
        }
    }
}
