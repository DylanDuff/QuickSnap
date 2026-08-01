//
//  AIProvider.swift
//  QuickSnap
//

import Foundation

/// Why a provider can't be used right now, in terms the settings UI can put
/// in front of someone. Everything here is recoverable except
/// `deviceNotSupported`, so each case carries whether there's anything to do
/// about it.
nonisolated enum AIUnavailableReason: Sendable, Equatable {
    /// The Mac can't run the on-device model at all.
    case deviceNotSupported
    /// Apple Intelligence is switched off in System Settings.
    case appleIntelligenceOff
    /// Available, but the model is still downloading or otherwise not ready.
    case modelNotReady

    var message: String {
        switch self {
        case .deviceNotSupported:
            return "This Mac doesn't support on-device intelligence."
        case .appleIntelligenceOff:
            return "Apple Intelligence is turned off in System Settings."
        case .modelNotReady:
            return "The on-device model isn't ready yet — it may still be downloading."
        }
    }

    /// Whether pointing the user at System Settings would help.
    var isResolvableInSystemSettings: Bool {
        self == .appleIntelligenceOff
    }
}

nonisolated enum AIAvailability: Sendable, Equatable {
    case available
    case unavailable(AIUnavailableReason)

    var isAvailable: Bool {
        self == .available
    }
}

nonisolated enum AIProviderError: LocalizedError {
    case unavailable(AIUnavailableReason)
    /// The model answered, but with nothing usable.
    case emptyResponse
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .emptyResponse: return "No description could be generated."
        case .generationFailed(let detail): return detail
        }
    }
}

/// What a provider is told about a capture when asked to describe it.
///
/// Deliberately text-only: the on-device model takes no image input (see
/// `FoundationModelsProvider`), so `recognizedText` — Vision's OCR of the
/// capture — plus the window it came from is the whole picture. Callers
/// should pass the text as recognized and let the provider do its own
/// trimming.
nonisolated struct CaptureDescriptionRequest: Sendable {
    /// On-screen text from `TextRecognizer`. May be empty.
    let recognizedText: String
    /// The app the capture came from, when known.
    let appName: String?
    /// The window's title, when the capture was a window.
    let windowTitle: String?

    init(recognizedText: String, appName: String? = nil, windowTitle: String? = nil) {
        self.recognizedText = recognizedText
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

/// Something that can answer questions about a capture.
///
/// Same discipline as `UploadDestination`, and for the same reason: several
/// features want to ask a model about a screenshot, and without one seam
/// each would grow its own client, its own settings and its own key
/// handling. Conformers are stateless value types holding only their
/// configuration — no window or view references, nothing mutable.
///
/// Requirements are **narrow, named tasks** rather than a free-form
/// `prompt(_:)`. A general prompt method would put prompt wording at every
/// call site and make each feature's behaviour a property of its caller;
/// keeping the task here means the prompt, its guardrails and its output
/// shape live in one place per feature and can change without touching the
/// UI that asked.
///
/// Adding a provider means a conformer plus a branch in
/// `AppSettings.aiProvider` — nothing upstream, which only ever sees this
/// protocol.
nonisolated protocol AIProvider: Sendable {
    /// User-facing name, used verbatim in settings ("Apple Intelligence").
    var providerName: String { get }

    /// Whether the provider can be used right now. Cheap to read — the
    /// settings UI polls it — and re-read every time, since the answer
    /// changes outside the app (Apple Intelligence toggled, model finished
    /// downloading).
    var availability: AIAvailability { get }

    /// A short human-readable description of what a capture shows, e.g.
    /// "login form validation error". Plain prose, not a slug — turning it
    /// into a filename is the caller's business.
    func describeCapture(_ request: CaptureDescriptionRequest) async throws -> String
}
