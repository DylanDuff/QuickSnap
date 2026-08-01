//
//  ImageFormat.swift
//  QuickSnap
//

import AppKit
import UniformTypeIdentifiers

/// Output encoding for saved, exported and uploaded captures.
///
/// PNG is lossless and the right default for screenshots (text stays crisp);
/// JPEG and HEIC exist because a full-screen Retina PNG is easily 10 MB,
/// which matters most when every capture is being uploaded.
nonisolated enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    /// Sent as `Content-Type` when uploading.
    var mimeType: String {
        contentType.preferredMIMEType ?? "application/octet-stream"
    }

    /// Whether the quality setting applies — PNG is lossless, so a quality
    /// slider would be meaningless there.
    var isLossy: Bool {
        self != .png
    }

    /// True when the format can't represent transparency. Window captures
    /// with a transparent background style keep their alpha, so those get
    /// silently kept as PNG rather than flattened onto black — see
    /// `ScreenshotSaver.effectiveFormat(for:)`.
    var discardsAlpha: Bool {
        self == .jpeg
    }
}
