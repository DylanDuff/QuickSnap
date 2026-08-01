//
//  ImmichClient.swift
//  QuickSnap
//

import Foundation

/// Where uploads go and how we authenticate. Assembled by
/// `AppSettings.immichCredentials` (server URL from UserDefaults, API key
/// from the Keychain) and handed to the stateless client.
nonisolated struct ImmichCredentials: Sendable, Equatable {
    /// The instance's web root — no `/api` suffix. Shared links are built
    /// off this, API calls off `apiBaseURL`.
    let serverURL: URL
    let apiKey: String

    var apiBaseURL: URL {
        serverURL.appendingPathComponent("api")
    }
}

nonisolated struct ImmichAlbum: Sendable, Decodable, Identifiable, Hashable {
    let id: String
    let albumName: String
}

nonisolated enum ImmichError: LocalizedError {
    case notConfigured
    case invalidServerURL
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int, message: String?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Immich isn't set up yet. Add your server address and API key in Settings → Uploading."
        case .invalidServerURL:
            return "That server address isn't a valid URL. It should look like https://immich.example.com."
        case .unauthorized:
            return "Immich rejected the API key. Check it in Settings → Uploading."
        case .forbidden:
            return "This API key doesn't have permission for that. It needs asset.upload, and album or shared-link permissions if you use those options."
        case .notFound:
            return "Immich returned 404. Check the server address — it should be the instance's root, not a page inside it."
        case .server(let status, let message):
            return message.map { "Immich returned \(status): \($0)" } ?? "Immich returned HTTP \(status)."
        case .unexpectedResponse:
            return "Immich returned a response QuickSnap couldn't read."
        }
    }
}

