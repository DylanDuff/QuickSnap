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
    /// What the capture shows, in prose ("login form validation error").
    /// Nil at save time and filled in later — a model can't be waited on
    /// before writing the file (see `ResolvedFilename`). `{describe}` slugs
    /// it; the prose is kept as-is here so the index can reuse the same
    /// value.
    var description: String?
}

/// A capture's name kept as its *inputs* rather than as a finished string.
///
/// `{describe}` can't be resolved before the file is written — the save must
/// never block on a model — so the file lands under a name with that token
/// empty and is renamed when the description arrives. Re-rendering the
/// template at that point has to reproduce every other token exactly, which
/// means holding on to the same context and the same `{counter}` value
/// (`AppSettings.nextFilenameCounter()` advances on every call, and
/// `{time}`/`{random}` would drift too).
nonisolated struct ResolvedFilename: Sendable {
    let template: String
    var context: FilenameContext
    let counter: Int
    /// `{random}`'s value, drawn once and kept — re-rolling it on the second
    /// render would rename the file to a name that shares nothing with the
    /// one it was written under.
    let randomSuffix: String = FilenameTemplate.randomSuffix()

    var value: String {
        FilenameTemplate.render(
            template,
            context: context,
            counter: counter,
            randomSuffix: randomSuffix
        )
    }

    /// Whether this name is still waiting on a description to be complete.
    var awaitsDescription: Bool {
        context.description == nil && FilenameTemplate.usesDescription(template)
    }

    func describing(_ description: String) -> ResolvedFilename {
        var described = self
        described.context.description = description
        return described
    }
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
        ("{describe}", "What the screenshot shows, from Apple Intelligence"),
    ]

    /// Whether `template` asks for a description — i.e. whether a capture
    /// saved under it is worth the post-write model round trip at all.
    static func usesDescription(_ template: String) -> Bool {
        template.contains(descriptionToken)
    }

    /// Appends `{describe}` to `template` if it isn't already there, so the
    /// settings toggle can turn it on without the user editing the template
    /// by hand. Appended rather than inserted: the description is the part
    /// of a name people scan for, and it reads better after the timestamp
    /// than in front of it.
    static func addingDescription(to template: String) -> String {
        guard !usesDescription(template) else { return template }
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? descriptionToken : "\(trimmed) \(descriptionToken)"
    }

    /// The inverse, collapsing the whitespace the removed token leaves
    /// behind. Falls back to the default template if that empties the
    /// string, since a blank template isn't a name.
    static func removingDescription(from template: String) -> String {
        let stripped = template
            .replacingOccurrences(of: descriptionToken, with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return stripped.isEmpty ? defaultTemplate : stripped
    }

    private static let descriptionToken = "{describe}"

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
    /// `randomSuffix` is a parameter for the same reason — rendering the
    /// same name twice (which `ResolvedFilename` does, either side of a
    /// `{describe}` rename) has to produce the same string.
    static func render(
        _ template: String,
        context: FilenameContext,
        counter: Int,
        randomSuffix: String = randomSuffix()
    ) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        let source = trimmed.isEmpty ? defaultTemplate : trimmed
        let replacements = replacements(for: context, counter: counter, randomSuffix: randomSuffix)

        var result = source
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }

        let sanitized = sanitize(result)
        guard sanitized.isEmpty else { return sanitized }

        var fallback = defaultTemplate
        for (token, value) in replacements {
            fallback = fallback.replacingOccurrences(of: token, with: value)
        }
        return sanitize(fallback)
    }

    private static func replacements(
        for context: FilenameContext,
        counter: Int,
        randomSuffix: String
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
            ("{random}", randomSuffix),
            (descriptionToken, context.description.map { slug($0) } ?? ""),
        ]
    }

    /// A lowercase ASCII kebab-case slug: `Login form: validation error` →
    /// `login-form-validation-error`.
    ///
    /// The input is a model's output going into a filesystem call, so this
    /// is a whitelist rather than a blacklist — only `a`–`z` and `0`–`9`
    /// survive, everything else becomes a separator. Path separators,
    /// leading dots and anything Finder objects to therefore can't get
    /// through by construction. Truncation is on a word boundary, so a long
    /// description ends in a whole word rather than mid-syllable.
    static func slug(_ text: String, maxLength: Int = 48) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))

        var words: [String] = []
        var current = ""
        for character in folded.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        var slug = ""
        for word in words {
            if slug.isEmpty {
                slug = String(word.prefix(maxLength))
            } else if slug.count + 1 + word.count <= maxLength {
                slug += "-" + word
            } else {
                break
            }
        }
        return slug
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

    static func randomSuffix() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<6).compactMap { _ in alphabet.randomElement() })
    }
}
