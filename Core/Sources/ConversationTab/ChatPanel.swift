import AppKit
import Combine
import ComposableArchitecture
import ConversationServiceProvider
import MarkdownUI
import ChatAPIService
import SharedUIComponents
import SwiftUI
import ChatService
import SwiftUIFlowLayout
import XcodeInspector
import ChatTab
import Workspace
import Persist
import UniformTypeIdentifiers

private let r: Double = 4

public struct ChatPanel: View {
    @Perception.Bindable var chat: StoreOf<Chat>
    @Namespace var inputAreaNamespace

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                
                if chat.history.isEmpty {
                    VStack {
                        Spacer()
                        Instruction(isAgentMode: $chat.isAgentMode)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.trailing, 16)
                } else {
                    ChatPanelMessages(chat: chat)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Chat Messages Group")
                    
                    if let _ = chat.history.last?.followUp {
                        ChatFollowUp(chat: chat)
                            .padding(.trailing, 16)
                            .padding(.vertical, 8)
                    }
                }
                
                if chat.fileEditMap.count > 0 {
                    WorkingSetView(chat: chat)
                        .padding(.trailing, 16)
                }
                
                ChatPanelInputArea(chat: chat)
                    .padding(.trailing, 16)
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                chat.send(.appear)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                onFileDrop(providers)
            }
        }
    }
    
    private func onFileDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    let url: URL? = {
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        } else if let url = item as? URL {
                            return url
                        }
                        return nil
                    }()
                    
                    guard let url else { return }
                    if let isValidFile = try? WorkspaceFile.isValidFile(url), isValidFile {
                        DispatchQueue.main.async {
                            let fileReference = FileReference(url: url, isCurrentEditor: false)
                            chat.send(.addSelectedFile(fileReference))
                        }
                    } else if let data = try? Data(contentsOf: url),
                        ["png", "jpeg", "jpg", "bmp", "gif", "tiff", "tif", "webp"].contains(url.pathExtension.lowercased()) {
                        DispatchQueue.main.async {
                            chat.send(.addSelectedImage(ImageReference(data: data, fileUrl: url)))
                        }
                    }
                }
            }
        }
        
        return true
    }
}



private struct ScrollViewOffsetPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct ListHeightPreferenceKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct ChatPanelMessages: View {
    let chat: StoreOf<Chat>
    @State var cancellable = Set<AnyCancellable>()
    @State var isScrollToBottomButtonDisplayed = true
    @State var isPinnedToBottom = true
    @Namespace var bottomID
    @Namespace var topID
    @Namespace var scrollSpace
    @State var scrollOffset: Double = 0
    @State var listHeight: Double = 0
    @State var didScrollToBottomOnAppearOnce = false
    @State var isBottomHidden = true
    @Environment(\.isEnabled) var isEnabled

