import Foundation

enum RuntimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case unavailable(String)

    var title: String {
        switch self {
        case .disconnected:
            "Runtime offline"
        case .connecting:
            "Connecting"
        case .connected:
            "Runtime connected"
        case .unavailable:
            "Runtime unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .disconnected, .unavailable:
            "bolt.slash"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .connected:
            "bolt.fill"
        }
    }
}

struct TaskSummary: Identifiable, Equatable {
    enum Status: String, CaseIterable {
        case queued
        case running
        case waiting
        case completed
        case failed
        case cancelled

        var title: String {
            rawValue.capitalized
        }

        var symbolName: String {
            switch self {
            case .queued: "circle"
            case .running: "play.circle.fill"
            case .waiting: "pause.circle.fill"
            case .completed: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .cancelled: "xmark.circle.fill"
            }
        }
    }

    let id: String
    var title: String
    var status: Status
    var updatedAt: Date
    var memorySummaryRevision: UInt64?
    var workContextName: String
    var workContextStatus: String
    var recoveryReason: String?
}

struct ConversationStatusSnapshot: Decodable, Sendable {
    let conversationID: String
    let focusedTaskID: String?
    let tasks: [ConversationTaskStatus]

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case focusedTaskID = "focused_task_id"
        case tasks
    }
}

struct ConversationTaskStatus: Decodable, Sendable {
    let taskID: String
    let lifecycle: String
    let updatedAtMilliseconds: UInt64
    let memorySummaryRevision: UInt64?
    let workContext: WorkContextStatus
    let recoveryReason: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case lifecycle
        case updatedAtMilliseconds = "updated_at_ms"
        case memorySummaryRevision = "memory_summary_revision"
        case workContext = "work_context"
        case recoveryReason = "recovery_reason"
    }
}

struct WorkContextStatus: Decodable, Sendable {
    let displayName: String
    let revision: UInt64
    let resourceStatus: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case revision
        case resourceStatus = "resource_status"
    }
}

struct ConversationEntry: Identifiable, Equatable {
    enum Author {
        case user
        case agent
        case system
    }

    let id: UUID
    let author: Author
    let content: String
    let timestamp: Date

    init(author: Author, content: String, timestamp: Date = .now) {
        self.id = UUID()
        self.author = author
        self.content = content
        self.timestamp = timestamp
    }
}

struct DesktopDebuggerSnapshot: Decodable, Sendable {
    let agents: [DebuggerAgent]
    let taskState: DebuggerTaskState?
    let taskView: DebuggerTaskGraph?
    let traceEvents: [DebuggerTraceEvent]
    let endpointCount: Int
    let llmCount: Int

    enum CodingKeys: String, CodingKey {
        case agents
        case taskState = "task_state"
        case taskView = "task_view"
        case traceEvents = "trace_events"
        case endpointCount = "endpoint_count"
        case llmCount = "llm_count"
    }
}

struct DebuggerAgent: Decodable, Identifiable, Sendable {
    let id: String
    let role: String
    let status: String
}

struct DebuggerTaskState: Decodable, Sendable {
    let teamTaskID: String
    let status: String
    let currentWorkerRole: String
    let waitingForWorker: String
    let currentTaskIndex: Int?
    let taskCount: Int
    let previousResultCount: Int

    enum CodingKeys: String, CodingKey {
        case teamTaskID = "team_task_id"
        case status
        case currentWorkerRole = "current_worker_role"
        case waitingForWorker = "waiting_for_worker"
        case currentTaskIndex = "current_task_index"
        case taskCount = "task_count"
        case previousResultCount = "previous_result_count"
    }
}

struct DebuggerTaskGraph: Decodable, Sendable {
    let summary: String
    let status: String
    let tasks: [DebuggerTaskNode]
}

struct DebuggerTaskNode: Decodable, Identifiable, Sendable {
    let index: Int
    let status: String
    let workerRole: String
    let task: String

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index
        case status
        case workerRole = "worker_role"
        case task
    }
}

struct DebuggerTraceEvent: Decodable, Identifiable, Sendable {
    let sequence: UInt64
    let kind: String
    let subject: String
    let detail: String

    var id: UInt64 { sequence }
}
