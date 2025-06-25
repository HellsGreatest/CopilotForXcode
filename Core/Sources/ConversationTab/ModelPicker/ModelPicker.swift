import SwiftUI
import ChatService
import Persist
import ComposableArchitecture
import GitHubCopilotService
import Combine
import HostAppActivator
import SharedUIComponents
import ConversationServiceProvider

public let SELECTED_LLM_KEY = "selectedLLM"
public let SELECTED_CHATMODE_KEY = "selectedChatMode"

extension Notification.Name {
    static let gitHubCopilotSelectedModelDidChange = Notification.Name("com.github.CopilotForXcode.SelectedModelDidChange")
}

extension AppState {
    func getSelectedModelFamily() -> String? {
        if let savedModel = get(key: SELECTED_LLM_KEY),
           let modelFamily = savedModel["modelFamily"]?.stringValue {
            return modelFamily
        }
        return nil
    }

    func getSelectedModelName() -> String? {
        if let savedModel = get(key: SELECTED_LLM_KEY),
           let modelName = savedModel["modelName"]?.stringValue {
            return modelName
        }
        return nil
    }
    
    func isSelectedModelSupportVision() -> Bool? {
        if let savedModel = get(key: SELECTED_LLM_KEY) {
           return savedModel["supportVision"]?.boolValue
        }
        return nil
    }

    func setSelectedModel(_ model: LLMModel) {
        update(key: SELECTED_LLM_KEY, value: model)
        NotificationCenter.default.post(name: .gitHubCopilotSelectedModelDidChange, object: nil)
    }

    func modelScope() -> PromptTemplateScope {
        return isAgentModeEnabled() ? .agentPanel : .chatPanel
    }
    
    func getSelectedChatMode() -> String {
        if let savedMode = get(key: SELECTED_CHATMODE_KEY),
           let modeName = savedMode.stringValue {
            return convertChatMode(modeName)
        }
        return "Ask"
    }

    func setSelectedChatMode(_ mode: String) {
        update(key: SELECTED_CHATMODE_KEY, value: mode)
    }

    func isAgentModeEnabled() -> Bool {
        return getSelectedChatMode() == "Agent"
    }

    private func convertChatMode(_ mode: String) -> String {
        switch mode {
        case "Agent":
            return "Agent"
        default:
            return "Ask"
        }
    }
}

class CopilotModelManagerObservable: ObservableObject {
    static let shared = CopilotModelManagerObservable()
    
    @Published var availableChatModels: [LLMModel] = []
    @Published var availableAgentModels: [LLMModel] = []
    @Published var defaultChatModel: LLMModel?
    @Published var defaultAgentModel: LLMModel?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Initial load
        availableChatModels = CopilotModelManager.getAvailableChatLLMs(scope: .chatPanel)
        availableAgentModels = CopilotModelManager.getAvailableChatLLMs(scope: .agentPanel)
        defaultChatModel = CopilotModelManager.getDefaultChatModel(scope: .chatPanel)
        defaultAgentModel = CopilotModelManager.getDefaultChatModel(scope: .agentPanel)
        
        
        // Setup notification to update when models change
        NotificationCenter.default.publisher(for: .gitHubCopilotModelsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.availableChatModels = CopilotModelManager.getAvailableChatLLMs(scope: .chatPanel)
                self?.availableAgentModels = CopilotModelManager.getAvailableChatLLMs(scope: .agentPanel)
                self?.defaultChatModel = CopilotModelManager.getDefaultChatModel(scope: .chatPanel)
                self?.defaultAgentModel = CopilotModelManager.getDefaultChatModel(scope: .agentPanel)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .gitHubCopilotShouldSwitchFallbackModel)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if let fallbackModel = CopilotModelManager.getFallbackLLM(
                    scope: AppState.shared
                        .isAgentModeEnabled() ? .agentPanel : .chatPanel
                ) {
                    AppState.shared.setSelectedModel(
                        .init(
                            modelName: fallbackModel.modelName,
                            modelFamily: fallbackModel.id,
                            billing: fallbackModel.billing,
                            supportVision: fallbackModel.capabilities.supports.vision
                        )
                    )
                }
            }
            .store(in: &cancellables)
    }
}

