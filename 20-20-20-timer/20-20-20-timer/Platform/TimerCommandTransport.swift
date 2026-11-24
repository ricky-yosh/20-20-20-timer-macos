import Darwin
import Foundation

nonisolated enum TimerCommandTransportError: Error, Equatable, Sendable {
    case socketPathTooLong(path: String, byteCount: Int, maximumByteCount: Int)
    case endpointDirectoryUnavailable(path: String)
    case endpointInUse(path: String)
    case endpointUnavailable(path: String)
    case applicationIdentifierUnavailable(path: String)
    case serverAlreadyRunning
    case peerIdentityUnavailable(code: Int32)
    case peerRejected
    case connectionClosed
    case timedOut
    case frameTooLarge(byteCount: Int, maximumByteCount: Int)
    case malformedFrame
    case systemCall(operation: String, code: Int32)
}

nonisolated extension TimerCommandTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path, byteCount, maximumByteCount):
            return "Socket path '\(path)' is \(byteCount) bytes; the limit is \(maximumByteCount)."
        case let .endpointDirectoryUnavailable(path):
            return "The command endpoint directory '\(path)' is unavailable."
        case let .endpointInUse(path):
            return "Another timer instance owns the command endpoint '\(path)'."
        case let .endpointUnavailable(path):
            return "The timer command endpoint '\(path)' is not available."
        case let .applicationIdentifierUnavailable(path):
            return "Could not read a bundle identifier from '\(path)'."
        case .serverAlreadyRunning:
            return "The command server is already running."
        case let .peerIdentityUnavailable(code):
            return "Could not read the peer identity (errno \(code))."
        case .peerRejected:
            return "The command endpoint peer belongs to another user."
        case .connectionClosed:
            return "The command connection closed before a complete response arrived."
        case .timedOut:
            return "The command transport timed out."
        case let .frameTooLarge(byteCount, maximumByteCount):
            return "The command frame is \(byteCount) bytes; the limit is \(maximumByteCount)."
        case .malformedFrame:
            return "The command frame is malformed."
        case let .systemCall(operation, code):
            return "Command transport \(operation) failed with errno \(code)."
        }
    }
}

nonisolated struct TimerCommandTransportLimits: Equatable, Sendable {
    static let standard = TimerCommandTransportLimits(
        maximumPayloadBytes: 64 * 1024,
        connectionTimeout: .seconds(5),
        clientTimeout: .milliseconds(750)
    )

    let maximumPayloadBytes: Int
    let connectionTimeout: Duration
    let clientTimeout: Duration
}

