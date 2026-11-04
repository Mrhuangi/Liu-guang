import Foundation

/// 一条媒体记录：本地文件（安全作用域书签）或网络地址（二选一）
struct MediaItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bookmark: Data?      // 本地文件的 security-scoped bookmark
    var urlString: String?   // 网络直链
    var addedAt = Date()
    var subtitleBookmark: Data?  // 外挂字幕文件的 security-scoped bookmark（v3 新增，旧数据无此键也能解码）
    var subtitleName: String?    // 外挂字幕文件名
    var lastPlayedAt: Date?      // 最近播放时间（v4 新增，用于「继续观看」与排序）
}

/// 媒体库：增删、持久化（UserDefaults）、书签解析
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var progressMap: [UUID: Double] = [:]  // itemID -> 0...1 播放进度

    private let key = "library.items.v1"
    private var accessingURL: URL?
    private var accessingSubtitleURL: URL?

    init() { load(); refreshProgress() }

    // MARK: - 续播进度

    func refreshProgress() {
        var map: [UUID: Double] = [:]
        for item in items {
            if let p = ResumeStore.progress(forKey: item.id.uuidString) { map[item.id] = p }
        }
        progressMap = map
    }

    func touchPlayed(_ item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastPlayedAt = Date()
        save()
    }

    /// 有进度且没看完的条目，按最近播放排序（继续观看）
    var continueWatching: [MediaItem] {
        items.filter { item in
            guard let p = progressMap[item.id] else { return false }
            return p > 0.02 && p < 0.95
        }
        .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    // MARK: - 增删

    func addFile(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var bookmark: Data?
        bookmark = try? url.bookmarkData(options: [.minimalBookmark],
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        let item = MediaItem(name: url.deletingPathExtension().lastPathComponent,
                             bookmark: bookmark,
                             urlString: nil)
        items.insert(item, at: 0)
        save()
    }

    func addURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty
            ? (url.host ?? trimmed)
            : url.deletingPathExtension().lastPathComponent
        items.insert(MediaItem(name: name, bookmark: nil, urlString: trimmed), at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func remove(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - 解析可播放地址

    /// 返回可播放 URL；本地文件会开启安全作用域访问，调用方播完后应调用 stopAccessing()
    func resolveURL(for item: MediaItem) -> URL? {
        stopAccessing()
        if let s = item.urlString { return URL(string: s) }
        guard let data = item.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() {
            accessingURL = url
        }
        return url
    }

    func stopAccessing() {
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
        accessingSubtitleURL?.stopAccessingSecurityScopedResource()
        accessingSubtitleURL = nil
    }

    // MARK: - 外挂字幕

    func attachSubtitle(item: MediaItem, url: URL) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        items[index].subtitleBookmark = try? url.bookmarkData(
            options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        items[index].subtitleName = url.lastPathComponent
        save()
    }

    func detachSubtitle(item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].subtitleBookmark = nil
        items[index].subtitleName = nil
        save()
    }

    /// 解析外挂字幕文件为条目（SRT / ASS / SSA / VTT）；没有挂载或读失败返回 nil
    func loadExternalSubtitleCues(for item: MediaItem) -> [SubtitleCue]? {
        guard let data = item.subtitleBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() {
            accessingSubtitleURL = url
        }
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        let cues = SubtitleParser.parse(data: fileData, fileExtension: url.pathExtension)
        return cues.isEmpty ? nil : cues
    }

    // MARK: - 持久化

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = decoded
    }
}

// MARK: - 续播存储（按条目 ID 记录位置与总时长，供继续观看与自动续播）

enum ResumeStore {
    private static let key = "resume.store.v2"

    private static func all() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    static func save(key itemKey: String, seconds: Double, duration: Double) {
        guard seconds > 3, duration > 0, seconds.isFinite, duration.isFinite else { return }
        var dict = all()
        dict[itemKey] = [seconds, duration]
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func position(forKey itemKey: String) -> Double? {
        guard let pair = all()[itemKey], pair.count == 2 else { return nil }
        return pair[0]
    }

    static func progress(forKey itemKey: String) -> Double? {
        guard let pair = all()[itemKey], pair.count == 2, pair[1] > 0 else { return nil }
        return min(1, max(0, pair[0] / pair[1]))
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
