import Foundation

/// Genealogical date using ASTRONOMICAL year numbering (1 BC = 0, 44 BC = -43).
public struct GenDate: Codable, Hashable, Sendable {
    public enum Qualifier: String, Codable, Sendable {
        case exact, about, estimated, calculated, before, after, between, fromTo, phrase
    }

    public var qualifier: Qualifier
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var endYear: Int?
    public var original: String

    public init(qualifier: Qualifier = .exact, year: Int? = nil, month: Int? = nil, day: Int? = nil,
                endYear: Int? = nil, original: String = "") {
        self.qualifier = qualifier
        self.year = year
        self.month = month
        self.day = day
        self.endYear = endYear
        self.original = original
    }

    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let qualifiers: [String: Qualifier] = [
        "ABT": .about, "ABOUT": .about, "CIRCA": .about, "CA": .about, "C": .about,
        "EST": .estimated, "CAL": .calculated, "BEF": .before, "AFT": .after
    ]

    public static func toAstronomical(_ year: Int, bce: Bool) -> Int { bce ? 1 - year : year }

    public static func formatYear(_ year: Int) -> String {
        year <= 0 ? "\(1 - year) BCE" : "\(year)"
    }

    public var display: String {
        guard let year else { return original }
        if (qualifier == .between || qualifier == .fromTo), let endYear {
            return "\(GenDate.formatYear(year))–\(GenDate.formatYear(endYear))"
        }
        var parts: [String] = []
        if let day { parts.append(String(day)) }
        if let month, month >= 1, month <= 12 { parts.append(GenDate.months[month - 1].capitalized) }
        parts.append(GenDate.formatYear(year))
        let prefix: String
        switch qualifier {
        case .about: prefix = "c. "
        case .estimated: prefix = "est. "
        case .calculated: prefix = "calc. "
        case .before: prefix = "before "
        case .after: prefix = "after "
        default: prefix = ""
        }
        return prefix + parts.joined(separator: " ")
    }

    private static func isBCE(_ s: String) -> (Bool, String) {
        let patterns = ["B.C.E.", "BCE", "B.C.", "BC"]
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for p in patterns where trimmed.hasSuffix(p) {
            return (true, String(trimmed.dropLast(p.count)).trimmingCharacters(in: .whitespaces))
        }
        return (false, trimmed)
    }

    static func parseSimple(_ input: String) -> (Int?, Int?, Int?) {
        var text = input.uppercased()
        let (bce, rest) = isBCE(text)
        text = rest
        // Dual dating "1700/01" -> keep first year.
        if let slash = text.firstIndex(of: "/") {
            let before = text[..<slash]
            if let last = before.last, last.isNumber {
                text = String(before) + String(text[slash...].drop(while: { $0 == "/" || $0.isNumber }))
            }
        }
        if text.hasPrefix("-"), let n = Int(text) { return (n, nil, nil) }
        let tokens = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        let hasMonth = tokens.contains { months.contains(String($0.prefix(3))) && $0.allSatisfy(\.isLetter) }
        var day: Int?, month: Int?, year: Int?
        var seenMonth = false
        for tok in tokens {
            if tok.allSatisfy(\.isLetter), let idx = months.firstIndex(of: String(tok.prefix(3))) {
                month = idx + 1
                seenMonth = true
            } else if let n = Int(tok) {
                if hasMonth && !seenMonth && day == nil && year == nil && n <= 31 && tok.count <= 2 {
                    day = n
                } else {
                    year = n
                }
            }
        }
        if let y = year { year = y > 0 ? toAstronomical(y, bce: bce) : nil }
        return (year, month, day)
    }

    /// Parses GEDCOM 5.5.1 / 7 date values and common free text.
    public static func parse(_ raw: String?) -> GenDate? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var up = raw.uppercased()
            .replacingOccurrences(of: "@#DGREGORIAN@", with: "")
            .replacingOccurrences(of: "@#DJULIAN@", with: "")
            .trimmingCharacters(in: .whitespaces)
        for cal in ["GREGORIAN ", "JULIAN "] where up.hasPrefix(cal) { up = String(up.dropFirst(cal.count)) }
        let words = up.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if (first == "BET" || first == "FROM"), let sepIdx = words.firstIndex(where: { $0 == "AND" || $0 == "TO" }) {
            let a = words[1..<sepIdx].joined(separator: " ")
            let b = words[(sepIdx + 1)...].joined(separator: " ")
            return GenDate(qualifier: first == "BET" ? .between : .fromTo,
                           year: parseSimple(a).0, endYear: parseSimple(b).0, original: raw)
        }
        if first == "FROM" || first == "TO" {
            let (y, m, d) = parseSimple(words.dropFirst().joined(separator: " "))
            return GenDate(qualifier: first == "FROM" ? .after : .before, year: y, month: m, day: d, original: raw)
        }
        if first == "INT" || up.hasPrefix("(") {
            var inner = words.dropFirst(first == "INT" ? 1 : 0).joined(separator: " ")
            if let open = inner.firstIndex(of: "(") { inner = String(inner[..<open]) }
            let (y, m, d) = parseSimple(inner)
            return GenDate(qualifier: y == nil ? .phrase : .exact, year: y, month: m, day: d, original: raw)
        }
        let q = qualifiers[first.trimmingCharacters(in: CharacterSet(charactersIn: "."))]
        let body = q != nil ? words.dropFirst().joined(separator: " ") : up
        let (y, m, d) = parseSimple(body)
        return GenDate(qualifier: q ?? .exact, year: y, month: m, day: d, original: raw)
    }
}
