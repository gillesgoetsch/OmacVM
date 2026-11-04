import Foundation
import OmacVMUpdate

/// What a new version brings, for the update banner and What's New: its
/// section of CHANGELOG.md, read from the downloaded app itself
/// (Contents/Resources/omacvm/CHANGELOG.md; the app's signature was checked
/// before, so nothing here comes from the network unchecked).
public struct WhatsNew: Equatable, Sendable {
    /// The section's opening line, if it has one ("Full screen including the notch, ...").
    public var intro: String?
    /// The bullets, as Markdown (bold, code, links), continuation lines joined.
    public var items: [String]

    public init(intro: String?, items: [String]) {
        self.intro = intro
        self.items = items
    }

    /// Items shown in all (one version, or all versions together).
    public static let maxItems = 30
    /// Versions shown; older ones are left to the release notes.
    public static let maxVersions = 5
    /// The most of a changelog that is read: What's New needs only its top,
    /// down to the running version's heading (see `head`), so a longer file
    /// still works.
    public static let maxBytes = 512 * 1024

    /// The "## VERSION" section of a changelog; nil when it has none.
    public static func parse(changelog: String, version: String) -> WhatsNew? {
        let isVersion = { (title: String) in title == version || title.hasPrefix(version + " ") }
        guard let s = sections(head(changelog, cut: Cut(low: nil, isStaged: isVersion))).first(where: { isVersion($0.title) }),
              !(s.news.intro == nil && s.news.items.isEmpty) else { return nil }
        return WhatsNew(intro: s.news.intro, items: Array(s.news.items.prefix(maxItems)))
    }

    /// Every version after `running` up to `staged`, newest first, each from
    /// its own "## VERSION ..." section (headings that are not a release
    /// version, such as "Unreleased" or "3.3.0-rc1", are skipped). nil when
    /// the staged version has no section. A running version that is not a
    /// release version ("?", a development build), or one at or above the
    /// staged one, gives the staged section alone. At most `maxVersions`
    /// versions and `maxItems` items in all, filled newest first; the rest
    /// is counted.
    public static func parse(changelog: String, running: String, staged: String) -> WhatsNewList? {
        guard let top = Version(staged) else {
            return parse(changelog: changelog, version: staged).map { WhatsNewList(staged: staged, sections: [.init(version: staged, news: $0)]) }
        }
        let low = Version(running).flatMap { $0 < top ? $0 : nil }
        var found: [(version: Version, news: WhatsNew)] = []
        for s in sections(head(changelog, running: running, staged: staged)) {
            guard let v = headingVersion(s.title),
                  v <= top, low.map({ $0 < v }) ?? (v == top),
                  !(s.news.intro == nil && s.news.items.isEmpty),
                  !found.contains(where: { $0.version == v }) else { continue }
            found.append((v, s.news))
        }
        found.sort { $1.version < $0.version }
        guard let first = found.first, first.version == top else { return nil }

        var list = WhatsNewList(staged: staged, sections: [])
        var room = maxItems
        for (i, f) in found.enumerated() {
            let fits = i == 0 || (i < maxVersions && room > 0)
            guard fits else {
                list.omittedVersions += 1
                continue
            }
            let take = min(room, f.news.items.count)
            list.sections.append(.init(version: f.version.description,
                                       news: WhatsNew(intro: f.news.intro, items: Array(f.news.items.prefix(take)))))
            list.omittedItems += f.news.items.count - take
            room -= take
        }
        return list
    }