/// Thin, stateless wrapper over the Immich REST API (spec 3.1.0, base path
/// `/api`, `x-api-key` auth). UI-agnostic like the other Services — it takes
/// credentials and plain values and returns values or throws.
///
/// Immich has no notion of a client-chosen folder: `POST /api/assets` has no
/// path field, and the server's Folders view is read-only (it browses by the
/// `originalPath` the server assigns from its own storage template). The only
/// grouping a client controls is the **album**, which is why the settings
/// offer an album picker rather than a folder chooser.
nonisolated enum ImmichClient {
    /// Built per call rather than cached, so a timeout change in Settings
    /// takes effect on the next upload instead of at the next launch.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = AppSettings.uploadTimeoutSeconds
        configuration.timeoutIntervalForResource = AppSettings.uploadTimeoutSeconds * 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - Server address

    /// Turns whatever the user typed into the instance's web root.
    /// Tolerates a trailing slash and a trailing `/api` (people paste the
    /// API base as often as the web root), and fills in a missing scheme —
    /// `http` for LAN addresses, `https` otherwise, which is what a
    /// self-hosted instance almost always wants.
    static func normalizedServerURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            text = (isLocalAddress(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }

    /// Private-range IPv4, loopback, or a `.local` hostname — the cases an
    /// unprefixed address is overwhelmingly likely to be plain HTTP.
    private static func isLocalAddress(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare == "localhost" || bare.lowercased().hasSuffix(".local") { return true }

        let octets = bare.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    // MARK: - Connection

    /// Name (or email) of the account the API key belongs to — the "Test
    /// connection" call, since it exercises both the address and the key.
    static func currentUserName(_ credentials: ImmichCredentials) async throws -> String {
        struct User: Decodable {
            let name: String?
            let email: String
        }
        let user: User = try await get("users/me", credentials: credentials)
        return user.name?.isEmpty == false ? user.name! : user.email
    }

    // MARK: - Albums

    static func albums(_ credentials: ImmichCredentials) async throws -> [ImmichAlbum] {
        let albums: [ImmichAlbum] = try await get("albums", credentials: credentials)
        return albums.sorted {
            $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending
        }
    }

    static func createAlbum(named name: String, credentials: ImmichCredentials) async throws -> ImmichAlbum {
        try await send(
            "albums",
            method: "POST",
            json: ["albumName": name],
            credentials: credentials
        )
    }

    static func addAssets(_ assetIds: [String], toAlbum albumId: String, credentials: ImmichCredentials) async throws {
        struct Result: Decodable { let success: Bool }
        // Response is a per-asset result array; a failure here is reported
        // separately from the upload itself, which already succeeded.
        let _: [Result] = try await send(
            "albums/\(albumId)/assets",
            method: "PUT",
            json: ["ids": assetIds],
            credentials: credentials
        )
    }

    // MARK: - Shared links

    /// Public link to a single asset — `https://<server>/share/<key>`.
    static func createSharedLink(assetId: String, credentials: ImmichCredentials) async throws -> URL {
        struct SharedLink: Decodable {
            let key: String
        }
        let link: SharedLink = try await send(
            "shared-links",
            method: "POST",
            json: ["type": "INDIVIDUAL", "assetIds": [assetId]],
            credentials: credentials
        )
        guard let url = URL(string: "\(credentials.serverURL.absoluteString)/share/\(link.key)") else {
            throw ImmichError.unexpectedResponse
        }
        return url
    }

    // MARK: - Upload

    /// `POST /api/assets`, multipart. `fileCreatedAt`/`fileModifiedAt` are
    /// required by the API; we send the capture time for both.
    ///
    /// `deviceAssetId`/`deviceId` are sent for compatibility with older
    /// Immich releases that required them — the current schema is a
    /// non-strict Zod object, so it silently drops fields it doesn't know
    /// rather than rejecting the request.
    static func upload(
        imageData: Data,
        filename: String,
        mimeType: String,
        capturedAt: Date,
        credentials: ImmichCredentials
    ) async throws -> (assetId: String, isDuplicate: Bool) {
        struct UploadResponse: Decodable {
            let id: String
            /// `created` or `duplicate` — Immich dedupes by checksum.
            let status: String
        }

        let boundary = "QuickSnap-\(UUID().uuidString)"
        let timestamp = ISO8601DateFormatter().string(from: capturedAt)
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("deviceAssetId", "\(filename)-\(Int(capturedAt.timeIntervalSince1970))")
        appendField("deviceId", "QuickSnap")
        appendField("fileCreatedAt", timestamp)
        appendField("fileModifiedAt", timestamp)
        appendField("filename", filename)

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n")

        var request = try makeRequest("assets", method: "POST", credentials: credentials)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let response: UploadResponse = try await perform(request)
        return (response.id, response.status == "duplicate")
    }

    // MARK: - Request plumbing

    private static func makeRequest(
        _ path: String,
        method: String,
        credentials: ImmichCredentials
    ) throws -> URLRequest {
        var request = URLRequest(url: credentials.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func get<T: Decodable>(_ path: String, credentials: ImmichCredentials) async throws -> T {
        try await perform(makeRequest(path, method: "GET", credentials: credentials))
    }

    private static func send<T: Decodable>(
        _ path: String,
        method: String,
        json: [String: any Sendable],
        credentials: ImmichCredentials
    ) async throws -> T {
        var request = try makeRequest(path, method: method, credentials: credentials)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(request)
    }

    private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await makeSession().data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unexpectedResponse }

        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw ImmichError.unauthorized
            case 403: throw ImmichError.forbidden
            case 404: throw ImmichError.notFound
            default: throw ImmichError.server(status: http.statusCode, message: errorMessage(from: data))
            }
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ImmichError.unexpectedResponse
        }
    }

    /// Immich errors come back as `{ "message": …, "statusCode": … }`, where
    /// `message` is sometimes a string and sometimes an array of validation
    /// strings.
    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let messages = object["message"] as? [String] { return messages.joined(separator: ", ") }
        return object["error"] as? String
    }
}


// MARK: - Multipart helper

/// `nonisolated` for the same reason the Services are: this file's default
/// isolation is `MainActor`, and the multipart body is assembled off it.
nonisolated private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
