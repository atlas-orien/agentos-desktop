import SwiftUI

@main
struct AgentOSDesktopApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AgentOS") {
            MainWindow(model: model)
                .frame(minWidth: 860, minHeight: 620)
                .task {
                    await model.maintainRuntimeConnection()
                }
        }
        .defaultSize(width: 1_080, height: 760)

        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var page: DesktopPage? = .chat

    var body: some View {
        NavigationSplitView {
            AppSidebar(connectionState: model.connectionState, page: $page)
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        } detail: {
            switch page ?? .chat {
            case .chat:
                ChatWorkspace(model: model)
            case .debugger:
                DebuggerPane(snapshot: model.debuggerSnapshot)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task { await model.connect() }
                } label: {
                    Label("Connect Runtime", systemImage: model.connectionState.symbolName)
                }
                .disabled(model.connectionState == .connecting || model.connectionState == .connected)
                .help("Connect to the local AgentOS Runtime")

                Button(role: .destructive) {
                    Task { await model.cancelSelectedTask() }
                } label: {
                    Label("Cancel task", systemImage: "stop.fill")
                }
                .disabled(model.selectedTask == nil)
                .help("Cancel the selected task")
            }
        }
    }
}

private enum DesktopPage: Hashable {
    case chat
    case debugger
}

private struct AppSidebar: View {
    let connectionState: RuntimeConnectionState
    @Binding var page: DesktopPage?

    var body: some View {
        List(selection: $page) {
            Section("AgentOS") {
                Label("Chat", systemImage: "message")
                    .tag(DesktopPage.chat)
                Label("Debugger", systemImage: "waveform.path.ecg")
                    .tag(DesktopPage.debugger)
            }

            Section("Runtime") {
                Label(connectionState.title, systemImage: connectionState.symbolName)
                    .foregroundStyle(connectionTint)
            }
        }
        .navigationTitle("AgentOS")
        .listStyle(.sidebar)
    }

    private var connectionTint: Color {
        switch connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .unavailable: .secondary
        }
    }
}

private struct DebuggerPane: View {
    let snapshot: DesktopDebuggerSnapshot?

    var body: some View {
        Group {
            if let snapshot {
                List {
                    Section("Runtime") {
                        LabeledContent("Endpoints", value: "\(snapshot.endpointCount)")
                        LabeledContent("LLMs", value: "\(snapshot.llmCount)")
                    }

                    if let state = snapshot.taskState {
                        Section("Current Task") {
                            LabeledContent("Status", value: state.status)
                            LabeledContent("Worker", value: displayValue(state.currentWorkerRole))
                            LabeledContent("Waiting", value: displayValue(state.waitingForWorker))
                            LabeledContent(
                                "Progress",
                                value: "\(state.currentTaskIndex.map { $0 + 1 } ?? 0)/\(state.taskCount)"
                            )
                            LabeledContent("Results", value: "\(state.previousResultCount)")
                        }
                    }

                    if let taskView = snapshot.taskView {
                        Section("Plan") {
                            Text(taskView.summary)
                                .lineLimit(3)
                            ForEach(taskView.tasks) { task in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("\(task.index + 1). \(task.status)")
                                        Spacer()
                                        Text(displayValue(task.workerRole))
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                    Text(task.task)
                                        .lineLimit(2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("Agents") {
                        ForEach(snapshot.agents) { agent in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.id).lineLimit(1)
                                    Text(agent.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(agent.status)
                                    .font(.caption)
                                    .foregroundStyle(agent.status.lowercased() == "idle" ? .secondary : .primary)
                            }
                        }
                    }

                    Section("Recent Events") {
                        ForEach(Array(snapshot.traceEvents.suffix(24).reversed())) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.subject).lineLimit(1)
                                Text("\(event.kind) - \(event.detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Debugger Waiting",
                    systemImage: "waveform.path.ecg",
                    description: Text("Connect to Runtime to receive its current state.")
                )
            }
        }
        .navigationTitle("Debugger")
    }

    private func displayValue(_ value: String) -> String {
        value.isEmpty || value == "(none)" ? "-" : value
    }
}

private struct ChatWorkspace: View {
    @Bindable var model: AppModel

    var body: some View {
        ConversationPane(model: model)
        .navigationTitle("Chat")
    }
}

private struct ConversationPane: View {
    let model: AppModel
    @FocusState private var composerFocused: Bool
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.tasks.isEmpty {
                TaskPortfolioStrip(model: model)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.conversation) { entry in
                        ConversationRow(entry: entry)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($composerFocused)
                        .padding(6)

                    if draft.isEmpty {
                        Text("Describe a task")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 13)
                    }
                }
                .frame(minHeight: 44, maxHeight: 120)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Button {
                    let text = draft
                    draft = ""
                    Task { await model.submit(text: text) }
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                .help("Submit task")
            }
            .padding(16)
        }
        .navigationTitle(model.selectedTask?.title ?? "Conversation")
        .onAppear {
            DispatchQueue.main.async {
                composerFocused = true
            }
        }
    }
}

private struct TaskPortfolioStrip: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.tasks) { task in
                    Button {
                        Task { await model.focus(taskID: task.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).lineLimit(1)
                            Text(task.status.title)
                                .font(.caption)
                            Text(task.workContextName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(task.workContextStatus)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if let recoveryReason = task.recoveryReason {
                                Text(recoveryReason)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                            if let revision = task.memorySummaryRevision {
                                Text("Memory #\(revision)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 220, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(
                        model.selectedTaskID == task.id ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

private struct ConversationRow: View {
    let entry: ConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(authorTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: entry.author == .user ? .trailing : .leading)
        .padding(.leading, entry.author == .user ? 160 : 0)
        .padding(.trailing, entry.author == .user ? 0 : 160)
    }

    private var authorTitle: String {
        switch entry.author {
        case .user: "You"
        case .agent: "AgentOS"
        case .system: "System"
        }
    }
}