    /// Reads a changelog file line by line in 64 KiB steps, only as far as
    /// `head` would keep (never more than `maxBytes`), then parses that part.
    /// nil: no file, a read error, a line in that part that is not UTF-8, or
    /// no section for the staged version.
    public static func read(_ url: URL, running: String, staged: String) -> WhatsNewList? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var stop = cut(running: running, staged: staged)
        var text = "", used = 0, rest = Data()
        reading: while true {
            let chunk: Data
            do { chunk = try h.read(upToCount: 64 * 1024) ?? Data() } catch { return nil }   // nil: the end of the file
            rest.append(chunk)
            while let nl = rest.firstIndex(of: 0x0A) {
                guard used + (nl - rest.startIndex) + 1 <= maxBytes else { break reading }
                guard let line = String(data: rest[rest.startIndex..<nl], encoding: .utf8) else { return nil }
                if stop.ends(at: line[...]) { break reading }
                text += line + "\n"
                used += line.utf8.count + 1
                rest = rest[(nl + 1)...]
            }
            if used + rest.count > maxBytes { break }
            if chunk.isEmpty {
                // The last line, without a line break.
                guard let line = String(data: rest, encoding: .utf8) else { return nil }
                if !stop.ends(at: line[...]) { text += line }
                break
            }
        }
        return parse(changelog: text, running: running, staged: staged)
    }

    /// Where reading a changelog can stop. With a running version below the
    /// staged one: after the staged version's heading, at the first "## "
    /// heading at or below the running version (the file is newest first;
    /// sections out of order above it are still read). Otherwise only the
    /// staged section is shown: at the first heading after the first staged
    /// section that has text.
    struct Cut {
        var low: Version?
        var isStaged: (String) -> Bool
        var seen = false, inStaged = false, stagedHasText = false

        mutating func ends(at line: Substring) -> Bool {
            guard line.hasPrefix("## ") else {
                if inStaged, line.range(of: #"^#+ "#, options: .regularExpression) == nil,
                   !line.trimmingCharacters(in: .whitespaces).isEmpty { stagedHasText = true }
                return false
            }
            let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if let low, seen { return headingVersion(title).map { $0 <= low } ?? false }
            if low == nil, inStaged, stagedHasText { return true }
            inStaged = isStaged(title)
            seen = seen || inStaged
            return false
        }
    }

    static func cut(running: String, staged: String) -> Cut {
        guard let top = Version(staged) else { return Cut(low: nil, isStaged: { $0 == staged || $0.hasPrefix(staged + " ") }) }
        return Cut(low: Version(running).flatMap { $0 < top ? $0 : nil }, isStaged: { headingVersion($0) == top })
    }

    /// The part of a changelog that What's New needs: from the top to where
    /// `Cut` stops, and at most `maxBytes`, ending at a whole line. The rest
    /// of the text is never looked at, so its size does not matter.
    public static func head(_ changelog: String, running: String, staged: String) -> Substring {
        head(changelog, cut: cut(running: running, staged: staged))
    }

    static func head(_ changelog: String, cut: Cut) -> Substring {
        var cut = cut
        let u = changelog.utf8
        var end = u.endIndex
        if let cap = u.index(u.startIndex, offsetBy: maxBytes, limitedBy: u.endIndex), cap < u.endIndex {
            end = u[..<cap].lastIndex(of: 0x0A) ?? u.startIndex
        }
        var start = u.startIndex
        while start < end {
            let nl = u[start..<end].firstIndex(of: 0x0A) ?? end
            if cut.ends(at: changelog[start..<nl]) { return changelog[..<start] }
            start = nl < end ? u.index(after: nl) : end
        }
        return changelog[..<end]
    }

    /// A heading's version: its first word ("3.2.4 (2026-01-02)" is 3.2.4); nil for "Unreleased".
    static func headingVersion(_ title: String) -> Version? {
        title.split(separator: " ").first.flatMap { Version(String($0)) }
    }

    /// The changelog's "## " sections in file order, with their intro and
    /// bullets. Other headings ("# Changelog", "### Fixed") are left out.
    static func sections<S: StringProtocol>(_ changelog: S) -> [(title: String, news: WhatsNew)] {
        var out: [(title: String, news: WhatsNew)] = []
        var title: String?, intro: [String] = [], items: [String] = []
        func close() {
            if let title { out.append((title, WhatsNew(intro: intro.isEmpty ? nil : intro.joined(separator: " "), items: items))) }
            intro = []
            items = []
        }
        for raw in changelog.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") {
                close()
                title = raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard title != nil else { continue }
            if raw.range(of: #"^#+ "#, options: .regularExpression) != nil {
                continue
            } else if raw.hasPrefix("- ") || raw.hasPrefix("* ") {
                items.append(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.isEmpty {
                continue
            } else if raw.hasPrefix(" "), !items.isEmpty {
                items[items.count - 1] += " " + line
            } else if items.isEmpty {
                intro.append(line)
            }
        }
        close()
        return out
    }

    /// One line for the banner: the intro, else the first item's first
    /// sentence, as plain text, cut at `limit` characters.
    public func summary(limit: Int = 110) -> String? {
        guard let text = intro ?? items.first.map(Self.firstSentence) else { return nil }
        let plain = Self.plain(text)
        guard plain.count > limit else { return plain }
        let cut = plain.prefix(limit - 1)
        let end = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return end.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    static func firstSentence(_ s: String) -> String {
        guard let r = s.range(of: #"\.\s"#, options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound]) + "."
    }

    /// Markdown's marks out: **bold**, `code`, [text](link).
    public static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "`", "__"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// What's New for an update past several versions: each version's section,
/// newest (the staged one) first, and how much did not fit.
public struct WhatsNewList: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var version: String
        public var news: WhatsNew

        public init(version: String, news: WhatsNew) {
            self.version = version
            self.news = news
        }
    }

    /// The update's version; its section is the banner's.
    public var staged: String
    public var sections: [Section]
    /// Versions in the range that are not shown (the version or item cap).
    public var omittedVersions = 0
    /// Items cut from versions that are shown.
    public var omittedItems = 0

    public init(staged: String, sections: [Section], omittedVersions: Int = 0, omittedItems: Int = 0) {
        self.staged = staged
        self.sections = sections
        self.omittedVersions = omittedVersions
        self.omittedItems = omittedItems
    }

    /// Where the left-out versions are: the whole changelog, not the staged
    /// version's release page (a fixed address, never from the feed).
    public static let changelogURL = URL(string: "https://github.com/gillesgoetsch/OmacVM/blob/main/CHANGELOG.md")!

    /// The staged version's section, found by its version (2.7 is 2.7.0).
    public var stagedNews: WhatsNew? {
        let v = Version(staged)
        return sections.first { s in v.map { Version(s.version) == $0 } ?? (s.version == staged) }?.news
    }

    /// The banner's line: the staged version's, as for a one-version update.
    public func summary(limit: Int = 110) -> String? { stagedNews?.summary(limit: limit) }

    /// "2 earlier versions and 5 more items are in the release notes."; nil when all is shown.
    public var omittedNote: String? {
        var parts: [String] = []
        if omittedVersions > 0 { parts.append("\(omittedVersions) earlier version" + (omittedVersions == 1 ? "" : "s")) }
        if omittedItems > 0 { parts.append("\(omittedItems) more item" + (omittedItems == 1 ? "" : "s")) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " and ") + (omittedVersions + omittedItems == 1 ? " is" : " are") + " in the changelog."
    }
}
