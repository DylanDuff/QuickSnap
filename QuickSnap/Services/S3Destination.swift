//
//  S3Destination.swift
//  QuickSnap
//

import Foundation

nonisolated struct S3Configuration: Sendable, Equatable {
    /// Service endpoint without a bucket, e.g.
    /// `https://<account>.r2.cloudflarestorage.com` or `http://minio.local:9000`.
    let endpoint: URL
    let region: String
    let bucket: String
    let accessKeyID: String
    let secretAccessKey: String
    /// Prepended to the object key, e.g. `screenshots/`.
    let keyPrefix: String
    /// CDN or custom domain the bucket is served from. When set, links are
    /// built off this instead of the API endpoint — the endpoint is often
    /// not publicly readable even when the bucket's contents are (R2 in
    /// particular serves objects from a completely different domain).
    let publicBaseURL: String?
    /// `endpoint/bucket/key` rather than `bucket.endpoint/key`. Required by
    /// MinIO and fine on R2/B2; AWS proper prefers virtual-hosted.
    let usesPathStyle: Bool
    /// Sends `x-amz-acl: public-read`. AWS and MinIO honour it; R2 rejects
    /// ACLs entirely, which is why it's opt-in rather than implied by
    /// wanting a link.
    let isPublicRead: Bool
}

nonisolated enum S3Error: LocalizedError {
    case invalidEndpoint
    case invalidObjectURL
    /// An S3 XML error, e.g. `SignatureDoesNotMatch` or `NoSuchBucket`.
    case service(code: String, message: String?)
    case http(status: Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "That endpoint isn't a valid URL. It should look like https://s3.example.com — the service address, without the bucket."
        case .invalidObjectURL:
            return "Couldn't build a URL for the uploaded object. Check the bucket name and key prefix."
        case .service(let code, let message):
            return Self.explanation(forCode: code) ?? message ?? "The storage service returned \(code)."
        case .http(let status):
            return "The storage service returned HTTP \(status)."
        case .unexpectedResponse:
            return "The storage service returned a response QuickSnap couldn't read."
        }
    }

    /// S3's error codes are precise and worth translating — they're the
    /// difference between "your clock is wrong" and "your key is wrong",
    /// which are otherwise both just a 403.
    private static func explanation(forCode code: String) -> String? {
        switch code {
        case "SignatureDoesNotMatch":
            return "The secret key doesn't match the access key ID, or the region is wrong for this endpoint."
        case "InvalidAccessKeyId":
            return "That access key ID doesn't exist on this service."
        case "AccessDenied":
            return "These credentials don't have permission for that bucket. Uploading needs s3:PutObject; the connection test also needs s3:ListBucket."
        case "NoSuchBucket":
            return "That bucket doesn't exist on this endpoint."
        case "RequestTimeTooSkewed":
            return "Your Mac's clock is too far from the server's. Check date & time settings."
        case "InvalidRequest", "InvalidArgument":
            return "The service rejected the request. If this is Cloudflare R2, turn off \"Make uploads publicly readable\" — R2 doesn't accept ACLs."
        default:
            return nil
        }
    }
}