nonisolated struct TimerCommandEndpoint: Hashable, Sendable {
    static let directoryName = "tc"
    static let socketFileName = "s"
    static let lockFileName = "l"

    let containerTemporaryDirectory: URL

    init(containerTemporaryDirectory: URL) throws {
        let directory = containerTemporaryDirectory
            .standardizedFileURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        let socket = directory.appendingPathComponent(Self.socketFileName)
        let byteCount = socket.path.utf8.count
        let maximumByteCount = TimerCommandSocket.maximumPathBytes
        guard byteCount <= maximumByteCount else {
            throw TimerCommandTransportError.socketPathTooLong(
                path: socket.path,
                byteCount: byteCount,
                maximumByteCount: maximumByteCount
            )
        }
        self.containerTemporaryDirectory = containerTemporaryDirectory.standardizedFileURL
    }

    static func currentProcess() throws -> TimerCommandEndpoint {
        try TimerCommandEndpoint(containerTemporaryDirectory: FileManager.default.temporaryDirectory)
    }

    static func appContainer(
        bundleIdentifier: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> TimerCommandEndpoint {
        let container = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        return try TimerCommandEndpoint(containerTemporaryDirectory: container)
    }

    static func appContainer(
        applicationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> TimerCommandEndpoint {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw TimerCommandTransportError.applicationIdentifierUnavailable(
                path: applicationURL.path
            )
        }
        return try appContainer(
            bundleIdentifier: bundleIdentifier,
            homeDirectory: homeDirectory
        )
    }

    var directoryURL: URL {
        containerTemporaryDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var socketPath: String {
        directoryURL.appendingPathComponent(Self.socketFileName).path
    }

    var lockPath: String {
        directoryURL.appendingPathComponent(Self.lockFileName).path
    }
}

nonisolated struct TimerCommandReply: Sendable {
    let payload: Data
    let afterReply: (@Sendable () async -> Void)?

    init(_ payload: Data, afterReply: (@Sendable () async -> Void)? = nil) {
        self.payload = payload
        self.afterReply = afterReply
    }
}

nonisolated struct TimerCommandClient: Sendable {
    let endpoint: TimerCommandEndpoint
    let limits: TimerCommandTransportLimits

    init(
        endpoint: TimerCommandEndpoint,
        limits: TimerCommandTransportLimits = .standard
    ) {
        self.endpoint = endpoint
        self.limits = limits
    }

    func send(_ request: Data) async throws -> Data {
        let frame = try TimerCommandFrame.encode(
            request,
            maximumPayloadBytes: limits.maximumPayloadBytes
        )
        let endpoint = self.endpoint
        let limits = self.limits
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try TimerCommandClient.exchange(
                        frame: frame,
                        endpoint: endpoint,
                        limits: limits
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func exchange(
        frame: Data,
        endpoint: TimerCommandEndpoint,
        limits: TimerCommandTransportLimits
    ) throws -> Data {
        let deadline = TimerCommandSocket.deadline(after: limits.clientTimeout)
        let descriptor = try TimerCommandSocket.makeStreamSocket()
        defer { close(descriptor) }

        let socketAddress = try TimerCommandSocket.address(for: endpoint.socketPath)
        var address = socketAddress.address
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(descriptor, pointer, socketAddress.length)
            }
        }
        if connectResult != 0 {
            let code = errno
            if code == EINPROGRESS {
                try TimerCommandSocket.wait(descriptor, events: Int16(POLLOUT), until: deadline)
                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &errorLength
                ) == 0 else {
                    throw TimerCommandTransportError.systemCall(operation: "getsockopt", code: errno)
                }
                if socketError != 0 {
                    throw TimerCommandSocket.connectionError(
                        code: socketError,
                        path: endpoint.socketPath
                    )
                }
            } else {
                throw TimerCommandSocket.connectionError(code: code, path: endpoint.socketPath)
            }
        }

        try TimerCommandSocket.verifyPeerIsCurrentUser(descriptor)
        try TimerCommandSocket.writeBlocking(frame, to: descriptor, until: deadline)
        shutdown(descriptor, SHUT_WR)
        return try TimerCommandSocket.readFrameBlocking(
            from: descriptor,
            maximumPayloadBytes: limits.maximumPayloadBytes,
            until: deadline
        )
    }
}

actor TimerCommandServer {
    private let endpoint: TimerCommandEndpoint
    private let limits: TimerCommandTransportLimits
    private let queue = DispatchQueue(label: "TimerCommandServer", qos: .userInitiated)
    private var listenerDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var requestHandler: (@Sendable (Data) async -> TimerCommandReply)?
    private var activeDescriptor: Int32 = -1
    private var isServingConnection = false
    private var running = false

    init(
        endpoint: TimerCommandEndpoint,
        limits: TimerCommandTransportLimits = .standard
    ) {
        self.endpoint = endpoint
        self.limits = limits
    }

    var isRunning: Bool {
        running
    }

    func start(handler: @escaping @Sendable (Data) async -> TimerCommandReply) throws {
        guard !running else {
            throw TimerCommandTransportError.serverAlreadyRunning
        }
        try TimerCommandSocket.prepareDirectory(at: endpoint.directoryURL)
        let acquiredLock = try TimerCommandSocket.acquireLock(at: endpoint.lockPath)

        var listener: Int32 = -1
        do {
            unlink(endpoint.socketPath)
            listener = try TimerCommandSocket.makeStreamSocket()
            let socketAddress = try TimerCommandSocket.address(for: endpoint.socketPath)
            var address = socketAddress.address
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    bind(listener, pointer, socketAddress.length)
                }
            }
            guard bindResult == 0 else {
                throw TimerCommandTransportError.systemCall(operation: "bind", code: errno)
            }
            guard chmod(endpoint.socketPath, 0o600) == 0 else {
                throw TimerCommandTransportError.systemCall(operation: "chmod", code: errno)
            }
            guard listen(listener, SOMAXCONN) == 0 else {
                throw TimerCommandTransportError.systemCall(operation: "listen", code: errno)
            }
        } catch {
            if listener >= 0 {
                close(listener)
            }
            close(acquiredLock)
            unlink(endpoint.socketPath)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.acceptConnection() }
        }
        source.resume()

        listenerDescriptor = listener
        lockDescriptor = acquiredLock
        listenerSource = source
        requestHandler = handler
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        requestHandler = nil

        listenerSource?.cancel()
        listenerSource = nil
        if listenerDescriptor >= 0 {
            close(listenerDescriptor)
            listenerDescriptor = -1
        }
        if activeDescriptor >= 0 {
            close(activeDescriptor)
            activeDescriptor = -1
        }
        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }
        unlink(endpoint.socketPath)
    }

    deinit {
        listenerSource?.cancel()
        if listenerDescriptor >= 0 {
            close(listenerDescriptor)
        }
        if activeDescriptor >= 0 {
            close(activeDescriptor)
        }
        if lockDescriptor >= 0 {
            close(lockDescriptor)
        }
    }

    private func acceptConnection() {
        guard listenerDescriptor >= 0 else { return }
        while true {
            let descriptor = accept(listenerDescriptor, nil, nil)
            if descriptor < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    return
                }
                if code == EINTR {
                    continue
                }
                return
            }
            guard !isServingConnection else {
                close(descriptor)
                continue
            }
            serve(descriptor)
            return
        }
    }

    private func serve(_ descriptor: Int32) {
        isServingConnection = true
        activeDescriptor = descriptor
        let limits = self.limits

        Task { [weak self] in
            var afterReply: (@Sendable () async -> Void)?
            do {
                try TimerCommandSocket.verifyPeerIsCurrentUser(descriptor)
                let deadline = TimerCommandSocket.deadline(after: limits.connectionTimeout)
                let request = try await TimerCommandSocket.readFrame(
                    from: descriptor,
                    maximumPayloadBytes: limits.maximumPayloadBytes,
                    until: deadline
                )
                guard let self else {
                    close(descriptor)
                    return
                }
                guard let handler = await self.requestHandler else {
                    await self.closeConnection(descriptor)
                    await self.finishServing()
                    return
                }
                let reply = await handler(request)
                try await TimerCommandSocket.writeFrame(
                    reply.payload,
                    maximumPayloadBytes: limits.maximumPayloadBytes,
                    to: descriptor,
                    until: deadline
                )
                shutdown(descriptor, SHUT_WR)
                afterReply = reply.afterReply
            } catch {
            }
            if let afterReply {
                await afterReply()
            }
            if let self {
                await self.closeConnection(descriptor)
                await self.finishServing()
            } else {
                close(descriptor)
            }
        }
    }

    private func closeConnection(_ descriptor: Int32) {
        guard activeDescriptor == descriptor else { return }
        activeDescriptor = -1
        close(descriptor)
    }

    private func finishServing() {
        isServingConnection = false
    }
}

