import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private let runtime: any AgentRuntimeClient

    var connectionState: RuntimeConnectionState = .disconnected
    var tasks: [TaskSummary] = []
    var selectedTaskID: String?
    var debuggerSnapshot: DesktopDebuggerSnapshot?
    var conversation: [ConversationEntry] = [
        ConversationEntry(
            author: .system,
            content: "Connect a local AgentOS Runtime to start a task."
        ),
    ]
    var isSending = false

    private var eventTask: Task<Void, Never>?

    init(runtime: any AgentRuntimeClient = UnixRuntimeClient()) {
        self.runtime = runtime
    }

    var selectedTask: TaskSummary? {
        tasks.first { $0.id == selectedTaskID }
    }

    func maintainRuntimeConnection() async {
        while !Task.isCancelled {
            if connectionState != .connected {
                DesktopRuntimeLog.write("connection maintenance retry")
                await connect()
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    func connect() async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting
        DesktopRuntimeLog.write("connection attempt started")

        do {
            try await runtime.connect()
            connectionState = .connected
            DesktopRuntimeLog.write("connection attempt completed")
            observeRuntimeEvents()
        } catch {
            connectionState = .unavailable(error.localizedDescription)
            DesktopRuntimeLog.write("connection attempt failed \(error.localizedDescription)")
        }
    }

    func submit(text rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        isSending = true
        conversation.append(ConversationEntry(author: .user, content: text))

        do {
            try await runtime.submit(text: text)
        } catch {
            conversation.append(ConversationEntry(author: .system, content: error.localizedDescription))
        }

        isSending = false
    }

    func cancelSelectedTask() async {
        do {
            try await runtime.cancel(taskID: selectedTaskID)
        } catch {
            conversation.append(ConversationEntry(author: .system, content: error.localizedDescription))
        }
    }

    func focus(taskID: String) async {
        selectedTaskID = taskID
        do { try await runtime.focus(taskID: taskID) }
        catch { conversation.append(ConversationEntry(author: .system, content: error.localizedDescription)) }
    }

    private func observeRuntimeEvents() {
        eventTask?.cancel()
        let events = runtime.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handleRuntimeEvent(event)
            }
        }
    }

    private func handleRuntimeEvent(_ event: RuntimeEvent) {
        switch event {
        case let .connected(protocolVersion):
            conversation.append(
                ConversationEntry(author: .system, content: "Connected to local Runtime (protocol \(protocolVersion)).")
            )
        case let .commandAccepted(_, capsuleID):
            conversation.append(
                ConversationEntry(author: .system, content: "Runtime accepted request \(capsuleID).")
            )
        case let .userOutput(text):
            conversation.append(ConversationEntry(author: .agent, content: text))
        case let .debuggerSnapshot(snapshot):
            debuggerSnapshot = snapshot
        case let .conversationStatus(snapshot):
            selectedTaskID = snapshot?.focusedTaskID
            tasks = snapshot?.tasks.map { task in
                TaskSummary(
                    id: task.taskID,
                    title: task.taskID,
                    status: taskStatus(for: task.lifecycle),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(task.updatedAtMilliseconds) / 1_000),
                    memorySummaryRevision: task.memorySummaryRevision,
                    workContextName: task.workContext.displayName,
                    workContextStatus: task.workContext.resourceStatus,
                    recoveryReason: task.recoveryReason
                )
            } ?? []
        case let .failure(message):
            connectionState = .unavailable(message)
            conversation.append(ConversationEntry(author: .system, content: message))
        }
    }

    private func taskStatus(for lifecycle: String) -> TaskSummary.Status {
        switch lifecycle {
        case "running": .running
        case "completed": .completed
        case "cancelled": .cancelled
        case "blocked", "paused", "requiresuser": .waiting
        case "failed", "interrupted", "budgetlimited", "usagelimited": .failed
        default: .queued
        }
    }
}
