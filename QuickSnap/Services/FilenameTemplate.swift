//
//  FilenameTemplate.swift
//  QuickSnap
//

import Foundation

/// What a capture knows about itself at naming time. Everything is optional
/// except the date, because area and full-screen captures don't always have
/// a meaningful window title, and a template shouldn't break when a token
/// has nothing to fill it with.
nonisolated struct FilenameContext: Sendable {
    var date = Date()
    /// Frontmost app at capture time, or the captured window's owner.
    var appName: String?
    var windowTitle: String?
    /// Pixel dimensions of the final image.
    var pixelWidth: Int?
    var pixelHeight: Int?
}

/// Renders the user's filename template into a real, safe filename.
///
/// Tokens are `{name}`; anything else in the template is a literal. Unknown
/// tokens are left as-is rather than silently deleted, so a typo is visible
/// in the preview instead of quietly producing the wrong name.
nonisolated enum FilenameTemplate {
    /// Reproduces the original hardcoded convention exactly
    /// (`QuickSnap 2026-08-01 at 12.30.45`), so the default behaviour is
    /// unchanged for anyone who never touches the setting.
    static let defaultTemplate = "QuickSnap {date} at {time}"

    /// Token name → what it inserts, for the settings legend. Ordered for
    /// display, hence an array rather than a dictionary.
    static let tokens: [(token: String, description: String)] = [
        ("{date}", "Date, 2026-08-01"),
        ("{time}", "Time, 12.30.45"),
        ("{year}", "2026"),
        ("{month}", "08"),
        ("{day}", "01"),
        ("{app}", "Frontmost app, or the captured window's app"),
        ("{window}", "Captured window's title"),
        ("{width}", "Pixel width"),
        ("{height}", "Pixel height"),
        ("{counter}", "Number that increments with each capture"),
        ("{random}", "Six random characters"),
    ]

    /// Characters that can't appear in a filename. `/` is the path separator
    /// and `:` is what Finder displays as `/`; both are replaced rather than
    /// stripped so words don't run together.
    private static let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")

    /// Renders `template` against `context`, falling back to the default
    /// template when the result would be empty (an all-token template whose
    /// tokens are all unavailable, or a blank setting).
    ///
    /// `counter` is passed in rather than read here so this stays pure and
    /// testable; `AppSettings.nextFilenameCounter()` is what advances it.
    static func render(
        _ template: String,
        context: FilenameContext,
        counter: Int
    ) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        let source = trimmed.isEmpty ? defaultTemplate : trimmed

        var result = source
        for (token, value) in replacements(for: context, counter: counter) {
            result = result.replacingOccurrences(of: token, with: value)
        }

        let sanitized = sanitize(result)
        return sanitized.isEmpty
            ? sanitize(renderDefault(context: context, counter: counter))
            : sanitized
    }

    private static func renderDefault(context: FilenameContext, counter: Int) -> String {
        var result = defaultTemplate
        for (token, value) in replacements(for: context, counter: counter) {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    private static func replacements(
        for context: FilenameContext,
        counter: Int
    ) -> [(String, String)] {
        [
            ("{date}", formatted(context.date, "yyyy-MM-dd")),
            ("{time}", formatted(context.date, "HH.mm.ss")),
            ("{year}", formatted(context.date, "yyyy")),
            ("{month}", formatted(context.date, "MM")),
            ("{day}", formatted(context.date, "dd")),
            ("{app}", context.appName ?? ""),
            ("{window}", context.windowTitle ?? ""),
            ("{width}", context.pixelWidth.map(String.init) ?? ""),
            ("{height}", context.pixelHeight.map(String.init) ?? ""),
            ("{counter}", String(counter)),
            ("{random}", randomSuffix()),
        ]
    }

    /// Strips characters the filesystem or Finder can't take, collapses the
    /// runs of whitespace an empty token leaves behind, and trims leading
    /// dots (which would make the file hidden).
    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: illegalCharacters)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }

        // HFS+/APFS cap component names at 255 bytes; leave room for the
        // extension and any de-duplication suffix.
        return String(trimmed.prefix(200))
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func randomSuffix() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).compactMap { _ in alphabet.randomElement() })
    }
}
