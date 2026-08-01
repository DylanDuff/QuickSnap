//
//  SensitiveContentDetector.swift
//  QuickSnap
//

import CoreGraphics
import Foundation

/// Something in a capture that probably shouldn't be uploaded, and where it
/// is.
///
/// **The matched text is deliberately not kept.** The whole point is that
/// this string is a secret; carrying it around invites it into a toast, a
/// log line or a diagnostics dump. Only the masked `preview` survives, which
/// is enough to tell two findings apart in a list.
nonisolated struct SensitiveMatch: Sendable, Identifiable, Equatable {
    let kind: Kind
    /// Where to redact, in image pixel coordinates (top-left origin).
    let rect: CGRect
    /// `AKIA••••••••••••3QY7` — enough to recognise, not enough to use.
    let preview: String
    let id = UUID()

    static func == (lhs: SensitiveMatch, rhs: SensitiveMatch) -> Bool {
        lhs.id == rhs.id
    }
}

extension SensitiveMatch {
    enum Kind: String, Sendable, CaseIterable {
        case awsAccessKey
        case apiToken
        case jsonWebToken
        case privateKey
        case bearerToken
        case cardNumber
        case iban
        case emailAddress
        case longHexString

        var label: String {
            switch self {
            case .awsAccessKey: return "AWS access key"
            case .apiToken: return "API token"
            case .jsonWebToken: return "JSON Web Token"
            case .privateKey: return "Private key"
            case .bearerToken: return "Bearer token"
            case .cardNumber: return "Card number"
            case .iban: return "Bank account (IBAN)"
            case .emailAddress: return "Email address"
            case .longHexString: return "Long hex string"
            }
        }

        /// Whether a finding of this kind is certain enough to **hold an
        /// upload**.
        ///
        /// The split is the difference between a feature people keep on and
        /// one they switch off. An email address or a hash in the corner of
        /// a window is extremely common and usually harmless; stopping every
        /// such capture would train people to bypass this immediately. A
        /// credential is neither common nor harmless, and there is no undo
        /// once it's a public URL. So the low-confidence kinds are still
        /// flagged and still one click from redaction — they just don't
        /// interrupt.
        var holdsUpload: Bool {
            switch self {
            case .awsAccessKey, .apiToken, .jsonWebToken, .privateKey, .bearerToken, .cardNumber, .iban:
                return true
            case .emailAddress, .longHexString:
                return false
            }
        }
    }
}

