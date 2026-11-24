import Darwin
import Foundation
import os

@MainActor
final class TimerCommandHost {
    static let shared = TimerCommandHost(service: .shared)

    private let service: TimerCommandService
    private let logger = Logger(subsystem: "20-20-20-timer", category: "commands")
    private var server: TimerCommandServer?
    private var startupTask: Task<Void, Never>?

    init(service: TimerCommandService) {
        self.service = service
    }

    func start() {
        guard server == nil, startupTask == nil else { return }
        startupTask = Task { @MainActor in
            await startServing()
        }
    }

    private func startServing() async {
        do {
            guard let home = getpwuid(getuid()) else {
                throw TimerCommandTransportError.endpointDirectoryUnavailable(path: NSHomeDirectory())
            }
            let homeDirectory = URL(
                fileURLWithPath: String(cString: home.pointee.pw_dir),
                isDirectory: true
            )
            guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
                throw TimerCommandTransportError.applicationIdentifierUnavailable(
                    path: Bundle.main.bundleURL.path
                )
            }
            let endpoint = try TimerCommandEndpoint.appContainer(
                bundleIdentifier: bundleIdentifier,
                homeDirectory: homeDirectory
            )
            let server = TimerCommandServer(endpoint: endpoint)
            try await server.start { [service] data in
                do {
                    let request = try TimerCommandCodec.decode(
                        TimerCommandRequest.self,
                        from: data
                    )
                    let execution = await service.execute(request)
                    let payload = try TimerCommandCodec.encode(execution.response)
                    let afterReply: (@Sendable () async -> Void)? = execution.afterResponse.map { completion in
                        { @Sendable in
                            await MainActor.run {
                                completion()
                            }
                        }
                    }
                    return TimerCommandReply(payload, afterReply: afterReply)
                } catch {
                    let response = TimerCommandResponse.failure(
                        .protocolFailure,
                        "The command request is not a valid timer command."
                    )
                    let payload = (try? TimerCommandCodec.encode(response)) ?? Data()
                    return TimerCommandReply(payload)
                }
            }
            self.server = server
        } catch {
            logger.error("Timer command endpoint unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
