//
//  ScreenCaptureManager.swift
//  QuickSnap
//

import AppKit
import ScreenCaptureKit

enum ScreenCaptureManagerError: Error {
    case displayNotFound
}

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission dialog the first time; returns immediately with
    /// the current status on subsequent calls (macOS won't re-prompt after a denial).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum ScreenCaptureManager {
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return content.displays.first { $0.displayID == screenNumber }
    }

    /// Windows eligible to be picked in "Capture Window" mode: on-screen, normal
    /// application windows, excluding QuickSnap's own overlay windows.
    static func capturableWindows(in content: SCShareableContent) -> [SCWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { window in
            guard window.owningApplication?.processID != ownPID else { return false }
            guard window.isOnScreen, window.windowLayer == 0 else { return false }
            return window.frame.width > 40 && window.frame.height > 40
        }
    }

    static func captureFullScreen(display: SCDisplay, scale: CGFloat, showsCursor: Bool = false) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = showsCursor
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// - Parameter rect: Selection rectangle in points, local to `display`'s own
    ///   top-left-origin coordinate space (i.e. the same space `SelectionOverlayView`
    ///   reports, since that view is flipped and window-aligned to the display).
    static func captureArea(rect: CGRect, display: SCDisplay, scale: CGFloat, showsCursor: Bool = false) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = showsCursor
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures the bare window, edge to edge: the system shadow is excluded
    /// and alpha (the window's rounded corners) is preserved, so
    /// `WindowBackgroundRenderer` can pad it out and draw its own shadow.
    static func captureWindow(_ window: SCWindow, scale: CGFloat, showsCursor: Bool = false) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = showsCursor
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