extension CopilotModelManager {
    static func getAvailableChatLLMs(scope: PromptTemplateScope = .chatPanel) -> [LLMModel] {
        let LLMs = CopilotModelManager.getAvailableLLMs()
        return LLMs.filter(
            { $0.scopes.contains(scope) }
        ).map {
            return LLMModel(
                modelName: $0.modelName,
                modelFamily: $0.isChatFallback ? $0.id : $0.modelFamily,
                billing: $0.billing,
                supportVision: $0.capabilities.supports.vision
            )
        }
    }

    static func getDefaultChatModel(scope: PromptTemplateScope = .chatPanel) -> LLMModel? {
        let LLMs = CopilotModelManager.getAvailableLLMs()
        let LLMsInScope = LLMs.filter({ $0.scopes.contains(scope) })
        let defaultModel = LLMsInScope.first(where: { $0.isChatDefault })
        // If a default model is found, return it
        if let defaultModel = defaultModel {
            return LLMModel(
                modelName: defaultModel.modelName,
                modelFamily: defaultModel.modelFamily,
                billing: defaultModel.billing,
                supportVision: defaultModel.capabilities.supports.vision
            )
        }

        // Fallback to gpt-4.1 if available
        let gpt4_1 = LLMsInScope.first(where: { $0.modelFamily == "gpt-4.1" })
        if let gpt4_1 = gpt4_1 {
            return LLMModel(
                modelName: gpt4_1.modelName,
                modelFamily: gpt4_1.modelFamily,
                billing: gpt4_1.billing,
                supportVision: gpt4_1.capabilities.supports.vision
            )
        }

        // If no default model is found, fallback to the first available model
        if let firstModel = LLMsInScope.first {
            return LLMModel(
                modelName: firstModel.modelName,
                modelFamily: firstModel.modelFamily,
                billing: firstModel.billing,
                supportVision: firstModel.capabilities.supports.vision
            )
        }

        return nil
    }
}

struct LLMModel: Codable, Hashable {
    let modelName: String
    let modelFamily: String
    let billing: CopilotModelBilling?
    let supportVision: Bool
}

struct ScopeCache {
    var modelMultiplierCache: [String: String] = [:]
    var cachedMaxWidth: CGFloat = 0
    var lastModelsHash: Int = 0
}

struct ModelPicker: View {
    @State private var selectedModel = ""
    @State private var isHovered = false
    @State private var isPressed = false
    @ObservedObject private var modelManager = CopilotModelManagerObservable.shared
    static var lastRefreshModelsTime: Date = .init(timeIntervalSince1970: 0)

    @State private var chatMode = "Ask"
    @State private var isAgentPickerHovered = false
    
    // Separate caches for both scopes
    @State private var askScopeCache: ScopeCache = ScopeCache()
    @State private var agentScopeCache: ScopeCache = ScopeCache()

