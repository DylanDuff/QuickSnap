//
//  AWSSignatureV4.swift
//  QuickSnap
//

import CryptoKit
import Foundation

/// AWS Signature Version 4 request signing, hand-rolled on CryptoKit so the
/// S3 support needs no SDK or third-party dependency.
///
/// Only what an S3-compatible object store needs is implemented: signed
/// headers with a known payload hash (`AWS4-HMAC-SHA256`, no chunked
/// streaming, no presigned URLs, no STS session tokens beyond passing one
/// through). That covers PUT/GET/HEAD against AWS, Cloudflare R2, Backblaze
/// B2, MinIO, Wasabi, and DigitalOcean Spaces.
///
/// The two places implementations usually get this wrong, both handled here:
///
/// 1. **URI encoding.** The canonical URI must be encoded per AWS's rules —
///    unreserved characters are `A-Za-z0-9-_.~` and *everything* else is
///    percent-encoded with uppercase hex — which is not what
///    `addingPercentEncoding(withAllowedCharacters:)` does out of the box.
///    Path segments keep their separating slashes; query values don't.
/// 2. **Query ordering.** The canonical query string must be sorted by
///    encoded key, with encoded values.
nonisolated enum AWSSignatureV4 {
    struct Credentials: Sendable {
        let accessKeyID: String
        let secretAccessKey: String
        /// Only used by temporary STS credentials; nil for the long-lived
        /// keys a self-hosted store issues.
        var sessionToken: String?
    }

    /// Signs `request` in place: adds `x-amz-date`, `x-amz-content-sha256`,
    /// the optional session token, and the `Authorization` header.
    ///
    /// `payload` must be the exact bytes being sent — the payload hash is
    /// part of the signature, so a mismatch fails with `SignatureDoesNotMatch`.
    static func sign(
        _ request: inout URLRequest,
        payload: Data,
        credentials: Credentials,
        region: String,
        service: String = "s3",
        date: Date = Date()
    ) {
        guard let url = request.url, url.host != nil else { return }

        let amzDate = Self.amzDate(from: date)
        let dateStamp = Self.dateStamp(from: date)
        let payloadHash = sha256Hex(payload)

        // The Host header must be signed, and must match byte-for-byte what
        // URLSession actually puts on the wire — which includes the port
        // whenever it isn't the scheme's default. `URL.host` omits it, so
        // signing that value alone breaks against anything on a non-standard
        // port (a self-hosted MinIO on :9000, say) with SignatureDoesNotMatch.
        request.setValue(hostHeader(for: url), forHTTPHeaderField: "host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }

        // Every header actually on the request gets signed, so provider
        // extras (x-amz-acl, content-type) are covered automatically.
        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { (name: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.name < $1.name }
        let signedHeaders = headers.map(\.name).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.name):\($0.value)\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(for: url),
            canonicalQueryString(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signature = hexString(
            hmac(Data(stringToSign.utf8), key: signingKey(
                secret: credentials.secretAccessKey,
                dateStamp: dateStamp,
                region: region,
                service: service
            ))
        )

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    /// `host` or `host:port`, matching URLSession's own Host header: the
    /// port appears only when it isn't the scheme's default.
    static func hostHeader(for url: URL) -> String {
        guard let host = url.host else { return "" }
        let defaultPort = url.scheme?.lowercased() == "http" ? 80 : 443
        guard let port = url.port, port != defaultPort else { return host }
        return "\(host):\(port)"
    }

    // MARK: - Canonicalization

    /// The URL path, encoded per AWS's rules (S3 encodes once, not twice).
    ///
    /// Deliberately reads `percentEncodedPath` rather than `URL.path`:
    /// `URL.path` **drops a trailing slash**, so a bucket-root request like
    /// `/bucket/?list-type=2` would be signed as `/bucket` while the server
    /// signs `/bucket/`, failing with `SignatureDoesNotMatch`. Each segment
    /// is then decoded and re-encoded so the canonical form is ours
    /// regardless of how the caller encoded it; splitting without omitting
    /// empty subsequences is what preserves the leading and trailing slashes.
    private static func canonicalURI(for url: URL) -> String {
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        guard !rawPath.isEmpty else { return "/" }
        return rawPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let decoded = String(segment).removingPercentEncoding ?? String(segment)
                return uriEncode(decoded)
            }
            .joined(separator: "/")
    }

    private static func canonicalQueryString(for url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty
        else {
            return ""
        }
        // Written out rather than chained: the tuple inference in a
        // map/sorted/map chain blows up the type checker.
        var pairs: [(name: String, value: String)] = []
        for item in items {
            pairs.append((uriEncode(item.name), uriEncode(item.value ?? "")))
        }
        pairs.sort { left, right in
            left.name == right.name ? left.value < right.value : left.name < right.name
        }

        var encoded: [String] = []
        for pair in pairs {
            encoded.append("\(pair.name)=\(pair.value)")
        }
        return encoded.joined(separator: "&")
    }

    /// AWS's URI encoding: unreserved is `A-Za-z0-9-_.~`, everything else is
    /// percent-encoded with *uppercase* hex. Deliberately not built on
    /// `CharacterSet` percent-encoding, whose notion of "allowed" differs.
    static func uriEncode(_ string: String) -> String {
        var encoded = ""
        for byte in Array(string.utf8) {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    // MARK: - Crypto

    /// kSecret → kDate → kRegion → kService → kSigning.
    private static func signingKey(
        secret: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for component in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: hmac(Data(component.utf8), key: key))
        }
        return key
    }

    private static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func sha256Hex(_ data: Data) -> String {
        hexString(Data(SHA256.hash(data: data)))
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Timestamps

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC. A fixed POSIX locale and UTC zone are
    /// required — a user's locale or calendar must never reach these.
    private static func amzDate(from date: Date) -> String {
        formatter(format: "yyyyMMdd'T'HHmmss'Z'").string(from: date)
    }

    private static func dateStamp(from date: Date) -> String {
        formatter(format: "yyyyMMdd").string(from: date)
    }

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
