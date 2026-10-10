import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private let runtime: any AgentRuntimeClient

    var connectionState: RuntimeConnectionState = .disconnected
    var tasks: [TaskSummary] = []
    var selectedTaskID: String?
    var conversation: [ConversationEntry] = [
        ConversationEntry(
            author: .system,
            content: "Connect a local AgentOS Runtime to start a task."
        ),
    ]
    var draft = ""
    var isSending = false

    init(runtime: any AgentRuntimeClient = UnavailableRuntimeClient()) {
        self.runtime = runtime
    }

    var selectedTask: TaskSummary? {
        tasks.first { $0.id == selectedTaskID }
    }

    func connect() async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting

        do {
            try await runtime.connect()
            connectionState = .connected
            conversation.append(ConversationEntry(author: .system, content: "Connected to local Runtime."))
        } catch {
            connectionState = .unavailable(error.localizedDescription)
            conversation.append(ConversationEntry(author: .system, content: error.localizedDescription))
        }
    }

    func submitDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        draft = ""
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
}
