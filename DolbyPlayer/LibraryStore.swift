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
    var fileExtension: String?   // 原始文件扩展名（小写，v4.1 新增：判断 MKV 不能只看片名，旧数据无此键为 nil）
}

/// 媒体库：增删、持久化（UserDefaults）、书签解析
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var progressMap: [UUID: Double] = [:]  // itemID -> 0...1 播放进度
    @Published private(set) var scanFolderName: String?

    private let key = "library.items.v1"
    private let folderBookmarkKey = "scan.folderBookmark.v1"
    private let folderNameKey = "scan.folderName.v1"
    private var accessingURL: URL?
    private var accessingSubtitleURL: URL?

    static let videoExtensions: Set<String> = ["mkv", "mp4", "mov", "m4v", "ts", "m2ts",
                                               "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"]

    init() {
        load()
        refreshProgress()
        scanFolderName = UserDefaults.standard.string(forKey: folderNameKey)
    }

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
        var item = MediaItem(name: url.deletingPathExtension().lastPathComponent,
                             bookmark: bookmark,
                             urlString: nil)
        item.fileExtension = url.pathExtension.lowercased()
        items.insert(item, at: 0)
        save()
    }

    func addURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty
            ? (url.host ?? trimmed)
            : url.deletingPathExtension().lastPathComponent
        var item = MediaItem(name: name, bookmark: nil, urlString: trimmed)
        item.fileExtension = url.pathExtension.lowercased()
        items.insert(item, at: 0)
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

    // MARK: - 扫描文件夹

    /// 设置扫描文件夹（保存书签，下次启动自动重扫）并立即扫描一遍
    @discardableResult
    func setScanFolder(url: URL) -> (added: Int, found: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [.minimalBookmark],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: folderBookmarkKey)
        }
        scanFolderName = url.lastPathComponent
        UserDefaults.standard.set(scanFolderName, forKey: folderNameKey)
        return scanFolderContents(url)
    }

    /// 重新扫描已保存的文件夹（App 启动时自动调用）；没设置过返回 nil
    @discardableResult
    func rescanSavedFolder() -> (added: Int, found: Int)? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        scanFolderName = url.lastPathComponent
        return scanFolderContents(url)
    }

    func clearScanFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
        scanFolderName = nil
    }

    /// 扫描 App 自身的 Documents 目录（通过「文件」App 拷进流光的视频会出现在这里）
    @discardableResult
    func scanOwnDocuments() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return scanFolderContents(docs).added
    }

    /// 递归扫描文件夹，把新视频加入媒体库（按片名＋扩展名去重，已在库的不重复添加）
    private func scanFolderContents(_ folder: URL) -> (added: Int, found: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return (0, 0) }
        var found = 0
        var newItems: [MediaItem] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.videoExtensions.contains(ext) else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found += 1
            let name = fileURL.deletingPathExtension().lastPathComponent
            let lower = name.lowercased()
            let exists = items.contains {
                $0.name.lowercased() == lower && ($0.fileExtension == nil || $0.fileExtension == ext)
            } || newItems.contains { $0.name.lowercased() == lower }
            if exists { continue }
            let bookmark = try? fileURL.bookmarkData(options: [.minimalBookmark],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
            var item = MediaItem(name: name, bookmark: bookmark, urlString: nil)
            item.fileExtension = ext
            newItems.append(item)
        }
        if !newItems.isEmpty {
            items.insert(contentsOf: newItems, at: 0)
            save()
        }
        return (newItems.count, found)
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
