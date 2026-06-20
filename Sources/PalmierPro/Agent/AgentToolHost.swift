import Foundation

/// What the agent loop needs from whatever backs its tools: the schemas to advertise, the system
/// prompt to run under, and a dispatcher. `ToolExecutor` (editor-backed, a project's timeline and
/// media panel) and `LibraryToolExecutor` (the home screen's cross-project Library + Spaces) both
/// conform, so a single `AgentService` runs in either context without the loop knowing which.
@MainActor protocol AgentToolHost: AnyObject {
    var toolSchemas: [AnthropicToolSchema] { get }
    var systemInstructions: String { get }
    func execute(name: String, args: [String: Any]) async -> ToolResult
}
