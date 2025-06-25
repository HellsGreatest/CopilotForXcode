import ConversationServiceProvider
import JSONRPC
import ChatTab

enum ToolInvocationStatus: String {
    case success, error, cancelled
}

public protocol ToolContextProvider {
    // MARK: insert_edit_into_file
    var chatTabInfo: ChatTabInfo { get }
    func updateFileEdits(by fileEdit: FileEdit) -> Void
}

public typealias ChatHistoryUpdater = (String, [AgentRound]) -> Void

public protocol ICopilotTool {
    /**
      * Invokes the Copilot tool with the given request.
      *  - Parameters:
      *      - request: The tool invocation request.
      *      - completion: Closure called with JSON-RPC response when tool execution completes.
      *      - chatHistoryUpdater: Optional closure to update chat history during tool execution.
      *      - contextProvider: Optional provider that supplies additional context information
      *                         needed for tool execution, such as chat tab data and file editing capabilities.
      *  - Returns: Boolean indicating if the tool call has completed. True if the tool call is completed, false otherwise.
     */
    func invokeTool(
        _ request: InvokeClientToolRequest,
        completion: @escaping (AnyJSONRPCResponse) -> Void,
        chatHistoryUpdater: ChatHistoryUpdater?,
        contextProvider: ToolContextProvider?
    ) -> Bool
}

extension ICopilotTool {
    /**
     * Completes a tool response.
     * - Parameters:
     *   - request: The original tool invocation request.
     *   - status: The completion status of the tool execution (success, error, or cancelled).
     *   - response: The string value to include in the response content.
     *   - completion: The completion handler to call with the response.
     */
    func completeResponse(
        _ request: InvokeClientToolRequest,
        status: ToolInvocationStatus = .success,
        response: String = "",
        completion: @escaping (AnyJSONRPCResponse) -> Void
    ) {
        let result: JSONValue = .array([
            .hash([
                "status": .string(status.rawValue),
                "content": .array([.hash(["value": .string(response)])])
            ]),
            .null
        ])
        completion(AnyJSONRPCResponse(id: request.id, result: result))
    }
}

extension ChatService: ToolContextProvider { }
