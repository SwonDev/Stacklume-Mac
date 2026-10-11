import Foundation

struct AIChatTranscriptCallbacks {
    let send: (String) -> Void
    let copy: (String) -> Void
    let regenerate: () -> Void
    let preview: (AssistantLinkReference) -> Void
    let open: (AssistantLinkReference) -> Void
    let add: ([AssistantLinkReference]) -> Void
}

/// Conserva la política de seguimiento sin invalidar la lista por cambios de geometría.
@MainActor
final class TranscriptScrollState {
    var followsResponse = true
    var isNearBottom = true
    var isExploring = false
}
