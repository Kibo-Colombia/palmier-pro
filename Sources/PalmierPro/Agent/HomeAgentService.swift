import Foundation

/// The single home-screen agent: an `AgentService` wired to the Library/Spaces tool host with its
/// own persisted history. App-lifetime (the home window is itself a singleton) so chat state
/// survives `HomeView` being recreated when the user switches home sections.
@MainActor
enum HomeAgent {
    static let shared: AgentService = {
        let service = AgentService()
        service.useToolHost(LibraryToolExecutor())   // retained by the service as its tool host
        service.loadHomeSessions()
        service.onSessionsChanged = { HomeChatSessionStore.save(service.sessions) }
        return service
    }()
}