    let minimumPadding: Int = 48
    let attributes: [NSAttributedString.Key: NSFont] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]

    var spaceWidth: CGFloat {
        "\u{200A}".size(withAttributes: attributes).width
    }

    var minimumPaddingWidth: CGFloat {
        spaceWidth * CGFloat(minimumPadding)
    }

    init() {
        let initialModel = AppState.shared.getSelectedModelName() ?? CopilotModelManager.getDefaultChatModel()?.modelName ?? ""
        self._selectedModel = State(initialValue: initialModel)
        updateAgentPicker()
    }

    var models: [LLMModel] {
        AppState.shared.isAgentModeEnabled() ? modelManager.availableAgentModels : modelManager.availableChatModels
    }

    var defaultModel: LLMModel? {
        AppState.shared.isAgentModeEnabled() ? modelManager.defaultAgentModel : modelManager.defaultChatModel
    }

    // Get the current cache based on scope
    var currentCache: ScopeCache {
        AppState.shared.isAgentModeEnabled() ? agentScopeCache : askScopeCache
    }

    // Helper method to format multiplier text
    func formatMultiplierText(for billing: CopilotModelBilling?) -> String {
        guard let billingInfo = billing else { return "" }
        
        let multiplier = billingInfo.multiplier
        if multiplier == 0 {
            return "Included"
        } else {
            let numberPart = multiplier.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", multiplier)
                : String(format: "%.2f", multiplier)
            return "\(numberPart)x"
        }
    }
    
    // Update cache for specific scope only if models changed
    func updateModelCacheIfNeeded(for scope: PromptTemplateScope) {
        let currentModels = scope == .agentPanel ? modelManager.availableAgentModels : modelManager.availableChatModels
        let modelsHash = currentModels.hashValue
        
        if scope == .agentPanel {
            guard agentScopeCache.lastModelsHash != modelsHash else { return }
            agentScopeCache = buildCache(for: currentModels, currentHash: modelsHash)
        } else {
            guard askScopeCache.lastModelsHash != modelsHash else { return }
            askScopeCache = buildCache(for: currentModels, currentHash: modelsHash)
        }
    }
    
    // Build cache for given models
    private func buildCache(for models: [LLMModel], currentHash: Int) -> ScopeCache {
        var newCache: [String: String] = [:]
        var maxWidth: CGFloat = 0

        for model in models {
            let multiplierText = formatMultiplierText(for: model.billing)
            newCache[model.modelName] = multiplierText
            
            let displayName = "✓ \(model.modelName)"
            let displayNameWidth = displayName.size(withAttributes: attributes).width
            let multiplierWidth = multiplierText.isEmpty ? 0 : multiplierText.size(withAttributes: attributes).width
            let totalWidth = displayNameWidth + minimumPaddingWidth + multiplierWidth
            maxWidth = max(maxWidth, totalWidth)
        }

        if maxWidth == 0 {
            maxWidth = selectedModel.size(withAttributes: attributes).width
        }
        
        return ScopeCache(
            modelMultiplierCache: newCache,
            cachedMaxWidth: maxWidth,
            lastModelsHash: currentHash
        )
    }

    func updateCurrentModel() {
        selectedModel = AppState.shared.getSelectedModelName() ?? defaultModel?.modelName ?? ""
    }
    
    func updateAgentPicker() {
        self.chatMode = AppState.shared.getSelectedChatMode()
    }
    
    func switchModelsForScope(_ scope: PromptTemplateScope) {
        let newModeModels = CopilotModelManager.getAvailableChatLLMs(scope: scope)
        
        if let currentModel = AppState.shared.getSelectedModelName() {
            if !newModeModels.isEmpty && !newModeModels.contains(where: { $0.modelName == currentModel }) {
                let defaultModel = CopilotModelManager.getDefaultChatModel(scope: scope)
                if let defaultModel = defaultModel {
                    AppState.shared.setSelectedModel(defaultModel)
                } else {
                    AppState.shared.setSelectedModel(newModeModels[0])
                }
            }
        }
        
        self.updateCurrentModel()
        updateModelCacheIfNeeded(for: scope)
    }
    
    // Model picker menu component
    private var modelPickerMenu: some View {
        Menu(selectedModel) {
            // Group models by premium status
            let premiumModels = models.filter { $0.billing?.isPremium == true }
            let standardModels = models.filter { $0.billing?.isPremium == false || $0.billing == nil }
            
            // Display standard models section if available
            modelSection(title: "Standard Models", models: standardModels)
            
            // Display premium models section if available
            modelSection(title: "Premium Models", models: premiumModels)
            
            if standardModels.isEmpty {
                Link("Add Premium Models", destination: URL(string: "https://aka.ms/github-copilot-upgrade-plan")!)
            }
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .frame(maxWidth: labelWidth())
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // Helper function to create a section of model options
    @ViewBuilder
    private func modelSection(title: String, models: [LLMModel]) -> some View {
        if !models.isEmpty {
            Section(title) {
                ForEach(models, id: \.self) { model in
                    modelButton(for: model)
                }
            }
        }
    }
    
    // Helper function to create a model selection button
    private func modelButton(for model: LLMModel) -> some View {
        Button {
            AppState.shared.setSelectedModel(model)
        } label: {
            Text(createModelMenuItemAttributedString(
                modelName: model.modelName,
                isSelected: selectedModel == model.modelName,
                cachedMultiplierText: currentCache.modelMultiplierCache[model.modelName] ?? ""
            ))
        }
    }
    
    private var mcpButton: some View {
        Button(action: {
            try? launchHostAppMCPSettings()
        }) {
            Image(systemName: "wrench.and.screwdriver")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .padding(4)
                .foregroundColor(.primary.opacity(0.85))
                .font(Font.system(size: 11, weight: .semibold))
        }
        .buttonStyle(HoverButtonStyle(padding: 0))
        .help("Configure your MCP server")
        .cornerRadius(6)
    }
    
    // Main view body
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                // Custom segmented control with color change
                ChatModePicker(chatMode: $chatMode, onScopeChange: switchModelsForScope)
                    .onAppear() {
                        updateAgentPicker()
                    }
                
                if chatMode == "Agent" {
                    mcpButton
                }

                // Model Picker
                Group {
                    if !models.isEmpty && !selectedModel.isEmpty {
                        modelPickerMenu
                    } else {
                        EmptyView()
                    }
                }
            }
            .onAppear() {
                updateCurrentModel()
                // Initialize both caches
                updateModelCacheIfNeeded(for: .chatPanel)
                updateModelCacheIfNeeded(for: .agentPanel)
                Task {
                    await refreshModels()
                }
            }
            .onChange(of: defaultModel) { _ in
                updateCurrentModel()
            }
            .onChange(of: modelManager.availableChatModels) { _ in
                updateCurrentModel()
                updateModelCacheIfNeeded(for: .chatPanel)
            }
            .onChange(of: modelManager.availableAgentModels) { _ in
                updateCurrentModel()
                updateModelCacheIfNeeded(for: .agentPanel)
            }
            .onChange(of: chatMode) { _ in
                updateCurrentModel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gitHubCopilotSelectedModelDidChange)) { _ in
                updateCurrentModel()
            }
        }
    }

    func labelWidth() -> CGFloat {
        let width = selectedModel.size(withAttributes: attributes).width
        return CGFloat(width + 20)
    }

    @MainActor
    func refreshModels() async {
        let now = Date()
        if now.timeIntervalSince(Self.lastRefreshModelsTime) < 60 {
            return
        }

        Self.lastRefreshModelsTime = now
        let copilotModels = await SharedChatService.shared.copilotModels()
        if !copilotModels.isEmpty {
            CopilotModelManager.updateLLMs(copilotModels)
        }
    }

    private func createModelMenuItemAttributedString(
        modelName: String,
        isSelected: Bool,
        cachedMultiplierText: String
    ) -> AttributedString {
        let displayName = isSelected ? "✓ \(modelName)" : "    \(modelName)"

        var fullString = displayName
        var attributedString = AttributedString(fullString)

        if !cachedMultiplierText.isEmpty {
            let displayNameWidth = displayName.size(withAttributes: attributes).width
            let multiplierTextWidth = cachedMultiplierText.size(withAttributes: attributes).width
            let neededPaddingWidth = currentCache.cachedMaxWidth - displayNameWidth - multiplierTextWidth
            let finalPaddingWidth = max(neededPaddingWidth, minimumPaddingWidth)
            
            let numberOfSpaces = Int(round(finalPaddingWidth / spaceWidth))
            let padding = String(repeating: "\u{200A}", count: max(minimumPadding, numberOfSpaces))
            fullString = "\(displayName)\(padding)\(cachedMultiplierText)"
            
            attributedString = AttributedString(fullString)

            if let range = attributedString.range(of: cachedMultiplierText) {
                attributedString[range].foregroundColor = .secondary
            }
        }

        return attributedString
    }
}

struct ModelPicker_Previews: PreviewProvider {
    static var previews: some View {
        ModelPicker()
    }
}