/// Finds likely credentials and personal identifiers in a capture's text.
///
/// **Regex is the floor, and the floor is what gates uploads.** It needs no
/// model, no network and no settings, it runs in microseconds over text
/// Vision has already produced, and it's deterministic — which is what makes
/// it safe to block an upload on. A model layer can only ever be additive
/// here; an upload held because a language model had a feeling would be
/// impossible to reason about.
///
/// **Biased toward flagging.** A false positive costs one click. A false
/// negative is a credential in a public URL with no undo. Where a pattern is
/// arguable, it's included at low confidence rather than left out.
nonisolated enum SensitiveContentDetector {
    /// Convenience for the upload path: OCR then classify. Returns nothing
    /// rather than throwing if recognition fails — a detector that errors at
    /// the user is a detector that gets switched off, and the upload it was
    /// checking still needs a decision.
    static func detect(in image: CGImage) async -> [SensitiveMatch] {
        let lines = (try? await TextRecognizer.recognizeLines(in: image)) ?? []
        return detect(in: lines)
    }

    static func detect(in lines: [RecognizedTextLine]) -> [SensitiveMatch] {
        lines.flatMap { line in
            patterns.flatMap { pattern in
                matches(of: pattern, in: line)
            }
        }
    }

    // MARK: - Patterns

    private struct Pattern {
        let kind: SensitiveMatch.Kind
        let expression: NSRegularExpression
        /// Second-stage check for patterns that are too broad on their own —
        /// a card number's Luhn checksum, say.
        var validate: (@Sendable (String) -> Bool)?

        init(_ kind: SensitiveMatch.Kind, _ pattern: String, validate: (@Sendable (String) -> Bool)? = nil) {
            self.kind = kind
            // Force-try: these are literals compiled at startup, so a bad one
            // is a programming error that should fail loudly in development
            // rather than silently stop detecting secrets in the field.
            self.expression = try! NSRegularExpression(pattern: pattern)
            self.validate = validate
        }
    }

    /// Character classes are deliberately permissive: this text came out of
    /// OCR, which confuses `0`/`O` and `1`/`l` regularly. Matching a
    /// slightly-wrong transcription of a real key is exactly what we want.
    private static let patterns: [Pattern] = [
        // AKIA…, ASIA… — the fixed prefix plus 16 makes this unambiguous.
        Pattern(.awsAccessKey, "\\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\\b"),

        // Vendor-prefixed tokens: OpenAI/Anthropic `sk-`, GitHub `ghp_` and
        // friends, Slack `xox…`, Google `AIza…`, Stripe `sk_live_…`.
        Pattern(.apiToken, "\\bsk-[A-Za-z0-9_-]{16,}"),
        Pattern(.apiToken, "\\bgh[pousr]_[A-Za-z0-9]{16,}"),
        Pattern(.apiToken, "\\bxox[baprs]-[A-Za-z0-9-]{10,}"),
        Pattern(.apiToken, "\\bAIza[0-9A-Za-z_-]{30,}"),
        Pattern(.apiToken, "\\b[sr]k_(?:live|test)_[0-9A-Za-z]{16,}"),
        Pattern(.apiToken, "\\bglpat-[A-Za-z0-9_-]{16,}"),
        Pattern(.apiToken, "\\bnpm_[A-Za-z0-9]{30,}"),

        // header.payload.signature — the `eyJ` opening is base64 `{"`.
        Pattern(.jsonWebToken, "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"),

        Pattern(.privateKey, "-{2,}\\s*BEGIN[A-Z ]*PRIVATE KEY\\s*-{2,}"),

        // `Authorization: Bearer …` — the word is what makes it certain.
        Pattern(.bearerToken, "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{16,}"),

        Pattern(.cardNumber, "\\b(?:\\d[ -]?){12,18}\\d\\b", validate: passesLuhn),

        Pattern(.iban, "\\b[A-Z]{2}\\d{2}[ ]?(?:[A-Z0-9]{4}[ ]?){2,7}[A-Z0-9]{1,4}\\b", validate: looksLikeIBAN),

        Pattern(.emailAddress, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"),

        // Session ids, hashes, raw keys with no vendor prefix. Low
        // confidence on purpose — plenty of innocent things are long hex.
        Pattern(.longHexString, "\\b[0-9a-fA-F]{32,}\\b"),
    ]

    // MARK: - Matching

    private static func matches(of pattern: Pattern, in line: RecognizedTextLine) -> [SensitiveMatch] {
        let text = line.text
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

        return pattern.expression.matches(in: text, range: fullRange).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let matched = String(text[range])
            if let validate = pattern.validate, !validate(matched) { return nil }

            return SensitiveMatch(
                kind: pattern.kind,
                rect: redactionRect(for: range, in: line),
                preview: masked(matched)
            )
        }
    }

    /// Where to paint, for a match at `range` of `line`.
    ///
    /// **The union of two estimates, on purpose.** Vision can box a
    /// substring directly, and measured against known text it is sometimes
    /// exact and sometimes covers most of the line instead (checked with a
    /// standalone probe, 2026-08-01: one of three fixtures was accurate, two
    /// started ~500 px early). Every observed error over-covered, but
    /// "observed" isn't "guaranteed", and a box that lands slightly short
    /// leaves the tail of a key readable — a silent leak, which is the one
    /// failure this feature exists to prevent.
    ///
    /// So the box painted is Vision's *unioned with* a proportional estimate
    /// from the character offsets, widened by a character either side. Both
    /// are approximations; the union is covered under either. The cost is
    /// occasionally blacking out a label next to the secret, which is
    /// exactly the direction to err in.
    private static func redactionRect(for range: Range<String.Index>, in line: RecognizedTextLine) -> CGRect {
        let text = line.text
        let characters = text.count
        guard characters > 0, line.frame.width > 0 else {
            return line.boundingBox(range) ?? line.frame
        }

        let characterWidth = line.frame.width / CGFloat(characters)
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let proportional = CGRect(
            x: line.frame.minX + CGFloat(start) * characterWidth - characterWidth,
            y: line.frame.minY,
            width: CGFloat(length) * characterWidth + characterWidth * 2,
            height: line.frame.height
        ).intersection(line.frame)

        guard let vision = line.boundingBox(range) else { return proportional }
        return vision.union(proportional)
    }

    /// Keeps the first four and last four characters, masking the middle —
    /// enough to tell two findings apart in a list, not enough to be a
    /// credential if this string is ever shown or copied.
    private static func masked(_ text: String) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 12 else {
            return String(repeating: "•", count: max(collapsed.count, 4))
        }
        return "\(collapsed.prefix(4))\(String(repeating: "•", count: 6))\(collapsed.suffix(4))"
    }

    // MARK: - Validators

    /// The check digit every real card number carries. Without it, any long
    /// run of digits — an order number, a timestamp, a phone number — would
    /// hold an upload.
    @Sendable
    private static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }

        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    /// IBANs are 15–34 characters and carry a mod-97 checksum. Checking it
    /// keeps this from firing on every "GB12 ABCD…"-shaped string, of which
    /// screenshots have plenty.
    @Sendable
    private static func looksLikeIBAN(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count) else { return false }

        // Move the first four characters to the end, then read letters as
        // numbers (A = 10) and take the whole thing mod 97 — it must be 1.
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let value: Int
            if character.isNumber, let digit = character.wholeNumberValue {
                value = digit
            } else if let letter = alphabetValue(character) {
                value = letter
            } else {
                return false
            }
            remainder = value < 10 ? (remainder * 10 + value) % 97 : (remainder * 100 + value) % 97
        }
        return remainder == 1
    }

    private static func alphabetValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (65...90).contains(ascii) else { return nil }
        return Int(ascii) - 55
    }
}
