import Foundation

extension AgentClient {
    /// One-shot, tool-free completion: drive `stream` and accumulate the text deltas into a
    /// string. Reuses the whole transport + SSE parsing; the model is whatever the client was
    /// constructed with, so build the client with the model you want (M4 summaries use Haiku).
    func complete(system: String, message: AnthropicMessage) async throws -> String {
        var out = ""
        for try await event in stream(system: system, tools: [], messages: [message]) {
            if case .textDelta(let chunk) = event { out += chunk }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
