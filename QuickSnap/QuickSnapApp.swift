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
    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled

    var body: some Scene {
        MenuBarExtra("QuickSnap", systemImage: "camera.viewfinder") {
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
        let view = NSView()
        
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // First open of the window in a session: the menu item activates
            // the app, but this window is created after that, so it needs
            // ordering front itself.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // The settings window shows no title bar chrome except the
            // traffic lights: SettingsView strips the toolbar's contents
            // (`.toolbar(removing: .title/.sidebarToggle)` — NOT
            // `.toolbar(.hidden, for: .windowToolbar)`, which nukes the
            // traffic lights too), and these keep the remaining strip
            // invisible so content renders edge-to-edge. (The system
            // scroll-edge effect — titlebarAppearsTransparent = false — was
            // tried for a header blur and misbehaved: no toolbar on first
            // show, then an opaque grey bar after a tab switch.)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden

            window.toolbarStyle = .unified

            window.styleMask.insert(.fullSizeContentView)

            window.isMovableByWindowBackground = true
            // Both halves are required: a clear background on a window
            // that's still opaque leaves black behind everything the system
            // composites over it — the scroll-edge toolbar blur rendered as
            // a solid black bar.
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
