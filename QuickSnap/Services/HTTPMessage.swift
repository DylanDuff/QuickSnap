//
//  HTTPMessage.swift
//  QuickSnap
//

import Foundation

/// Just enough HTTP/1.1 to serve MCP's Streamable HTTP transport: parse a
/// request with a `Content-Length` body, build a response. Pure functions on
/// bytes — the socket lives in `MCPCoordinator`.
///
/// Deliberately not a general-purpose server. It answers one endpoint on
/// loopback, closes every connection after one exchange (so there is no
/// keep-alive state to get wrong), and treats anything it doesn't understand
/// as a 400. Chunked transfer encoding is not supported: MCP clients send a
/// JSON body with a known length.
nonisolated enum HTTPMessage {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Lowercased field names — HTTP header names are case-insensitive
        /// and clients differ on casing.
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    /// Parses `data` if it holds a complete request, or returns nil if more
    /// bytes are needed. A malformed request throws so the caller can answer
    /// 400 rather than waiting forever for a body that will never arrive.
    static func parse(_ data: Data) throws -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expectedLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= expectedLength else { return nil }

        return Request(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: data[bodyStart..<(bodyStart + expectedLength)]
        )
    }

    enum ParseError: Error {
        case malformed
    }

    /// A complete response, ready to write. Always `Connection: close`.
    static func response(status: Int, json: Data? = nil) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        head += "Content-Length: \(json?.count ?? 0)\r\n"
        if json != nil {
            head += "Content-Type: application/json\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var response = Data(head.utf8)
        if let json { response.append(json) }
        return response
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }

    /// Whether an `Origin` header is safe to accept.
    ///
    /// The MCP spec requires local HTTP servers to validate this: without it
    /// any web page the user visits could POST to `127.0.0.1` from their
    /// browser and drive the server (DNS rebinding). A real MCP client sends
    /// no `Origin` at all, so absent is fine and only loopback origins are
    /// allowed through.
    static func isOriginAllowed(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        guard let host = URL(string: origin)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
