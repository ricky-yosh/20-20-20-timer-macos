import Foundation

@main
struct TimerCLI {
    static func main() async {
        let code = await CommandRunner.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}

private enum TimerCLIDefaults {
    static let appName = "20-20-20-timer.app"
    static let bundleIdentifier = "devplaceholder.PR7QWYXL.-0-20-20-timer"
    static let launchTimeout: TimeInterval = 6
}

private struct CommandOptions {
    var commandToken: String?
    var valueToken: String?
    var bundleIdentifier: String?
    var applicationPath: String?
    var shouldLaunch = true
    var demoTimings = false
    var pretty = true
    var help = false
    var version = false
}

private enum CommandRunner {
    static func run(arguments: [String]) async -> Int32 {
        let options: CommandOptions
        switch parse(arguments) {
        case .success(let parsed):
            options = parsed
        case .failure(let response):
            return write(response, pretty: true)
        }

        if options.help {
            print(usage)
            return 0
        }
        if options.version {
            print("20-20-20-cli 1.0")
            return 0
        }
        guard let token = options.commandToken else {
            print(usage)
            return 2
        }
        guard let command = resolve(token) else {
            return write(
                .failure(.invalidCommand, "Unknown command '\(token)'. Run 20-20-20-cli --help."),
                pretty: options.pretty
            )
        }
        guard let enabled = enabledValue(for: command, token: options.valueToken) else {
            return write(
                .failure(.invalidArgument, "\(command.rawValue) requires on or off."),
                pretty: options.pretty
            )
        }
        if let valueToken = options.valueToken, !command.requiresEnabledValue {
            return write(
                .failure(.invalidArgument, "\(command.rawValue) does not accept '\(valueToken)'."),
                pretty: options.pretty
            )
        }

        let appURL = locateApplication(explicitPath: options.applicationPath)
        let endpoint: TimerCommandEndpoint
        do {
            endpoint = try makeEndpoint(appURL: appURL, bundleIdentifier: options.bundleIdentifier)
        } catch {
            return write(
                .failure(
                    .invalidArgument,
                    options.applicationPath == nil
                        ? "Could not derive the timer app container. Pass --app or --bundle-id."
                        : "Could not read the bundle identifier from \(options.applicationPath!)."
                ),
                pretty: options.pretty
            )
        }

        let request = TimerCommandRequest(command: command, enabled: enabled)
        let response = await perform(
            request,
            endpoint: endpoint,
            appURL: appURL,
            launchIfNeeded: options.shouldLaunch && command == .start,
            demoTimings: options.demoTimings
        )
        return write(response, pretty: options.pretty)
    }

    private static func perform(
        _ request: TimerCommandRequest,
        endpoint: TimerCommandEndpoint,
        appURL: URL?,
        launchIfNeeded: Bool,
        demoTimings: Bool
    ) async -> TimerCommandResponse {
        do {
            return try await send(request, endpoint: endpoint)
        } catch {
            guard launchIfNeeded, let appURL else {
                return response(for: error, appURL: appURL)
            }
            do {
                try launch(appURL: appURL, demoTimings: demoTimings)
            } catch {
                return .failure(.appNotRunning, "Could not launch \(appURL.path): \(error.localizedDescription)")
            }
            guard let response = await waitForResponse(request, endpoint: endpoint) else {
                return .failure(
                    .appNotRunning,
                    "The timer app did not open its command endpoint at \(endpoint.socketPath)."
                )
            }
            return response
        }
    }

    private static func send(
        _ request: TimerCommandRequest,
        endpoint: TimerCommandEndpoint
    ) async throws -> TimerCommandResponse {
        let payload = try TimerCommandCodec.encode(request)
        let data = try await TimerCommandClient(endpoint: endpoint).send(payload)
        return try TimerCommandCodec.decode(TimerCommandResponse.self, from: data)
    }

