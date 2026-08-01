//
//  UploadDestination.swift
//  QuickSnap
//

import Foundation

/// One screenshot, ready to send.
nonisolated struct UploadRequest: Sendable {
    let pngData: Data
    /// Suggested asset/object name, e.g. `QuickSnap 2026-08-01 at 12.30.45.png`.
    /// Destinations may sanitize it (S3 keys, for instance, are better off
    /// without spaces) — the name is a request, not a contract.
    let filename: String
    let capturedAt: Date
}

/// What an upload produced, in the terms the UI actually needs.
nonisolated struct UploadOutcome: Sendable {
    /// A link worth putting on the clipboard, when the destination produced
    /// one. Nil when the user turned links off, or the provider has no
    /// concept of one.
    let publicURL: URL?
    /// The destination already had this exact file (Immich dedupes by
    /// checksum) — worth saying out loud rather than claiming a fresh upload.
    var isDuplicate = false
    /// Optional provider-specific note for the toast's second line, e.g.
    /// the album a capture was filed into.
    var detail: String?
}

/// An upload target. Conformers are stateless value types holding only
/// their configuration — same discipline as the rest of `Services`: no
/// window or view references, no mutable state, everything in and out by
/// value.
///
/// Adding a provider means adding a conformer, a case in `UploadProvider`,
/// a settings section, and a builder in `AppSettings.uploadDestination` —
/// nothing in the coordinator or the capture/preview/markup wiring, which
/// only ever see this protocol.
nonisolated protocol UploadDestination: Sendable {
    /// User-facing name, used verbatim in progress and result toasts
    /// ("Uploading to Immich…").
    var providerName: String { get }

    func upload(_ request: UploadRequest) async throws -> UploadOutcome
}

/// The available upload targets. The raw values are persisted in
/// UserDefaults under `AppSettings.Keys.uploadProvider`, so don't rename
/// them without a migration.
nonisolated enum UploadProvider: String, CaseIterable, Identifiable, Sendable {
    case immich
    case s3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .immich: return "Immich"
        case .s3: return "S3-Compatible"
        }
    }

    /// One-line description shown under the picker.
    var summary: String {
        switch self {
        case .immich:
            return "Self-hosted photo library. Organises by album — Immich has no client-selectable folder."
        case .s3:
            return "Any S3-compatible bucket: Cloudflare R2, Backblaze B2, MinIO, Wasabi, DigitalOcean Spaces, or AWS."
        }
    }
}
