import Foundation

/// In-memory conversation history with a sliding window for context management.
@MainActor
final class ConversationHistory: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []

    /// Maximum number of messages to keep in context window for LLM calls.
    /// Older messages are still displayed in UI but not sent to the LLM.
    let maxContextMessages: Int

    init(maxContextMessages: Int = 40) {
        self.maxContextMessages = maxContextMessages
    }

    func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    func addUserMessage(_ content: String, isHidden: Bool = false) {
        addMessage(ChatMessage(role: .user, content: content, isHidden: isHidden))
    }

    func addAssistantMessage(_ content: String) {
        addMessage(ChatMessage(role: .assistant, content: content))
    }

    func addToolStatusMessage(toolName: String, status: String) {
        let normalizedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = normalizedStatus.isEmpty ? normalizedName : "\(normalizedName) \(normalizedStatus)"
        addMessage(ChatMessage(role: .assistant, content: label, isToolStatus: true))
    }

    func addSystemMessage(_ content: String) {
        addMessage(ChatMessage(role: .system, content: content))
    }

    /// Messages to send to the LLM (most recent N messages).
    var contextMessages: [ChatMessage] {
        let contextEligibleMessages = messages.filter { !$0.isToolStatus }
        let startIndex = max(0, contextEligibleMessages.count - maxContextMessages)
        return Array(contextEligibleMessages[startIndex...])
    }

    func removeLastMessage() {
        guard !messages.isEmpty else { return }
        messages.removeLast()
    }

    func clear() {
        messages.removeAll()
    }
}