    var body: some View {
        WithPerceptionTracking {
            ScrollViewReader { proxy in
                GeometryReader { listGeo in
                    List {
                        Group {

                            ChatHistory(chat: chat)
                                .listItemTint(.clear)

                            ExtraSpacingInResponding(chat: chat)

                            Spacer(minLength: 12)
                                .id(bottomID)
                                .onAppear {
                                    isBottomHidden = false
                                    if !didScrollToBottomOnAppearOnce {
                                        proxy.scrollTo(bottomID, anchor: .bottom)
                                        didScrollToBottomOnAppearOnce = true
                                    }
                                }
                                .onDisappear {
                                    isBottomHidden = true
                                }
                                .background(GeometryReader { geo in
                                    let offset = geo.frame(in: .named(scrollSpace)).minY
                                    Color.clear.preference(
                                        key: ScrollViewOffsetPreferenceKey.self,
                                        value: offset
                                    )
                                })
                        }
                        .modify { view in
                            if #available(macOS 13.0, *) {
                                view
                                    .listRowSeparator(.hidden)
                            } else {
                                view
                            }
                        }
                    }
                    .padding(.leading, -8)
                    .listStyle(.plain)
                    .listRowBackground(EmptyView())
                    .modify { view in
                        if #available(macOS 13.0, *) {
                            view.scrollContentBackground(.hidden)
                        } else {
                            view
                        }
                    }
                    .coordinateSpace(name: scrollSpace)
                    .preference(
                        key: ListHeightPreferenceKey.self,
                        value: listGeo.size.height
                    )
                    .onPreferenceChange(ListHeightPreferenceKey.self) { value in
                        listHeight = value
                        updatePinningState()
                    }
                    .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { value in
                        scrollOffset = value
                        updatePinningState()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        scrollToBottomButton(proxy: proxy)
                    }
                    .background {
                        PinToBottomHandler(
                            chat: chat,
                            isBottomHidden: isBottomHidden,
                            pinnedToBottom: $isPinnedToBottom
                        ) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                    .task {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                trackScrollWheel()
            }
            .onDisappear {
                cancellable.forEach { $0.cancel() }
                cancellable = []
            }
        }
    }

    func trackScrollWheel() {
        NSApplication.shared.publisher(for: \.currentEvent)
            .filter {
                if !isEnabled { return false }
                return $0?.type == .scrollWheel
            }
            .compactMap { $0 }
            .sink { event in
                guard isPinnedToBottom else { return }
                let delta = event.deltaY
                let scrollUp = delta > 0
                if scrollUp {
                    isPinnedToBottom = false
                }
            }
            .store(in: &cancellable)
    }

    @MainActor
    func updatePinningState() {
        // where does the 32 come from?
        withAnimation(.linear(duration: 0.1)) {
            isScrollToBottomButtonDisplayed = scrollOffset > listHeight + 32 + 20
                || scrollOffset <= 0
        }
    }

    @ViewBuilder
    func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            isPinnedToBottom = true
            withAnimation(.easeInOut(duration: 0.1)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }) {
            Image(systemName: "chevron.down")
                .padding(8)
                .background {
                    Circle()
                        .fill(.thickMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                }
                .overlay {
                    Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HoverButtonStyle(padding: 0))
        .padding(4)
        .keyboardShortcut(.downArrow, modifiers: [.command])
        .opacity(isScrollToBottomButtonDisplayed ? 1 : 0)
        .help("Scroll Down")
    }

    struct ExtraSpacingInResponding: View {
        let chat: StoreOf<Chat>

        var body: some View {
            WithPerceptionTracking {
                if chat.isReceivingMessage {
                    Spacer(minLength: 12)
                }
            }
        }
    }

    struct PinToBottomHandler: View {
        let chat: StoreOf<Chat>
        let isBottomHidden: Bool
        @Binding var pinnedToBottom: Bool
        let scrollToBottom: () -> Void

        @State var isInitialLoad = true
        
        var body: some View {
            WithPerceptionTracking {
                EmptyView()
                    .onChange(of: chat.isReceivingMessage) { isReceiving in
                        if isReceiving {
                            Task {
                                pinnedToBottom = true
                                await Task.yield()
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    scrollToBottom()
                                }
                            }
                        } else {
                            Task { pinnedToBottom = false }
                        }
                    }
                    .onChange(of: chat.history.last) { _ in
                        if pinnedToBottom || isInitialLoad {
                            if isInitialLoad {
                                isInitialLoad = false
                            }
                            Task {
                                await Task.yield()
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    scrollToBottom()
                                }
                            }
                        }
                    }
                    .onChange(of: isBottomHidden) { value in
                        // This is important to prevent it from jumping to the top!
                        if value, pinnedToBottom {
                            scrollToBottom()
                        }
                    }
            }
        }
    }
}

struct ChatHistory: View {
    let chat: StoreOf<Chat>

    var body: some View {
        WithPerceptionTracking {
            ForEach(Array(chat.history.enumerated()), id: \.element.id) { index, message in
                VStack(spacing: 0) {
                    WithPerceptionTracking {
                        ChatHistoryItem(chat: chat, message: message)
                            .id(message.id)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                    }
                    
                    // add divider between messages
                    if message.role != .ignored && index < chat.history.count - 1 {
                        Divider()                    }
                }
            }
        }
    }
}

struct ChatHistoryItem: View {
    let chat: StoreOf<Chat>
    let message: DisplayedChatMessage

