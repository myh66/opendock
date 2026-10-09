import Foundation

enum NeteaseMusicLinkError: LocalizedError {
    case invalid, capacity, title
    var errorDescription: String? {
        switch self {
        case .invalid: return "请使用 https://music.163.com 的歌单、歌曲、专辑或艺人链接，包含一个有效的数字 id。"
        case .capacity: return "最多收藏 50 个入口，请先移除不再需要的链接。"
        case .title: return "请输入 1–120 字的入口名称。"
        }
    }
}

enum NeteaseMusicLinkKind: String, Codable, CaseIterable {
    case playlist, song, album, artist
    var title: String { switch self { case .playlist: return "歌单"; case .song: return "歌曲"; case .album: return "专辑"; case .artist: return "艺人" } }
    var symbol: String { switch self { case .playlist: return "music.note.list"; case .song: return "music.note"; case .album: return "opticaldisc"; case .artist: return "person.crop.circle" } }
}

/// Only public web routes are saved. Query/fragment variants resolve to one canonical bookmark.
struct NeteaseMusicPublicLink: Equatable {
    var kind: NeteaseMusicLinkKind
    var resourceID: String
    var url: URL {
        var components = URLComponents(); components.scheme = "https"; components.host = "music.163.com"; components.path = "/"
        components.fragment = "/\(kind.rawValue)?id=\(resourceID)"
        return components.url!
    }
    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "music.163.com", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { throw NeteaseMusicLinkError.invalid }
        let route: URLComponents
        if let fragment = parts.fragment {
            guard (parts.path.isEmpty || parts.path == "/"), parts.query == nil,
                  fragment.hasPrefix("/"), let parsed = URLComponents(string: fragment), parsed.fragment == nil else { throw NeteaseMusicLinkError.invalid }
            route = parsed
        } else { route = parts }
        let path = route.path
        guard path.utf8.count <= 32, path.first == "/", let kind = NeteaseMusicLinkKind(rawValue: String(path.dropFirst())),
              let items = route.queryItems, items.count == 1, items[0].name == "id", let id = items[0].value,
              (1...20).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }), id.contains(where: { $0 != "0" }) else { throw NeteaseMusicLinkError.invalid }
        self.kind = kind; self.resourceID = String(id.drop(while: { $0 == "0" }))
    }
}

struct NeteaseMusicBookmark: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var link: String
}

enum NeteaseMusicBookmarks {
    static let maximum = 50
    static let maximumBytes = 128 * 1024
    static func decode(_ value: String?) -> [NeteaseMusicBookmark] {
        guard let value, value.utf8.count <= maximumBytes, let data = value.data(using: .utf8),
              let entries = try? JSONDecoder().decode([NeteaseMusicBookmark].self, from: data) else { return [] }
        var ids = Set<UUID>(), links = Set<String>()
        return entries.prefix(maximum).compactMap { entry in
            guard let title = validTitle(entry.title), let link = try? NeteaseMusicPublicLink(entry.link),
                  ids.insert(entry.id).inserted, links.insert(link.url.absoluteString).inserted else { return nil }
            return NeteaseMusicBookmark(id: entry.id, title: title, link: link.url.absoluteString)
        }
    }
    static func adding(title: String, link input: String, to current: [NeteaseMusicBookmark]) throws -> [NeteaseMusicBookmark] {
        guard let title = validTitle(title) else { throw NeteaseMusicLinkError.title }
        let link = try NeteaseMusicPublicLink(input).url.absoluteString
        var entries = current
        if let index = entries.firstIndex(where: { $0.link == link }) { entries[index].title = title }
        else { guard entries.count < maximum else { throw NeteaseMusicLinkError.capacity }; entries.append(NeteaseMusicBookmark(title: title, link: link)) }
        return entries
    }
    static func encode(_ entries: [NeteaseMusicBookmark]) -> String? {
        guard entries.count <= maximum, let data = try? JSONEncoder().encode(entries), data.count <= maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func validTitle(_ input: String) -> String? {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(title.count), !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return title
    }
}

/// A future documented bridge can supply these capabilities without pretending launch links control playback.
struct NeteaseMusicCapabilities: Equatable {
    var supportsPublicLinks = true
    var supportsNowPlaying = false
    var supportsPlaybackControl = false
}
