//
//  MCPSettingsSection.swift
//  QuickSnap
//

import SwiftUI
import AppKit

/// The MCP server's sections of the Intelligence tab: it lets an AI coding
/// agent drive QuickSnap's captures directly, which is the same subject as
/// the rest of that page — it had its own "Integrations" tab while it was
/// the only thing on it, which read as a category with one member.
///
/// The section's real job is the config snippet. The server is useless until
/// the client knows the URL and the token, and asking someone to assemble
/// that by hand from three fields is where this feature would otherwise be
/// abandoned.
///
/// Sections rather than a `Form` of its own, so it drops into the
/// Intelligence page's form alongside everything else.
struct MCPSettingsSection: View {
    @AppStorage(AppSettings.Keys.mcpEnabled)
    private var isEnabled = AppSettings.Defaults.mcpEnabled

    @AppStorage(AppSettings.Keys.mcpPort)
    private var port = AppSettings.Defaults.mcpPort

    @ObservedObject private var status = MCPServerStatus.shared

    @State private var isTokenVisible = false
    @State private var didCopyConfiguration = false

    var body: some View {
        Group {
            Section("MCP Server") {
                Toggle("Let AI tools capture through QuickSnap", isOn: $isEnabled)

                Text("Exposes QuickSnap's capture tools to MCP clients like Claude Code, so an agent can screenshot a window or read text off your screen without you doing it by hand. It listens only on this Mac and needs the token below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isEnabled {
                    LabeledContent("Status") { statusLabel }

                    LabeledContent("Port") {
                        TextField("Port", value: $port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
            }

            if isEnabled {
                Section("Client Setup") {
                    Text("Add this to your MCP client's configuration, then restart it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal) {
                        Text(configurationSnippet)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 150)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    HStack(spacing: 8) {
                        Button(didCopyConfiguration ? "Copied" : "Copy Configuration") {
                            ScreenshotSaver.copyToClipboard(configurationSnippet)
                            didCopyConfiguration = true
                        }
                        .disabled(didCopyConfiguration)

                        Button(isTokenVisible ? "Hide Token" : "Show Token") {
                            isTokenVisible.toggle()
                        }

                        Spacer()

                        Button("Regenerate Token") {
                            AppSettings.regenerateMCPAuthToken()
                            didCopyConfiguration = false
                        }
                        .help("Any client using the old token stops working until you paste the new configuration.")
                    }
                }

                Section("What agents can do") {
                    ToolSummaryRow(name: "capture_area", detail: "Asks you to drag out a region — the only tool that interrupts you.")
                    ToolSummaryRow(name: "capture_window / capture_screen", detail: "Screenshots a window or display without asking.")
                    ToolSummaryRow(name: "read_screen_text", detail: "Reads on-screen text with on-device OCR, no image.")
                    ToolSummaryRow(name: "list_windows", detail: "Lists what's open, so an agent can pick a window.")
                    ToolSummaryRow(name: "list_recent_captures / search_captures / get_capture", detail: "Finds and reads screenshots QuickSnap saved — never other files in the folder.")

                    Text("QuickSnap shows a confirmation whenever an agent captures something you didn't trigger yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: port) { didCopyConfiguration = false }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status.state {
        case .running(let port):
            Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .stopped:
            Label("Starting…", systemImage: "clock")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }

    /// Written out by hand rather than encoded from a dictionary so the key
    /// order is stable and readable — this is something a person pastes.
    private var configurationSnippet: String {
        let token = isTokenVisible ? (AppSettings.mcpAuthToken() ?? "") : String(repeating: "•", count: 32)
        return """
            {
              "mcpServers": {
                "\(MCPProtocol.serverName)": {
                  "type": "http",
                  "url": "http://127.0.0.1:\(port)/mcp",
                  "headers": {
                    "Authorization": "Bearer \(token)"
                  }
                }
              }
            }
            """
    }
}

/// One line of the "what agents can do" list. Its own view because the tab
/// is a plain enumeration and the row shape repeats exactly.
private struct ToolSummaryRow: View {
    let name: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