    private static func waitForResponse(
        _ request: TimerCommandRequest,
        endpoint: TimerCommandEndpoint
    ) async -> TimerCommandResponse? {
        let deadline = Date().addingTimeInterval(TimerCLIDefaults.launchTimeout)
        while Date() < deadline {
            if let response = try? await send(request, endpoint: endpoint) {
                return response
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func launch(appURL: URL, demoTimings: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-g", appURL.path]
        if demoTimings {
            arguments.append(contentsOf: ["--args", "--demo-timings"])
        }
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    private static func response(for error: Error, appURL: URL?) -> TimerCommandResponse {
        if let transport = error as? TimerCommandTransportError {
            switch transport {
            case .endpointUnavailable, .endpointDirectoryUnavailable:
                return .failure(
                    .appNotRunning,
                    "The 20-20-20 timer app is not running. Start it with 20-20-20-cli start."
                )
            case .timedOut:
                return .failure(.transportFailure, "The timer app did not answer in time.")
            default:
                return .failure(.transportFailure, transport.localizedDescription)
            }
        }
        return .failure(.transportFailure, error.localizedDescription)
    }

    private static func makeEndpoint(
        appURL: URL?,
        bundleIdentifier: String?
    ) throws -> TimerCommandEndpoint {
        if let appURL {
            return try TimerCommandEndpoint.appContainer(applicationURL: appURL)
        }
        return try TimerCommandEndpoint.appContainer(
            bundleIdentifier: bundleIdentifier ?? TimerCLIDefaults.bundleIdentifier
        )
    }

    private static func locateApplication(explicitPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let explicitPath {
            let url = URL(fileURLWithPath: explicitPath).standardizedFileURL
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        if let environmentPath = ProcessInfo.processInfo.environment["TIMER_APP_PATH"] {
            let url = URL(fileURLWithPath: environmentPath).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()
        let candidates = [
            executableDirectory.appendingPathComponent(TimerCLIDefaults.appName),
            executableDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(TimerCLIDefaults.appName),
            URL(fileURLWithPath: "/Applications/\(TimerCLIDefaults.appName)"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func enabledValue(for command: TimerCommand, token: String?) -> Bool?? {
        guard command.requiresEnabledValue else {
            return .some(nil)
        }
        guard let token else {
            return nil
        }
        switch token.lowercased() {
        case "on", "true", "1", "yes":
            return .some(true)
        case "off", "false", "0", "no":
            return .some(false)
        default:
            return nil
        }
    }

    private static func resolve(_ token: String) -> TimerCommand? {
        if let command = TimerCommand(rawValue: token) {
            return command
        }
        switch token {
        case "end-break", "endBreak":
            return .dismissBreak
        case "snooze", "snooze-5m", "snoozeScheduledBreak":
            return .snoozeBreak
        case "take-break", "takeBreakNow":
            return .takeBreakNow
        case "dismiss-check-in", "dismissCheckIn":
            return .dismissCheckIn
        case "set-chime":
            return .setCompletionChime
        case "set-blink":
            return .setBlinkCheckIn
        case "set-posture":
            return .setPostureCheckIn
        default:
            return nil
        }
    }

    private enum ParseResult {
        case success(CommandOptions)
        case failure(TimerCommandResponse)
    }

    private static func parse(_ arguments: [String]) -> ParseResult {
        var options = CommandOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.help = true
            case "--version":
                options.version = true
            case "--no-launch":
                options.shouldLaunch = false
            case "--demo-timings":
                options.demoTimings = true
            case "--compact":
                options.pretty = false
            case "--pretty":
                options.pretty = true
            case "--bundle-id":
                index += 1
                guard index < arguments.count else {
                    return .failure(.failure(.invalidArgument, "--bundle-id requires a value."))
                }
                options.bundleIdentifier = arguments[index]
            case "--app":
                index += 1
                guard index < arguments.count else {
                    return .failure(.failure(.invalidArgument, "--app requires a path."))
                }
                options.applicationPath = arguments[index]
            default:
                if argument.hasPrefix("-") {
                    return .failure(.failure(.invalidCommand, "Unknown option '\(argument)'."))
                }
                if options.commandToken == nil {
                    options.commandToken = argument
                } else if options.valueToken == nil {
                    options.valueToken = argument
                } else {
                    return .failure(.failure(.invalidCommand, "Unexpected argument '\(argument)'."))
                }
            }
            index += 1
        }
        return .success(options)
    }

    private static func write(_ response: TimerCommandResponse, pretty: Bool) -> Int32 {
        if let data = try? TimerCommandCodec.encode(response, pretty: pretty),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return response.error?.code.exitCode ?? 0
    }

    private static let usage = """
    Usage: 20-20-20-cli [options] <command> [on|off]

    Commands:
      status                  Report timer state, remaining time, and preferences
      start                   Start the app if needed, then start the timer
      pause                   Pause the work interval
      resume                  Resume a paused work interval
      take-break-now          Open an on-demand break
      end-break               End or dismiss the current break
      snooze-break            Snooze a scheduled warning or scheduled break
      dismiss-check-in        Dismiss the visible blink or posture prompt
      set-chime on|off        Set the completion chime preference
      set-blink on|off        Set the blink reminder preference
      set-posture on|off      Set the posture reminder preference
      quit                    Ask the app to quit after acknowledging

    Options:
      --app <path>            Path to 20-20-20-timer.app
      --bundle-id <id>        App bundle identifier for the command container
      --no-launch             Do not launch the app for start
      --demo-timings          Pass --demo-timings when launching a Debug app
      --compact               Emit compact JSON
      --pretty                Emit pretty-printed JSON (default)
      --help                  Show this help
      --version               Show the CLI version
    """
}
