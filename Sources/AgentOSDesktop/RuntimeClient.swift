@preconcurrency import Network
import Foundation

enum DesktopRuntimeLog {
    private static let path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/AgentOSDesktop/runtime.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(message)\n"
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path()) {
            FileManager.default.createFile(atPath: path.path(), contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

enum RuntimeEvent: Sendable {
    case connected(protocolVersion: UInt16)
    case commandAccepted(requestID: String, capsuleID: String)
    case userOutput(String)
    case debuggerSnapshot(DesktopDebuggerSnapshot)
    case conversationStatus(ConversationStatusSnapshot?)
    case failure(String)
}

/// Frontend-facing boundary for the local AgentOS Runtime protocol.
///
/// The app owns its UI state. The concrete client only transports versioned
/// JSON Lines messages over a user-private Unix domain socket.
protocol AgentRuntimeClient: Sendable {
    func connect() async throws
    func disconnect() async
    func submit(text: String) async throws
    func cancel(taskID: String?) async throws
    func focus(taskID: String) async throws
    func events() -> AsyncStream<RuntimeEvent>
}

enum RuntimeClientError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "AgentOS Runtime is not connected."
        case let .connectionFailed(message):
            "Unable to connect to local AgentOS Runtime: \(message)"
        case .encodingFailed:
            "Unable to encode a Runtime protocol message."
        }
    }
}

final class UnixRuntimeClient: @unchecked Sendable, AgentRuntimeClient {
    static let protocolVersion: UInt16 = 1

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.agentos.desktop.runtime")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let eventStream: AsyncStream<RuntimeEvent>
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation

    convenience init() {
        self.init(socketPath: Self.defaultSocketPath())
    }

    init(socketPath: String) {
        self.socketPath = socketPath
        let stream = AsyncStream.makeStream(of: RuntimeEvent.self)
        eventStream = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        eventContinuation.finish()
    }

    func events() -> AsyncStream<RuntimeEvent> {
        eventStream
    }

    func connect() async throws {
        if isConnected { return }

        DesktopRuntimeLog.write("opening socket \(socketPath)")
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await waitUntilReady(connection)
        lock.withLock {
            self.connection = connection
        }
        receiveNext(on: connection)
        try await send(.hello(protocolVersion: Self.protocolVersion))
        try await send(.subscribeDebugger)
        DesktopRuntimeLog.write("hello message sent")
    }

    func disconnect() async {
        let connection = lock.withLock {
            let connection = self.connection
            self.connection = nil
            receiveBuffer.removeAll(keepingCapacity: false)
            return connection
        }
        connection?.cancel()
    }

    func submit(text: String) async throws {
        try await send(.submitText(requestID: UUID().uuidString, text: text))
    }

    func cancel(taskID: String?) async throws {
        try await send(.cancelTask(requestID: UUID().uuidString, taskID: taskID))
    }

    func focus(taskID: String) async throws {
        try await send(.focusTask(requestID: UUID().uuidString, taskID: taskID))
    }

