import Foundation

enum Mode: String, CaseIterable, Sendable {
    case polish, expand

    var title: String { self == .polish ? "Polishing" : "Expanding" }
    var promptURL: URL {
        Bundle.main.url(forResource: self == .polish ? "rewriter-prompt" : "expand-prompt", withExtension: "txt")!
    }
}

enum Verdict: Equatable {
    case replace(String)
    case preview(String, reason: String)
    case abort(String)
}

/// Builds the rewriter's input and decides whether its output is safe to paste without review.
enum Rewriter {
    static func userMessage(app: String, draft: String) -> String {
        "<app>\(app)</app>\n<draft>\n\(draft)\n</draft>"
    }

    // Same idea as spike/eval.py: code spans, URLs, file paths, @mentions, /commands and quotes must survive verbatim.
    private static let protectedPattern = try! NSRegularExpression(pattern:
        #"`[^`]+`|https?://\S+|[\w./-]+\.(?:py|ts|tsx|js|jsx|json|md|css|rs|go|swift|rb|java|kt|yml|yaml|toml|sh)\b|@[\w./-]+|(?<![\w/.])/[a-z][\w-]*|"[^"\n]+""#)

    static func protectedTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return protectedPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static let chatterPrefixes = ["sure", "here's", "here is", "certainly", "of course", "i can't", "i can’t",
                                          "i cannot", "i'm not going", "i won't", "i'm sorry", "sorry,"]

    static func check(draft: String, output raw: String, mode: Mode) -> Verdict {
        let output = clean(raw)
        guard !output.isEmpty else { return .abort("The model returned nothing, so your text was left alone.") }

        let lowerOut = output.lowercased(), lowerDraft = draft.lowercased()
        if let prefix = chatterPrefixes.first(where: { lowerOut.hasPrefix($0) }), !lowerDraft.hasPrefix(prefix) {
            return .preview(output, reason: "This looks like a reply, not a rewritten prompt.")
        }

        let missing = protectedTokens(in: draft).filter { !output.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        if !missing.isEmpty {
            return .preview(output, reason: "Changed or dropped: " + missing.prefix(3).joined(separator: ", "))
        }

        if mode == .polish {
            let d = wordCount(draft), o = wordCount(output)
            if o > max(4 * d, d + 30) { return .preview(output, reason: "Much longer than your draft.") }
        }
        return .replace(output)
    }

    /// Strips whitespace and a wrapper the model sometimes adds around the whole answer (quotes or a code fence).
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6 {
            s = String(s.dropFirst(3).dropLast(3))
            if let nl = s.firstIndex(of: "\n"), !s[..<nl].contains(" ") { s = String(s[s.index(after: nl)...]) } // drop ```text
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”")] where s.hasPrefix(open) && s.hasSuffix(close) && s.count > 1 {
            let inner = String(s.dropFirst().dropLast())
            if !inner.contains(open) { s = inner }
        }
        return s
    }

    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
}
