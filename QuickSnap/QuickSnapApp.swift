//
//  QuickSnapApp.swift
//  QuickSnap
//
//  Created by Dylan on 11/7/2026.
//

import SwiftUI
import AppKit

@main
struct QuickSnapApp: App {
    @StateObject private var captureCoordinator = CaptureCoordinator()

    /// Used instead of `SettingsLink` so the app can be activated first —
    /// see the Settings… item below.
    @Environment(\.openSettings) private var openSettings

    // Read reactively so the menu reflects hotkey changes immediately. The
    // shortcuts shown here are display only — the actual global trigger is
    // the Carbon registration in HotkeyCoordinator, which consumes the
    // keystroke before SwiftUI could ever see it.
    @AppStorage(AppSettings.Keys.hotkey(for: .captureArea))
    private var areaHotkeyData = Data()
    @AppStorage(AppSettings.Keys.hotkey(for: .captureWindow))
    private var windowHotkeyData = Data()
    @AppStorage(AppSettings.Keys.hotkey(for: .captureFullScreen))
    private var fullScreenHotkeyData = Data()
    @AppStorage(AppSettings.Keys.hotkey(for: .captureText))
    private var textHotkeyData = Data()
    @AppStorage(AppSettings.Keys.hotkey(for: .copyForAI))
    private var copyForAIHotkeyData = Data()
    @AppStorage(AppSettings.Keys.hotkey(for: .searchCaptures))
    private var searchHotkeyData = Data()

    /// Searching means nothing without an index, so the item goes away with
    /// it — read here rather than checked once so the menu follows the
    /// setting live.
    @ObservedObject private var menuBar = MenuBarPresence.shared
    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled

    var body: some Scene {
        // The label form, not `systemImage:`, so the icon can be swapped for
        // a blank one while onboarding flies it into place. The item stays
        // inserted throughout — see `MenuBarPresence`.
        MenuBarExtra(isInserted: .constant(true)) {
            Button("Capture Area") {
                captureCoordinator.startAreaCapture()
            }
            .keyboardShortcut(HotkeyShortcut.decode(areaHotkeyData)?.menuShortcut)

            Button("Capture Window") {
                captureCoordinator.startWindowCapture()
            }
            .keyboardShortcut(HotkeyShortcut.decode(windowHotkeyData)?.menuShortcut)

            Button("Capture Full Screen") {
                captureCoordinator.captureFullScreen()
            }
            .keyboardShortcut(HotkeyShortcut.decode(fullScreenHotkeyData)?.menuShortcut)

            Divider()

            Button("Capture Text (OCR)") {
                captureCoordinator.startTextCapture()
            }
            .keyboardShortcut(HotkeyShortcut.decode(textHotkeyData)?.menuShortcut)

            Button("Copy for AI") {
                captureCoordinator.startCopyForAI()
            }
            .keyboardShortcut(HotkeyShortcut.decode(copyForAIHotkeyData)?.menuShortcut)

            Divider()

            if isIndexingEnabled {
                Button("Search Captures…") {
                    captureCoordinator.showCaptureSearch()
                }
                .keyboardShortcut(HotkeyShortcut.decode(searchHotkeyData)?.menuShortcut)
            }

            Button("Open QuickSnap Folder") {
                captureCoordinator.openSaveFolder()
            }
            
            Divider()
            
            // Not a `SettingsLink`: that opens the window without
            // activating the app, and QuickSnap is an accessory app that is
            // rarely frontmost — so the settings window would appear behind
            // whatever the user was looking at, which reads as the menu item
            // doing nothing. Activating first puts it in front, every time.
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            
            Divider()
            
            Button("Quit QuickSnap") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // A blank image rather than nothing at all: it keeps the item's
            // slot (and therefore its window, which is how the onboarding
            // flight finds where to land) while drawing no icon.
            if menuBar.showsIcon {
                Image(systemName: "camera.viewfinder")
                    .accessibilityLabel("QuickSnap")
            } else {
                Image(nsImage: NSImage(size: NSSize(width: 18, height: 18)))
                    .accessibilityLabel("QuickSnap")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .frame(minWidth: 720, minHeight: 460)
                .background(WindowConfigurator())
            
        }
    }
}


/// SwiftUI representation of a stored hotkey for menu display. Lives here
/// rather than on the Services model because it drags in SwiftUI types.
/// Only single-character keys are representable (`KeyEquivalent` can't
/// express F-keys etc.) — those shortcuts simply show no menu hint.
private extension HotkeyShortcut {
    var menuShortcut: KeyboardShortcut? {
        guard keyLabel.count == 1, let character = keyLabel.lowercased().first else { return nil }

        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }

        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }
}


struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfiguringView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply on every SwiftUI update: the settings window is rebuilt
        // and reconfigured by SwiftUI as tabs change, and configuration
        // applied once at creation doesn't necessarily survive that.
        (nsView as? WindowConfiguringView)?.configureWindow()
    }
}

/// Configures the settings window whenever this view is in one.
///
/// Applied from `viewDidMoveToWindow`, on `didBecomeKey`, and on every
/// SwiftUI update, all idempotent — a single shot at creation was the
/// previous version and it silently did nothing at all when `view.window`
/// was still nil.
private final class WindowConfiguringView: NSView {
    private var observer: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureWindow() }
        }
    }

    func configureWindow() {
        guard let window else { return }

        // The settings window shows no title bar chrome except the traffic
        // lights: SettingsView strips the toolbar's contents
        // (`.toolbar(removing: .title/.sidebarToggle)` — NOT
        // `.toolbar(.hidden, for: .windowToolbar)`, which nukes the traffic
        // lights too), and these keep the remaining strip invisible so
        // content renders edge-to-edge. (The system scroll-edge effect —
        // titlebarAppearsTransparent = false — was tried for a header blur
        // and misbehaved: no toolbar on first show, then an opaque grey bar
        // after a tab switch.)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        // SwiftUI's `Settings` scene builds its window without `.resizable`,
        // so a flexible content frame alone leaves the drag corners inert.
        // The size *range* still comes from SwiftUI's frame.
        window.styleMask.insert(.resizable)
        // Deliberately **not** `isMovableByWindowBackground`. With the title
        // bar hidden it looks like the obvious way to let the window be
        // dragged from anywhere, but AppKit starts a window drag on any
        // mouse-down that isn't claimed by a control — which silently ate the
        // drag-to-reorder in the markup toolbar editor: grabbing an item
        // moved the window instead. The title bar strip is still draggable,
        // which is enough.
        // Both halves are required: a clear background on a window that's
        // still opaque leaves black behind everything the system composites
        // over it — the scroll-edge toolbar blur rendered as a solid black
        // bar.
        window.isOpaque = false
        window.backgroundColor = .clear

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
