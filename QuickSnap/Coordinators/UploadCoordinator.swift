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

        let assetName = filename ?? "\(ScreenshotSaver.timestampedName()).png"
        let capturedAt = Date()

        beginUpload(to: destination, on: targetScreen)

        Task {
            defer { endUpload() }
            do {
                // Encoding a full-resolution screenshot is real CPU work —
                // keep it off the main thread. The upload itself is async
                // URLSession, which never blocks a thread.
                let pngData = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotSaver.pngData(image)
                }.value

                let outcome = try await destination.upload(
                    UploadRequest(pngData: pngData, filename: assetName, capturedAt: capturedAt)
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