private nonisolated enum TimerCommandFrame {
    static let headerByteCount = 4

    static func encode(_ payload: Data, maximumPayloadBytes: Int) throws -> Data {
        guard payload.count <= maximumPayloadBytes else {
            throw TimerCommandTransportError.frameTooLarge(
                byteCount: payload.count,
                maximumByteCount: maximumPayloadBytes
            )
        }
        let length = UInt32(payload.count)
        var frame = Data(capacity: headerByteCount + payload.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(payload)
        return frame
    }

    static func payloadLength(in data: Data) -> Int? {
        guard data.count >= headerByteCount else { return nil }
        let bytes = [UInt8](data.prefix(headerByteCount))
        return (Int(bytes[0]) << 24)
            | (Int(bytes[1]) << 16)
            | (Int(bytes[2]) << 8)
            | Int(bytes[3])
    }
}

private nonisolated enum TimerCommandSocket {
    static let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(for path: String) throws -> (address: sockaddr_un, length: socklen_t) {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maximumPathBytes else {
            throw TimerCommandTransportError.socketPathTooLong(
                path: path,
                byteCount: pathBytes.count,
                maximumByteCount: maximumPathBytes
            )
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        let length = socklen_t(offset + pathBytes.count + 1)
        address.sun_len = UInt8(truncatingIfNeeded: length)
        return (address, length)
    }

    static func makeStreamSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TimerCommandTransportError.systemCall(operation: "socket", code: errno)
        }
        do {
            try setNonBlocking(descriptor)
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw TimerCommandTransportError.systemCall(operation: "setsockopt", code: errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TimerCommandTransportError.systemCall(operation: "fcntl", code: errno)
        }
    }

    static func verifyPeerIsCurrentUser(_ descriptor: Int32) throws {
        var effectiveUser: uid_t = 0
        var effectiveGroup: gid_t = 0
        guard getpeereid(descriptor, &effectiveUser, &effectiveGroup) == 0 else {
            throw TimerCommandTransportError.peerIdentityUnavailable(code: errno)
        }
        guard effectiveUser == geteuid() else {
            throw TimerCommandTransportError.peerRejected
        }
    }

    static func prepareDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw TimerCommandTransportError.endpointDirectoryUnavailable(path: url.path)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw TimerCommandTransportError.endpointDirectoryUnavailable(path: url.path)
            }
        }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw TimerCommandTransportError.systemCall(operation: "lstat", code: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw TimerCommandTransportError.endpointDirectoryUnavailable(path: url.path)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw TimerCommandTransportError.systemCall(operation: "chmod", code: errno)
        }
    }

    static func acquireLock(at path: String) throws -> Int32 {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw TimerCommandTransportError.systemCall(operation: "open", code: errno)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw TimerCommandTransportError.endpointInUse(path: path)
            }
            throw TimerCommandTransportError.systemCall(operation: "flock", code: code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            throw TimerCommandTransportError.systemCall(operation: "chmod", code: code)
        }
        return descriptor
    }

    static func connectionError(code: Int32, path: String) -> TimerCommandTransportError {
        switch code {
        case ENOENT, ECONNREFUSED, ENOTSOCK, ECONNRESET, EPIPE:
            return .endpointUnavailable(path: path)
        default:
            return .systemCall(operation: "connect", code: code)
        }
    }

    static func deadline(after duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let nanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    static func readFrame(
        from descriptor: Int32,
        maximumPayloadBytes: Int,
        until deadline: UInt64
    ) async throws -> Data {
        try await blocking {
            try readFrameBlocking(
                from: descriptor,
                maximumPayloadBytes: maximumPayloadBytes,
                until: deadline
            )
        }
    }

    static func writeFrame(
        _ payload: Data,
        maximumPayloadBytes: Int,
        to descriptor: Int32,
        until deadline: UInt64
    ) async throws {
        try await blocking {
            let frame = try TimerCommandFrame.encode(
                payload,
                maximumPayloadBytes: maximumPayloadBytes
            )
            try writeBlocking(frame, to: descriptor, until: deadline)
        }
    }

    static func readFrameBlocking(
        from descriptor: Int32,
        maximumPayloadBytes: Int,
        until deadline: UInt64
    ) throws -> Data {
        let header = try readExactly(
            TimerCommandFrame.headerByteCount,
            from: descriptor,
            until: deadline
        )
        guard let payloadLength = TimerCommandFrame.payloadLength(in: header) else {
            throw TimerCommandTransportError.malformedFrame
        }
        guard payloadLength <= maximumPayloadBytes else {
            throw TimerCommandTransportError.frameTooLarge(
                byteCount: payloadLength,
                maximumByteCount: maximumPayloadBytes
            )
        }
        return try readExactly(payloadLength, from: descriptor, until: deadline)
    }

    static func writeBlocking(_ data: Data, to descriptor: Int32, until deadline: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let sent = send(descriptor, base.advanced(by: offset), buffer.count - offset, 0)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent == 0 {
                    throw TimerCommandTransportError.connectionClosed
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try wait(descriptor, events: Int16(POLLOUT), until: deadline)
                    continue
                }
                throw TimerCommandTransportError.systemCall(operation: "send", code: code)
            }
        }
    }

    static func wait(_ descriptor: Int32, events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else {
                throw TimerCommandTransportError.timedOut
            }
            let remaining = deadline - now
            let milliseconds = Int32(clamping: max(1, (remaining + 999_999) / 1_000_000))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, milliseconds)
            if result > 0 {
                return
            }
            if result == 0 {
                throw TimerCommandTransportError.timedOut
            }
            if errno == EINTR {
                continue
            }
            throw TimerCommandTransportError.systemCall(operation: "poll", code: errno)
        }
    }

    static func readExactly(_ count: Int, from descriptor: Int32, until deadline: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(capacity: count)
        var scratch = [UInt8](repeating: 0, count: min(max(count, 1), 4096))
        while data.count < count {
            let wanted = min(scratch.count, count - data.count)
            let received = scratch.withUnsafeMutableBytes { buffer in
                recv(descriptor, buffer.baseAddress, wanted, 0)
            }
            if received > 0 {
                data.append(contentsOf: scratch[0..<received])
                continue
            }
            if received == 0 {
                throw TimerCommandTransportError.connectionClosed
            }
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                try wait(descriptor, events: Int16(POLLIN), until: deadline)
                continue
            }
            throw TimerCommandTransportError.systemCall(operation: "recv", code: code)
        }
        return data
    }

    private nonisolated static func blocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