    var body: some View {
        WithPerceptionTracking {
            let text = message.text
            switch message.role {
            case .user:
                UserMessage(
                    id: message.id,
                    text: text,
                    imageReferences: message.imageReferences,
                    chat: chat
                )
            case .assistant:
                BotMessage(
                    id: message.id,
                    text: text,
                    references: message.references,
                    followUp: message.followUp,
                    errorMessages: message.errorMessages,
                    chat: chat,
                    steps: message.steps,
                    editAgentRounds: message.editAgentRounds,
                    panelMessages: message.panelMessages
                )
            case .ignored:
                EmptyView()
            }
        }
    }
}

struct ChatFollowUp: View {
    let chat: StoreOf<Chat>
    @AppStorage(\.chatFontSize) var chatFontSize
    
    var body: some View {
        WithPerceptionTracking {
            HStack {
                if let followUp = chat.history.last?.followUp {
                    Button(action: {
                        chat.send(.followUpButtonClicked(UUID().uuidString, followUp.message))
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.blue)
                            
                            Text(followUp.message)
                                .font(.system(size: chatFontSize))
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered in
                        if isHovered {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ChatCLSError: View {
    let chat: StoreOf<Chat>
    @AppStorage(\.chatFontSize) var chatFontSize
    
    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.blue)
                    .padding(.leading, 8)
                
                Text("Monthly chat limit reached. [Upgrade now](https://github.com/github-copilot/signup/copilot_individual) or wait until your usage resets.")
                    .font(.system(size: chatFontSize))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .background(
                RoundedCorners(tl: r, tr: r, bl: 0, br: 0)
                    .fill(.ultraThickMaterial)
            )
            .overlay(
                RoundedCorners(tl: r, tr: r, bl: 0, br: 0)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.top, 4)
        }
    }
}

struct ChatPanelInputArea: View {
    let chat: StoreOf<Chat>
    @FocusState var focusedField: Chat.State.Field?

    var body: some View {
        HStack {
            InputAreaTextEditor(chat: chat, focusedField: $focusedField)
        }
        .background(Color.clear)
    }

    @MainActor
    var clearButton: some View {
        Button(action: {
            chat.send(.clearButtonTap)
        }) {
            Group {
                if #available(macOS 13.0, *) {
                    Image(systemName: "eraser.line.dashed.fill")
                } else {
                    Image(systemName: "trash.fill")
                }
            }
            .padding(6)
            .background {
                Circle().fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                Circle().stroke(Color(nsColor: .controlColor), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
    
    enum ShowingType { case template, agent }

    struct InputAreaTextEditor: View {
        @Perception.Bindable var chat: StoreOf<Chat>
        var focusedField: FocusState<Chat.State.Field?>.Binding
        @State var cancellable = Set<AnyCancellable>()
        @State private var isFilePickerPresented = false
        @State private var allFiles: [FileReference] = []
        @State private var filteredTemplates: [ChatTemplate] = []
        @State private var filteredAgent: [ChatAgent] = []
        @State private var showingTemplates = false
        @State private var dropDownShowingType: ShowingType? = nil

        @AppStorage(\.enableCurrentEditorContext) var enableCurrentEditorContext: Bool
        @State private var isCurrentEditorContextEnabled: Bool = UserDefaults.shared.value(
            for: \.enableCurrentEditorContext
        )

        var body: some View {
            WithPerceptionTracking {
                VStack(spacing: 0) {
                    chatContextView
                    
                    if isFilePickerPresented {
                        FilePicker(
                            allFiles: $allFiles,
                            workspaceURL: chat.workspaceURL,
                            onSubmit: { file in
                                chat.send(.addSelectedFile(file))
                            },
                            onExit: {
                                isFilePickerPresented = false
                                focusedField.wrappedValue = .textField
                            }
                        )
                        .onAppear() {
                            allFiles = ContextUtils.getFilesInActiveWorkspace(workspaceURL: chat.workspaceURL)
                        }
                    }
                    
                    if !chat.state.attachedImages.isEmpty {
                        ImagesScrollView(chat: chat)
                    }
                    
                    ZStack(alignment: .topLeading) {
                        if chat.typedMessage.isEmpty {
                            Group {
                                chat.isAgentMode ?
                                Text("Edit files in your workspace in agent mode") :
                                Text("Ask Copilot or type / for commands")
                            }
                            .font(.system(size: 14))
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(8)
                            .padding(.horizontal, 4)
                        }

                        HStack(spacing: 0) {
                            AutoresizingCustomTextEditor(
                                text: $chat.typedMessage,
                                font: .systemFont(ofSize: 14),
                                isEditable: true,
                                maxHeight: 400,
                                onSubmit: {
                                    if (dropDownShowingType == nil) {
                                        submitChatMessage()
                                    }
                                    dropDownShowingType = nil
                                }
                            )
                            .focused(focusedField, equals: .textField)
                            .bind($chat.focusedField, to: focusedField)
                            .padding(8)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: chat.typedMessage) { newValue in
                                Task {
                                    await onTypedMessageChanged(newValue: newValue)
                                }
                            }
                            /// When chat mode changed, the chat tamplate and agent need to be reloaded
                            .onChange(of: chat.isAgentMode) { _ in
                                Task {
                                    await onTypedMessageChanged(newValue: chat.typedMessage)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                    
                    HStack(spacing: 0) {
                        ModelPicker()

                        Spacer()
                        
                        Group {
                            if chat.isReceivingMessage { stopButton }
                            else { sendButton }
                        }
                        .buttonStyle(HoverButtonStyle(padding: 0))
                    }
                    .padding(8)
                    .padding(.top, -4)
                }
                .overlay(alignment: .top) {
                    dropdownOverlay
                }
                .onAppear() {
                    subscribeToActiveDocumentChangeEvent()
                }
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .controlColor), lineWidth: 1)
                }
                .background {
                    Button(action: {
                        chat.send(.returnButtonTapped)
                    }) {
                        EmptyView()
                    }
                    .keyboardShortcut(KeyEquivalent.return, modifiers: [.shift])
                    .accessibilityHidden(true)
                    
                    Button(action: {
                        focusedField.wrappedValue = .textField
                    }) {
                        EmptyView()
                    }
                    .keyboardShortcut("l", modifiers: [.command])
                    .accessibilityHidden(true)
                }
            }
        }
        
        private var sendButton: some View {
            Button(action: {
                submitChatMessage()
            }) {
                Image(systemName: "paperplane.fill")
                    .padding(4)
            }
            .keyboardShortcut(KeyEquivalent.return, modifiers: [])
            .help("Send")
        }
        
        private var stopButton: some View {
            Button(action: {
                chat.send(.stopRespondingButtonTapped)
            }) {
                Image(systemName: "stop.circle")
                    .padding(4)
            }
            .help("Stop")
        }
        
        private var dropdownOverlay: some View {
            Group {
                if dropDownShowingType != nil {
                    if dropDownShowingType == .template {
                        ChatDropdownView(items: $filteredTemplates, prefixSymbol: "/") { template in
                            chat.typedMessage = "/" + template.id + " "
                            if template.id == "releaseNotes" {
                                submitChatMessage()
                            }
                        }
                    } else if dropDownShowingType == .agent {
                        ChatDropdownView(items: $filteredAgent, prefixSymbol: "@") { agent in
                            chat.typedMessage = "@" + agent.id + " "
                        }
                    }
                }
            }
        }

        func onTypedMessageChanged(newValue: String) async {
            if newValue.hasPrefix("/") {
                filteredTemplates = await chatTemplateCompletion(text: newValue)
                dropDownShowingType = filteredTemplates.isEmpty ? nil : .template
            } else if newValue.hasPrefix("@") && !chat.isAgentMode {
                filteredAgent = await chatAgentCompletion(text: newValue)
                dropDownShowingType = filteredAgent.isEmpty ? nil : .agent
            } else {
                dropDownShowingType = nil
            }
        }
        
        enum ChatContextButtonType { case imageAttach, contextAttach}
        
        private var chatContextView: some View {
            let buttonItems: [ChatContextButtonType] = [.contextAttach, .imageAttach]
            let currentEditorItem: [FileReference] = [chat.state.currentEditor].compactMap {
                $0
            }
            let selectedFileItems = chat.state.selectedFiles
            let chatContextItems: [Any] = buttonItems.map {
                $0 as ChatContextButtonType
            } + currentEditorItem + selectedFileItems
            return FlowLayout(mode: .scrollable, items: chatContextItems, itemSpacing: 4) { item in
                if let buttonType = item as? ChatContextButtonType {
                    if buttonType == .imageAttach {
                        VisionMenuView(chat: chat)
                    } else if buttonType == .contextAttach {
                        // File picker button
                        Button(action: {
                            withAnimation {
                                isFilePickerPresented.toggle()
                                if !isFilePickerPresented {
                                    focusedField.wrappedValue = .textField
                                }
                            }
                        }) {
                            Image(systemName: "paperclip")
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 16, height: 16)
                                .padding(4)
                                .foregroundColor(.primary.opacity(0.85))
                                .font(Font.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(HoverButtonStyle(padding: 0))
                        .help("Add Context")
                        .cornerRadius(6)
                    }
                } else if let select = item as? FileReference {
                    HStack(spacing: 0) {
                        drawFileIcon(select.url)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundColor(.primary.opacity(0.85))
                            .padding(4)
                            .opacity(select.isCurrentEditor && !isCurrentEditorContextEnabled ? 0.4 : 1.0)

                        Text(select.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(
                                select.isCurrentEditor && !isCurrentEditorContextEnabled
                                ? .secondary
                                : .primary.opacity(0.85)
                            )
                            .font(.body)
                            .opacity(select.isCurrentEditor && !isCurrentEditorContextEnabled ? 0.4 : 1.0)
                            .help(select.getPathRelativeToHome())
                        
                        if select.isCurrentEditor {
                            Toggle("", isOn: $isCurrentEditorContextEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: .blue))
                                .controlSize(.mini)
                                .padding(.trailing, 4)
                                .onChange(of: isCurrentEditorContextEnabled) { newValue in
                                    enableCurrentEditorContext = newValue
                                }
                        } else {
                            Button(action: { chat.send(.removeSelectedFile(select)) }) {
                                Image(systemName: "xmark")
                                    .resizable()
                                    .frame(width: 8, height: 8)
                                    .foregroundColor(.primary.opacity(0.85))
                                    .padding(4)
                            }
                            .buttonStyle(HoverButtonStyle())
                        }
                    }
                    .background(
                        Color(nsColor: .windowBackgroundColor).opacity(0.5)
                    )
                    .cornerRadius(select.isCurrentEditor ? 99 : r)
                    .overlay(
                        RoundedRectangle(cornerRadius: select.isCurrentEditor ? 99 : r)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }

        func chatTemplateCompletion(text: String) async -> [ChatTemplate] {
            guard text.count >= 1 && text.first == "/" else { return [] }
            
            let prefix = text.dropFirst()
            var promptTemplates: [ChatTemplate] = []
            let releaseNotesTemplate: ChatTemplate = .init(
                id: "releaseNotes",
                description: "What's New",
                shortDescription: "What's New",
                scopes: [.chatPanel, .agentPanel]
            )
            
            if !chat.isAgentMode {
                promptTemplates = await SharedChatService.shared.loadChatTemplates() ?? []
            }

            let templates = promptTemplates + [releaseNotesTemplate]
            let skippedTemplates = [ "feedback", "help" ]
            
            return templates.filter {
                $0.scopes.contains(chat.isAgentMode ? .agentPanel : .chatPanel) &&
                $0.id.hasPrefix(prefix) &&
                !skippedTemplates.contains($0.id)
            }
        }
        
        func chatAgentCompletion(text: String) async -> [ChatAgent] {
            guard text.count >= 1 && text.first == "@" else { return [] }
            let prefix = text.dropFirst()
            var chatAgents = await SharedChatService.shared.loadChatAgents() ?? []
            
            if let index = chatAgents.firstIndex(where: { $0.slug == "project" }) {
                let projectAgent = chatAgents[index]
                chatAgents[index] = .init(slug: "workspace", name: "workspace", description: "Ask about your workspace", avatarUrl: projectAgent.avatarUrl)
            }
            
            /// only enable the @workspace
            let includedAgents = ["workspace"]
            
            return chatAgents.filter { $0.slug.hasPrefix(prefix) && includedAgents.contains($0.slug) }
        }

        func subscribeToActiveDocumentChangeEvent() {
            Publishers.CombineLatest(
                XcodeInspector.shared.$latestActiveXcode,
                XcodeInspector.shared.$activeDocumentURL
                    .removeDuplicates()
                )
                .receive(on: DispatchQueue.main)
                .sink { newXcode, newDocURL in
                    // First check for realtimeWorkspaceURL if activeWorkspaceURL is nil
                    if let realtimeURL = newXcode?.realtimeDocumentURL, newDocURL == nil {
                        if supportedFileExtensions.contains(realtimeURL.pathExtension) {
                            let currentEditor = FileReference(url: realtimeURL, isCurrentEditor: true)
                            chat.send(.setCurrentEditor(currentEditor))
                        }
                    } else {
                        if supportedFileExtensions.contains(newDocURL?.pathExtension ?? "") {
                            let currentEditor = FileReference(url: newDocURL!, isCurrentEditor: true)
                            chat.send(.setCurrentEditor(currentEditor))
                        }
                    }
                }
                .store(in: &cancellable)
        }
        
        func submitChatMessage() {
            chat.send(.sendButtonTapped(UUID().uuidString))
        }
    }
}
// MARK: - Previews

struct ChatPanel_Preview: PreviewProvider {
    static let history: [DisplayedChatMessage] = [
        .init(
            id: "1",
            role: .user,
            text: "**Hello**",
            references: []
        ),
        .init(
            id: "2",
            role: .assistant,
            text: """
            ```swift
            func foo() {}
            ```
            **Hey**! What can I do for you?**Hey**! What can I do for you?**Hey**! What can I do for you?**Hey**! What can I do for you?
            """,
            references: [
                .init(
                    uri: "Hi Hi Hi Hi",
                    status: .included,
                    kind: .class
                ),
            ]
        ),
        .init(
            id: "7",
            role: .ignored,
            text: "Ignored",
            references: []
        ),
        .init(
            id: "5",
            role: .assistant,
            text: "Yooo",
            references: []
        ),
        .init(
            id: "4",
            role: .user,
            text: "Yeeeehh",
            references: []
        ),
        .init(
            id: "3",
            role: .user,
            text: #"""
            Please buy me a coffee!
            | Coffee | Milk |
            |--------|------|
            | Espresso | No |
            | Latte | Yes |

            ```swift
            func foo() {}
            ```
            ```objectivec
            - (void)bar {}
            ```
            """#,
            references: [],
            followUp: .init(message: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Fusce turpis dolor, malesuada quis fringilla sit amet, placerat at nunc. Suspendisse orci tortor, tempor nec blandit a, malesuada vel tellus. Nunc sed leo ligula. Ut at ligula eget turpis pharetra tristique. Integer luctus leo non elit rhoncus fermentum.", id: "3", type: "type")
        ),
    ]
    
    static let chatTabInfo = ChatTabInfo(id: "", workspacePath: "path", username: "name")

    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: true),
            reducer: { Chat(service: ChatService.service(for: chatTabInfo)) }
        ))
        .frame(width: 450, height: 1200)
        .colorScheme(.dark)
    }
}

struct ChatPanel_EmptyChat_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: [DisplayedChatMessage](), isReceivingMessage: false),
            reducer: { Chat(service: ChatService.service(for: ChatPanel_Preview.chatTabInfo)) }
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatPanel_InputText_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: false),
            reducer: { Chat(service: ChatService.service(for: ChatPanel_Preview.chatTabInfo)) }
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatPanel_InputMultilineText_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(
            chat: .init(
                initialState: .init(
                    typedMessage: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Fusce turpis dolor, malesuada quis fringilla sit amet, placerat at nunc. Suspendisse orci tortor, tempor nec blandit a, malesuada vel tellus. Nunc sed leo ligula. Ut at ligula eget turpis pharetra tristique. Integer luctus leo non elit rhoncus fermentum.",

                    history: ChatPanel_Preview.history,
                    isReceivingMessage: false
                ),
                reducer: { Chat(service: ChatService.service(for: ChatPanel_Preview.chatTabInfo)) }
            )
        )
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.dark)
    }
}

struct ChatPanel_Light_Preview: PreviewProvider {
    static var previews: some View {
        ChatPanel(chat: .init(
            initialState: .init(history: ChatPanel_Preview.history, isReceivingMessage: true),
            reducer: { Chat(service: ChatService.service(for: ChatPanel_Preview.chatTabInfo)) }
        ))
        .padding()
        .frame(width: 450, height: 600)
        .colorScheme(.light)
    }
}

