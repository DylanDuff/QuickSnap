//
//  ImmichDestination.swift
//  QuickSnap
//

import Foundation

/// Immich as an upload target: the orchestration layer over `ImmichClient`'s
/// per-endpoint calls (upload → optionally file into an album → optionally
/// mint a shared link).
///
/// `ImmichClient` stays a pure REST wrapper; the decisions about *which*
/// calls a screenshot upload needs live here, driven by the values
/// `AppSettings.uploadDestination` reads out of settings.
nonisolated struct ImmichDestination: UploadDestination {
    let credentials: ImmichCredentials
    /// Nil means "library only" — Immich stores the asset, it just isn't
    /// filed into an album. There is no folder option; see the note in
    /// `ImmichClient`.
    let albumID: String?
    /// Cached album name, purely so the result toast can say where the
    /// capture went without another round trip.
    let albumName: String?
    let createsSharedLink: Bool

    var providerName: String { "Immich" }

    func upload(_ request: UploadRequest) async throws -> UploadOutcome {
        let uploaded = try await ImmichClient.upload(
            pngData: request.pngData,
            filename: request.filename,
            capturedAt: request.capturedAt,
            credentials: credentials
        )

        // Album filing and link creation happen after the asset is safely
        // on the server, so a failure in either is reported without
        // discarding a successful upload.
        if let albumID, !albumID.isEmpty {
            try await ImmichClient.addAssets([uploaded.assetId], toAlbum: albumID, credentials: credentials)
        }

        let sharedLinkURL = createsSharedLink
            ? try await ImmichClient.createSharedLink(assetId: uploaded.assetId, credentials: credentials)
            : nil

        return UploadOutcome(
            publicURL: sharedLinkURL,
            isDuplicate: uploaded.isDuplicate,
            detail: albumDetail
        )
    }

    /// Only meaningful when there's an album *and* we know its name — the
    /// coordinator prefers the link line when there's a link.
    private var albumDetail: String? {
        guard let albumID, !albumID.isEmpty, let albumName, !albumName.isEmpty else { return nil }
        return "Added to \(albumName)"
    }
}
