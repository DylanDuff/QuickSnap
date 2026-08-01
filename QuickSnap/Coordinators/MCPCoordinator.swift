//
//  MCPCoordinator.swift
//  QuickSnap
//

import AppKit
import Combine
import Network

/// The capture operations the MCP tools drive. `CaptureCoordinator`
/// conforms; this protocol is what keeps the server from reaching into it.
@MainActor
protocol MCPCaptureHost: AnyObject {
    /// Nil when the user cancelled or the overlay timed out.
    func captureInteractiveArea(timeout: TimeInterval) async throws -> CGImage?
    func captureWindow(matchingApp app: String, title: String?) async throws -> (image: CGImage, description: String)
    func captureDisplay(index: Int?) async throws -> CGImage
    func recognizeText(matchingApp app: String?, title: String?) async throws -> String
    func capturableWindows() async throws -> [String]
}

/// Failures worth explaining to a model rather than to a developer — every
/// message is written to tell an agent what to do next.
enum MCPToolError: LocalizedError {
    case screenRecordingDenied
    case captureSessionBusy
    case windowNotFound(app: String, available: [String])
    case displayNotFound(available: Int)
    case captureNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "QuickSnap doesn't have Screen Recording permission, so it can't capture anything. Ask the user to grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch QuickSnap."
        case .captureSessionBusy:
            return "A capture is already in progress. Wait for it to finish and try again."
        case .windowNotFound(let app, let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "No on-screen window matches \"\(app)\". Currently open: \(list)."
        case .displayNotFound(let available):
            return "No such display. There \(available == 1 ? "is" : "are") \(available) connected."
        case .captureNotFound(let name):
            return "No saved capture named \"\(name)\". Use list_recent_captures to see what exists."
        }
    }
}

enum MCPServerState: Equatable {
    case stopped
    case running(port: UInt16)
    case failed(String)
}

/// Published server state, so the settings UI can show what the server is
/// actually doing without owning the coordinator (the Settings scene and the
/// app's `CaptureCoordinator` are in different object graphs).
@MainActor
final class MCPServerStatus: nonisolated ObservableObject {
    static let shared = MCPServerStatus()
    @Published fileprivate(set) var state: MCPServerState = .stopped
    private init() {}
}

/// Serves QuickSnap's capture surface to MCP clients over an authenticated
/// loopback HTTP endpoint.
///
/// **Transport is HTTP, not stdio.** An MCP client starts a stdio server as a
/// child process; QuickSnap is a menu-bar app that is already running, so
/// there is nothing to launch. The alternative — a helper executable in the
/// bundle forwarding over XPC — buys nothing here beyond avoiding a socket,
/// at the cost of a second binary and an IPC protocol to design.
///
/// Because a socket *is* the trade, the security posture is deliberate: bound
/// to 127.0.0.1 only, off by default, a bearer token generated per install
/// and kept in the Keychain, `Origin` validated against DNS rebinding, and a
/// toast whenever an agent captures something without the user's involvement.
/// Full reference in `docs/mcp.md`.
@MainActor
final class MCPCoordinator {
    weak var host: (any MCPCaptureHost)?

    /// How long an interactive selection waits before giving up. Long enough
    /// for someone to notice the overlay and drag; short enough that a
    /// forgotten call doesn't pin the overlay on screen indefinitely.
    private static let interactiveTimeout: TimeInterval = 90

    /// Longest edge of the image returned inline. Full resolution goes back
    /// as a file path instead — see `ImageResizer`.
    private static let maxImageDimension = 1568

    /// Anything larger is not an MCP request; refuse it rather than buffer it.
    private static let maxRequestBytes = 1_048_576

    private static let endpointPath = "/mcp"

    /// What the listener is currently set up for, so the UserDefaults
    /// observer can ignore the vast majority of changes.
    private struct Configuration: Equatable {
        let isEnabled: Bool
        let port: UInt16
    }

    private var listener: NWListener?
    private var defaultsObserver: NSObjectProtocol?
    private var appliedConfiguration: Configuration?

    // MARK: - Lifecycle

