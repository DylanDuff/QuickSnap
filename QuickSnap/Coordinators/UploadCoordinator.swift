//
//  UploadCoordinator.swift
//  QuickSnap
//

import AppKit

/// Runs screenshot uploads and reports them to the user.
///
/// Provider-agnostic: it resolves whatever `AppSettings.uploadDestination`
/// currently returns and talks to it purely through `UploadDestination`, so
/// adding a provider needs no changes here. Uploads are fire-and-forget from
/// the caller's point of view — this owns the whole lifetime (PNG encode →
/// upload) and reports progress and outcome through its own toast, since
/// there's no other visible result.
///
/// Multiple uploads can be in flight at once (rapid captures), so the
/// in-progress pill is reference counted rather than shown and hidden per
/// upload.
///
/// Every caller reaches an upload provider through here — `CaptureCoordinator`
/// for automatic post-capture uploads, and the preview panel and annotation
/// toolbar buttons for manual ones.
@MainActor
final class UploadCoordinator {
    private let toastController = ToastController()
    private var activeUploads = 0

    /// True once a provider is switched on and fully configured — what the
    /// optional upload buttons key off.
    var isConfigured: Bool {
        AppSettings.uploadDestination != nil
    }

    /// Uploads `image`, naming it `filename` (the timestamped convention by
    /// default, matching what a local save would be called).
    func upload(_ image: CGImage, filename: String? = nil, on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main
        guard let destination = AppSettings.uploadDestination else {
            report(
                message: "Uploading isn't set up",
                systemImage: "exclamationmark.triangle.fill",
                detail: "Choose a provider and fill in its details in Settings → Uploading.",
                on: targetScreen
            )
            return
        }

        // The upload's own copy is encoded per the user's format setting,
        // independent of whether the capture was also saved to disk.
        let format = ScreenshotSaver.effectiveFormat(for: image, requested: AppSettings.imageFormat)
        let assetName = filename ?? "\(ScreenshotSaver.name()).\(format.fileExtension)"
        let capturedAt = Date()
        let retryLimit = AppSettings.uploadRetryCount

        beginUpload(to: destination, on: targetScreen)

        Task {
            defer { endUpload() }
            do {
                // Encoding a full-resolution screenshot is real CPU work —
                // keep it off the main thread. The upload itself is async
                // URLSession, which never blocks a thread.
                let imageData = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotSaver.imageData(image, format: format)
                }.value

                let outcome = try await Self.uploadWithRetry(
                    to: destination,
                    request: UploadRequest(
                        imageData: imageData,
                        filename: assetName,
                        format: format,
                        capturedAt: capturedAt
                    ),
                    retries: retryLimit
                )

                if let link = outcome.publicURL {
                    ScreenshotSaver.copyToClipboard(link.absoluteString)
                }
                report(
                    message: outcome.isDuplicate
                        ? "Already in \(destination.providerName)"
                        : "Uploaded to \(destination.providerName)",
                    systemImage: "checkmark.circle.fill",
                    detail: successDetail(for: outcome),
                    on: targetScreen
                )
            } catch {
                report(
                    message: "\(destination.providerName) upload failed",
                    systemImage: "exclamationmark.triangle.fill",
                    detail: error.localizedDescription,
                    on: targetScreen
                )
            }
        }
    }

    /// Retries only failures that could plausibly succeed on a second try:
    /// network errors, 5xx, and 429. A 401/403/404 or a malformed request
    /// will fail identically every time, and retrying it just delays the
    /// error the user needs to see.
    ///
    /// Both providers are safe to retry: an S3 `PUT` is idempotent, and
    /// Immich dedupes by checksum, so a retry after a response we never saw
    /// returns the existing asset rather than creating a duplicate.
    private static func uploadWithRetry(
        to destination: any UploadDestination,
        request: UploadRequest,
        retries: Int
    ) async throws -> UploadOutcome {
        var attempt = 0
        while true {
            do {
                return try await destination.upload(request)
            } catch {
                guard attempt < retries, isTransient(error) else { throw error }
                attempt += 1
                // Exponential backoff: 1s, 2s, 4s…
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let immich as ImmichError:
            if case .server(let status, _) = immich {
                return status >= 500 || status == 429
            }
            return false

        case let s3 as S3Error:
            switch s3 {
            case .http(let status):
                return status >= 500 || status == 429
            case .service(let code, _):
                // S3 names its own retryable conditions.
                return ["InternalError", "SlowDown", "ServiceUnavailable", "RequestTimeout"].contains(code)
            default:
                return false
            }

        case let urlError as URLError:
            return [
                .timedOut, .networkConnectionLost, .cannotConnectToHost,
                .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
            ].contains(urlError.code)

        default:
            return false
        }
    }

    /// The second toast line: the link takes priority (it's now on the
    /// clipboard and the user may want to eyeball it), otherwise whatever
    /// the provider had to say.
    private func successDetail(for outcome: UploadOutcome) -> String? {
        if let link = outcome.publicURL {
            return "Link copied — \(link.absoluteString)"
        }
        return outcome.detail
    }

    private func beginUpload(to destination: any UploadDestination, on screen: NSScreen?) {
        activeUploads += 1
        guard let screen else { return }
        toastController.show(
            message: activeUploads > 1
                ? "Uploading \(activeUploads) to \(destination.providerName)…"
                : "Uploading to \(destination.providerName)…",
            systemImage: "arrow.up.circle.fill",
            // No known duration — this pill stays until the result replaces it.
            autoDismisses: false,
            on: screen
        )
    }

    private func endUpload() {
        activeUploads = max(0, activeUploads - 1)
    }

    /// Shows a result pill, but only once the last in-flight upload has
    /// finished — otherwise a fast upload's result would replace the
    /// in-progress pill for uploads still running.
    private func report(message: String, systemImage: String, detail: String?, on screen: NSScreen?) {
        guard let screen else { return }
        guard activeUploads <= 1 else { return }
        toastController.show(message: message, systemImage: systemImage, detail: detail, on: screen)
    }
}
