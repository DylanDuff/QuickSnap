//
//  MCPProtocol.swift
//  QuickSnap
//

import Foundation

/// The wire format for the MCP server: JSON-RPC 2.0 framing, the tool
/// catalogue, and result construction. Pure and stateless — everything that
/// runs, listens or captures lives in `MCPCoordinator`.
///
/// Hand-rolled rather than pulled from a package, for the same reason
/// `AWSSignatureV4` is: the surface actually used here is small, and this
/// project carries no third-party dependencies. Full reference in
/// `docs/mcp.md`.
nonisolated enum MCPProtocol {
    /// The spec revision this server implements. Clients echo their own; a
    /// mismatch is not fatal, so we answer with ours and let them decide.
    static let protocolVersion = "2025-06-18"

    static let serverName = "quicksnap"

    // MARK: - Requests

    struct Request: Sendable {
        /// Absent for a notification, which takes no response.
        let id: JSONValue?
        let method: String
        let params: JSONValue

        var isNotification: Bool { id == nil }
        var arguments: JSONValue { params["arguments"] ?? .object([:]) }
        var toolName: String? { params["name"]?.stringValue }
    }

    /// Parses a single JSON-RPC request. Batches are not supported — the
    /// 2025-06-18 revision removed them from MCP.
    static func parseRequest(_ body: Data) -> Request? {
        guard let json = JSONValue.parse(body),
              let method = json["method"]?.stringValue
        else {
            return nil
        }
        return Request(id: json["id"], method: method, params: json["params"] ?? .object([:]))
    }

    // MARK: - Responses

    enum ErrorCode: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }

    static func result(id: JSONValue, _ value: JSONValue) -> Data {
        JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": value,
        ]).serialized
    }

    static func failure(id: JSONValue?, code: ErrorCode, message: String) -> Data {
        JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object([
                "code": .number(Double(code.rawValue)),
                "message": .string(message),
            ]),
        ]).serialized
    }

    /// The `initialize` handshake result.
    static func initializeResult(appVersion: String) -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(appVersion),
            ]),
        ])
    }

    // MARK: - Tool results

    /// A successful tool result: any text lines, then any images.
    static func toolResult(text: [String], images: [Data] = []) -> JSONValue {
        var content: [JSONValue] = text.map { .object(["type": .string("text"), "text": .string($0)]) }
        content += images.map {
            .object([
                "type": .string("image"),
                "data": .string($0.base64EncodedString()),
                "mimeType": .string("image/png"),
            ])
        }
        return .object(["content": .array(content)])
    }

    /// A tool *failure*, which in MCP is a successful JSON-RPC response
    /// carrying `isError` — not a protocol-level error. The distinction
    /// matters: a protocol error is the client's problem to handle, while
    /// this is a result the model is meant to read and react to (retry with
    /// a different window, ask the user to grant permission).
    static func toolFailure(_ message: String) -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    // MARK: - Tool catalogue

    enum Tool: String, CaseIterable {
        case captureArea = "capture_area"
        case captureWindow = "capture_window"
        case captureScreen = "capture_screen"
        case readScreenText = "read_screen_text"
        case listWindows = "list_windows"
        case listRecentCaptures = "list_recent_captures"
        case getCapture = "get_capture"

        /// Whether the tool puts a selection overlay on screen and waits for
        /// the user. Only one of these can be in flight, and the client is
        /// told as much in the description so a model doesn't fire it
        /// speculatively.
        var isInteractive: Bool { self == .captureArea }
    }

    static var toolCatalogue: JSONValue {
        .array(Tool.allCases.map(descriptor(for:)))
    }

    private static func descriptor(for tool: Tool) -> JSONValue {
        switch tool {
        case .captureArea:
            return tool.descriptor(
                description: """
                    Ask the user to drag out a screen region, then return that \
                    screenshot. This puts an overlay on the user's screen and \
                    waits for them, so only use it when you actually need them \
                    to point at something — prefer capture_window or \
                    capture_screen otherwise. Returns nothing if they cancel.
                    """,
                properties: [:]
            )

        case .captureWindow:
            return tool.descriptor(
                description: """
                    Screenshot a single window without interrupting the user. \
                    Matches the frontmost window whose application name \
                    contains `app`. Use list_windows first if you are not sure \
                    what is open.
                    """,
                properties: [
                    "app": .stringProperty("Application name, or part of one — e.g. \"Xcode\", \"Safari\"."),
                    "title": .stringProperty("Optional: also require the window title to contain this."),
                ],
                required: ["app"]
            )

        case .captureScreen:
            return tool.descriptor(
                description: "Screenshot a whole display, without interrupting the user.",
                properties: [
                    "display": .integerProperty("Display index, 0 being the main display. Defaults to the display under the pointer."),
                ]
            )

        case .readScreenText:
            return tool.descriptor(
                description: """
                    Read the text currently on screen using on-device OCR, \
                    returning text only and no image. Cheaper than a \
                    screenshot when you only need to read something — a stack \
                    trace, a console pane, an error dialog. Reads a window when \
                    `app` is given, otherwise the whole display.
                    """,
                properties: [
                    "app": .stringProperty("Optional: read this application's frontmost window instead of the display."),
                    "title": .stringProperty("Optional: also require the window title to contain this."),
                ]
            )

        case .listWindows:
            return tool.descriptor(
                description: "List the windows currently on screen that can be captured, frontmost first.",
                properties: [:]
            )

        case .listRecentCaptures:
            return tool.descriptor(
                description: """
                    List screenshots QuickSnap has saved, newest first — the \
                    way to find a capture the user just took without asking \
                    them for a path.
                    """,
                properties: [
                    "limit": .integerProperty("How many to return. Defaults to 10, maximum 50."),
                ]
            )

        case .getCapture:
            return tool.descriptor(
                description: "Return a saved screenshot by the name given by list_recent_captures.",
                properties: [
                    "name": .stringProperty("The capture's file name, including its extension."),
                ],
                required: ["name"]
            )
        }
    }
}

private extension MCPProtocol.Tool {
    func descriptor(
        description: String,
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "name": .string(rawValue),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ]),
        ])
    }
}

private extension JSONValue {
    static func stringProperty(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integerProperty(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