    /// Starts the server if the setting is on, and keeps it in step with the
    /// setting from then on. Same shape as `HotkeyCoordinator`: UserDefaults
    /// changes fire constantly, so the applied configuration is diffed first.
    func startIfEnabled() {
        applyConfiguration()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyConfiguration()
            }
        }
    }

    private func applyConfiguration() {
        let configuration = Configuration(isEnabled: AppSettings.isMCPServerEnabled, port: AppSettings.mcpServerPort)
        guard configuration != appliedConfiguration else { return }
        appliedConfiguration = configuration

        stop()
        guard configuration.isEnabled else { return }
        start(on: configuration.port)
    }

    private func start(on port: UInt16) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Binding the local endpoint — rather than passing `on:` — is what
            // keeps this off every other interface. A capture server reachable
            // from the LAN would be a different product.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port) ?? 8787
            )

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                MainActor.assumeIsolated {
                    Self.accept(connection) { [weak self] request in
                        await self?.respond(to: request) ?? HTTPMessage.response(status: 503)
                    }
                }
            }
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        MCPServerStatus.shared.state = .running(port: port)
                    case .failed(let error):
                        MCPServerStatus.shared.state = .failed(Self.describe(error, port: port))
                    case .cancelled:
                        MCPServerStatus.shared.state = .stopped
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            MCPServerStatus.shared.state = .failed(Self.describe(error, port: port))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        MCPServerStatus.shared.state = .stopped
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if case NWError.posix(.EADDRINUSE) = error {
            return "Port \(port) is already in use. Choose another port."
        }
        return error.localizedDescription
    }

    // MARK: - Connections

    /// Reads one request, answers it, and closes. No keep-alive: a single
    /// exchange per connection means there is no partially-consumed stream to
    /// track, and MCP clients reconnect per call anyway.
    private static func accept(
        _ connection: NWConnection,
        handler: @escaping @MainActor (HTTPMessage.Request) async -> Data
    ) {
        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
                MainActor.assumeIsolated {
                    if let chunk { buffer.append(chunk) }

                    guard buffer.count <= maxRequestBytes else {
                        return finish(connection, with: HTTPMessage.response(status: 413))
                    }

                    do {
                        guard let request = try HTTPMessage.parse(buffer) else {
                            guard error == nil, !isComplete else {
                                return connection.cancel()
                            }
                            return readMore()
                        }
                        Task { finish(connection, with: await handler(request)) }
                    } catch {
                        finish(connection, with: HTTPMessage.response(status: 400))
                    }
                }
            }
        }

        connection.start(queue: .main)
        readMore()
    }

    private static func finish(_ connection: NWConnection, with response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Request handling

    private func respond(to request: HTTPMessage.Request) async -> Data {
        guard HTTPMessage.isOriginAllowed(request.header("origin")) else {
            return HTTPMessage.response(status: 403)
        }
        guard request.path.hasPrefix(Self.endpointPath) else {
            return HTTPMessage.response(status: 404)
        }
        guard isAuthorized(request) else {
            return HTTPMessage.response(status: 401)
        }
        guard request.method == "POST" else {
            return HTTPMessage.response(status: 405)
        }
        guard let rpc = MCPProtocol.parseRequest(request.body) else {
            return HTTPMessage.response(
                status: 200,
                json: MCPProtocol.failure(id: nil, code: .parseError, message: "Request body is not a JSON-RPC message.")
            )
        }

        // A notification expects no body at all, only an acknowledgement.
        guard let id = rpc.id else {
            return HTTPMessage.response(status: 202)
        }

        switch rpc.method {
        case "initialize":
            return HTTPMessage.response(status: 200, json: MCPProtocol.result(id: id, MCPProtocol.initializeResult(appVersion: Self.appVersion)))

        case "ping":
            return HTTPMessage.response(status: 200, json: MCPProtocol.result(id: id, .object([:])))

        case "tools/list":
            return HTTPMessage.response(status: 200, json: MCPProtocol.result(id: id, .object(["tools": MCPProtocol.toolCatalogue])))

        case "tools/call":
            guard let name = rpc.toolName, let tool = MCPProtocol.Tool(rawValue: name) else {
                return HTTPMessage.response(
                    status: 200,
                    json: MCPProtocol.failure(id: id, code: .invalidParams, message: "Unknown tool: \(rpc.toolName ?? "(none)")")
                )
            }
            let result = await call(tool, arguments: rpc.arguments)
            return HTTPMessage.response(status: 200, json: MCPProtocol.result(id: id, result))

        default:
            return HTTPMessage.response(
                status: 200,
                json: MCPProtocol.failure(id: id, code: .methodNotFound, message: "Unsupported method: \(rpc.method)")
            )
        }
    }

    private func isAuthorized(_ request: HTTPMessage.Request) -> Bool {
        guard let expected = AppSettings.mcpAuthToken() else { return false }
        guard let provided = request.header("authorization") else { return false }
        return provided == "Bearer \(expected)"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Tools

    private func call(_ tool: MCPProtocol.Tool, arguments: JSONValue) async -> JSONValue {
        guard let host else { return MCPProtocol.toolFailure("QuickSnap isn't ready to capture yet.") }

        do {
            switch tool {
            case .captureArea:
                guard let image = try await host.captureInteractiveArea(timeout: Self.interactiveTimeout) else {
                    return MCPProtocol.toolFailure("The user cancelled the selection, or didn't make one in time.")
                }
                return await imageResult(image, summary: "The user selected this screen region.")

            case .captureWindow:
                guard let app = arguments.trimmedString("app") else {
                    return MCPProtocol.toolFailure("`app` is required. Use list_windows to see what's open.")
                }
                let capture = try await host.captureWindow(matchingApp: app, title: arguments.trimmedString("title"))
                return await imageResult(capture.image, summary: "Window: \(capture.description)")

            case .captureScreen:
                let image = try await host.captureDisplay(index: arguments["display"]?.intValue)
                return await imageResult(image, summary: "Full screen capture.")

            case .readScreenText:
                let text = try await host.recognizeText(
                    matchingApp: arguments.trimmedString("app"),
                    title: arguments.trimmedString("title")
                )
                return MCPProtocol.toolResult(text: [text.isEmpty ? "No text was recognised on screen." : text])

            case .listWindows:
                let windows = try await host.capturableWindows()
                guard !windows.isEmpty else {
                    return MCPProtocol.toolResult(text: ["No capturable windows are on screen."])
                }
                return MCPProtocol.toolResult(text: [windows.map { "- \($0)" }.joined(separator: "\n")])

            case .listRecentCaptures:
                return listRecentCaptures(limit: arguments["limit"]?.intValue ?? 10)

            case .getCapture:
                guard let name = arguments.trimmedString("name") else {
                    return MCPProtocol.toolFailure("`name` is required.")
                }
                guard let entry = CaptureLibrary.entry(named: name),
                      let data = try? Data(contentsOf: entry.url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    throw MCPToolError.captureNotFound(name: name)
                }
                return await imageResult(image, summary: entry.name, fullResolutionPath: entry.url.path)
            }
        } catch {
            return MCPProtocol.toolFailure(error.localizedDescription)
        }
    }

    private func listRecentCaptures(limit: Int) -> JSONValue {
        let entries = CaptureLibrary.recent(limit: min(max(limit, 1), 50))
        guard !entries.isEmpty else {
            return MCPProtocol.toolResult(text: ["QuickSnap hasn't saved any captures yet."])
        }

        let formatter = ISO8601DateFormatter()
        let lines = entries.map { entry in
            "- \(entry.name) — \(formatter.string(from: entry.modifiedAt)), \(entry.byteCount / 1024) KB\n  \(entry.url.path)"
        }
        return MCPProtocol.toolResult(text: [lines.joined(separator: "\n")])
    }

    /// Returns a downscaled image inline plus the path to the full-resolution
    /// file, so an agent that needs the detail can read it rather than having
    /// several megabytes of base64 pushed into its context.
    private func imageResult(
        _ image: CGImage,
        summary: String,
        fullResolutionPath: String? = nil
    ) async -> JSONValue {
        let dimensions = "\(image.width)×\(image.height) px"
        let encoded = await Task.detached(priority: .userInitiated) {
            (
                inline: try? ScreenshotSaver.imageData(
                    ImageResizer.downscaled(image, maxDimension: Self.maxImageDimension),
                    format: .png
                ),
                // Fresh captures aren't saved to the user's folder (the
                // after-capture actions don't apply to agent requests), so a
                // temp file is what backs the path.
                path: fullResolutionPath ?? (try? ScreenshotSaver.writeTemporaryImage(image, format: .png))?.path
            )
        }.value

        guard let inline = encoded.inline else {
            return MCPProtocol.toolFailure("The capture couldn't be encoded.")
        }

        var text = [summary]
        if let path = encoded.path {
            text.append("Full resolution (\(dimensions)): \(path)")
        }
        return MCPProtocol.toolResult(text: text, images: [inline])
    }
}