/// Any S3-compatible object store: Cloudflare R2, Backblaze B2, MinIO,
/// Wasabi, DigitalOcean Spaces, or AWS S3 itself. One `PUT` per screenshot,
/// signed with `AWSSignatureV4`.
///
/// Unlike Immich, this has real paths — `keyPrefix` is a genuine folder
/// prefix — and the resulting link needs no second API call, since an
/// object's URL is deterministic.
nonisolated struct S3Destination: UploadDestination {
    let configuration: S3Configuration
    let copiesLink: Bool

    var providerName: String { "S3" }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    /// Normalizes a typed endpoint: fills in a missing scheme (`http` for
    /// LAN addresses, `https` otherwise) and drops a trailing slash.
    static func normalizedEndpoint(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = (isLocalAddress(text) ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }

    private static func isLocalAddress(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare == "localhost" || bare.lowercased().hasSuffix(".local") { return true }

        let octets = bare.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    // MARK: - Upload

    func upload(_ request: UploadRequest) async throws -> UploadOutcome {
        let key = objectKey(for: request)
        guard let url = requestURL(forKey: key) else { throw S3Error.invalidObjectURL }

        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("image/png", forHTTPHeaderField: "Content-Type")
        // Content-Length is deliberately NOT set: URLSession reserves it and
        // sets it from the body itself. Setting it here would put it in
        // SignedHeaders, and if URLSession then rewrote or dropped it the
        // server's recomputed signature wouldn't match ours.
        if configuration.isPublicRead {
            put.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        }
        AWSSignatureV4.sign(
            &put,
            payload: request.pngData,
            credentials: .init(
                accessKeyID: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey
            ),
            region: configuration.region
        )
        put.httpBody = request.pngData

        let (data, response) = try await Self.session.data(for: put)
        try Self.validate(response: response, data: data)

        return UploadOutcome(
            publicURL: copiesLink ? publicURL(forKey: key) : nil,
            detail: copiesLink ? nil : "Stored as \(key)"
        )
    }

    /// Verifies the credentials and bucket without writing anything: a
    /// `ListObjectsV2` asking for zero keys.
    func testConnection() async throws {
        guard var components = URLComponents(
            url: requestURL(forKey: "") ?? configuration.endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw S3Error.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "max-keys", value: "0"),
        ]
        guard let url = components.url else { throw S3Error.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        AWSSignatureV4.sign(
            &request,
            payload: Data(),
            credentials: .init(
                accessKeyID: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey
            ),
            region: configuration.region
        )

        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    // MARK: - Keys and URLs

    /// Prefix + a filesystem-safe filename. Spaces are replaced rather than
    /// encoded: they're legal in S3 keys but produce links that break when
    /// pasted into chat clients, and the timestamped default name is full
    /// of them.
    private func objectKey(for request: UploadRequest) -> String {
        var prefix = configuration.keyPrefix.trimmingCharacters(in: .whitespaces)
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        if !prefix.isEmpty, !prefix.hasSuffix("/") { prefix += "/" }

        let name = request.filename
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return prefix + name
    }

    /// The signed request's URL — path-style puts the bucket in the path,
    /// virtual-hosted puts it in the hostname.
    private func requestURL(forKey key: String) -> URL? {
        let encodedKey = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { AWSSignatureV4.uriEncode(String($0)) }
            .joined(separator: "/")

        if configuration.usesPathStyle {
            return URL(string: "\(configuration.endpoint.absoluteString)/\(configuration.bucket)/\(encodedKey)")
        }
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              let host = components.host
        else {
            return nil
        }
        components.host = "\(configuration.bucket).\(host)"
        components.path = "/\(encodedKey)"
        return components.url
    }

    /// The link handed to the user: the CDN/custom domain when configured,
    /// otherwise the same URL the upload went to.
    private func publicURL(forKey key: String) -> URL? {
        guard let base = configuration.publicBaseURL?.trimmingCharacters(in: .whitespaces), !base.isEmpty else {
            return requestURL(forKey: key)
        }
        let encodedKey = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { AWSSignatureV4.uriEncode(String($0)) }
            .joined(separator: "/")
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        return URL(string: "\(trimmed)/\(encodedKey)")
    }

    // MARK: - Errors

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let code = errorCode(in: data) {
                throw S3Error.service(code: code, message: element("Message", in: data))
            }
            throw S3Error.http(status: http.statusCode)
        }
    }

    private static func errorCode(in data: Data) -> String? {
        element("Code", in: data)
    }

    /// Pulls a single element out of S3's XML error body. A full parser
    /// would be overkill — these bodies are flat and tiny, and we only ever
    /// want `<Code>` and `<Message>`.
    private static func element(_ name: String, in data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex)
        else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