    private var isConnected: Bool {
        lock.withLock { connection != nil }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let finish = ContinuationFinisher(continuation)
            connection.stateUpdateHandler = { state in
                DesktopRuntimeLog.write("network state \(String(describing: state))")
                switch state {
                case .ready:
                    finish.succeed()
                case let .failed(error):
                    finish.fail(RuntimeClientError.connectionFailed(error.localizedDescription))
                case let .waiting(error):
                    finish.fail(RuntimeClientError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    finish.fail(RuntimeClientError.connectionFailed("connection cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ message: ClientMessage) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(message).appendingNewline()
        } catch {
            throw RuntimeClientError.encodingFailed
        }

        let connection = lock.withLock { self.connection }
        guard let connection else { throw RuntimeClientError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RuntimeClientError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.handleIncomingData(data)
            }
            if let error {
                DesktopRuntimeLog.write("receive failed \(error.localizedDescription)")
                self.eventContinuation.yield(.failure(error.localizedDescription))
                return
            }
            guard !isComplete else {
                DesktopRuntimeLog.write("runtime connection closed")
                self.eventContinuation.yield(.failure("Runtime connection closed."))
                return
            }
            self.receiveNext(on: connection)
        }
    }

    private func handleIncomingData(_ data: Data) {
        let lines = lock.withLock {
            receiveBuffer.append(data)
            return receiveBuffer.completeLines()
        }

        for line in lines {
            do {
                eventContinuation.yield(try JSONDecoder().decode(ServerMessage.self, from: line).event)
            } catch {
                eventContinuation.yield(.failure("Invalid Runtime response: \(error.localizedDescription)"))
            }
        }
    }

    private static func defaultSocketPath() -> String {
        if let configuredPath = ProcessInfo.processInfo.environment["AGENTOS_RUNTIME_SOCKET"], !configuredPath.isEmpty {
            return configuredPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return "\(home)/Library/Application Support/AgentOS/runtime.sock"
    }
}

private final class ContinuationFinisher: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() {
        finish(with: .success(()))
    }

    func fail(_ error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum ClientMessage: Encodable {
    case hello(protocolVersion: UInt16)
    case submitText(requestID: String, text: String)
    case cancelTask(requestID: String, taskID: String?)
    case focusTask(requestID: String, taskID: String)
    case subscribeDebugger

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case text
        case taskID = "task_id"
    }

    enum Kind: String, Encodable {
        case hello
        case submitText = "submit_text"
        case cancelTask = "cancel_task"
        case focusTask = "focus_task"
        case subscribeDebugger = "subscribe_debugger"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(protocolVersion):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
        case let .submitText(requestID, text):
            try container.encode(Kind.submitText, forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(text, forKey: .text)
        case let .cancelTask(requestID, taskID):
            try container.encode(Kind.cancelTask, forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encodeIfPresent(taskID, forKey: .taskID)
        case .subscribeDebugger:
            try container.encode(Kind.subscribeDebugger, forKey: .type)
        case let .focusTask(requestID, taskID):
            try container.encode(Kind.focusTask, forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(taskID, forKey: .taskID)
        }
    }
}

private enum ServerMessage: Decodable {
    case hello(protocolVersion: UInt16)
    case commandAccepted(requestID: String, capsuleID: String)
    case userOutput(String)
    case debuggerSnapshot(DesktopDebuggerSnapshot)
    case conversationStatus(ConversationStatusSnapshot?)
    case error(requestID: String?, message: String)

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case capsuleID = "capsule_id"
        case text
        case message
        case snapshot
    }

    enum Kind: String, Decodable {
        case hello
        case commandAccepted = "command_accepted"
        case userOutput = "user_output"
        case error
        case debuggerSnapshot = "debugger_snapshot"
        case conversationStatus = "conversation_status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello(protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion))
        case .commandAccepted:
            self = .commandAccepted(
                requestID: try container.decode(String.self, forKey: .requestID),
                capsuleID: try container.decode(String.self, forKey: .capsuleID)
            )
        case .userOutput:
            self = .userOutput(try container.decode(String.self, forKey: .text))
        case .error:
            self = .error(
                requestID: try container.decodeIfPresent(String.self, forKey: .requestID),
                message: try container.decode(String.self, forKey: .message)
            )
        case .debuggerSnapshot:
            self = .debuggerSnapshot(
                try container.decode(DesktopDebuggerSnapshot.self, forKey: .snapshot)
            )
        case .conversationStatus:
            self = .conversationStatus(
                try container.decodeIfPresent(ConversationStatusSnapshot.self, forKey: .snapshot)
            )
        }
    }

    var event: RuntimeEvent {
        switch self {
        case let .hello(protocolVersion): .connected(protocolVersion: protocolVersion)
        case let .commandAccepted(requestID, capsuleID): .commandAccepted(requestID: requestID, capsuleID: capsuleID)
        case let .userOutput(text): .userOutput(text)
        case let .debuggerSnapshot(snapshot): .debuggerSnapshot(snapshot)
        case let .conversationStatus(snapshot): .conversationStatus(snapshot)
        case let .error(_, message): .failure(message)
        }
    }
}

private extension Data {
    func appendingNewline() -> Data {
        var result = self
        result.append(0x0A)
        return result
    }

    mutating func completeLines() -> [Data] {
        var lines: [Data] = []
        while let newline = firstIndex(of: 0x0A) {
            lines.append(prefix(upTo: newline))
            removeSubrange(...newline)
        }
        return lines
    }
}
