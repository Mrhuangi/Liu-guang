import AVFoundation
import Foundation
import UIKit

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

/// 错误日志：记录导入、扫描、播放各环节的成败，设置页可查看与复制（排查问题用）
enum AppLog {
    private static let key = "app.log.v1"
    private static let maxEntries = 300

    static func add(_ tag: String, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        var lines = all()
        lines.append("\(formatter.string(from: Date())) [\(tag)] \(message)")
        if lines.count > maxEntries { lines.removeFirst(lines.count - maxEntries) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
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
        var bookmark = try? url.bookmarkData(options: [.minimalBookmark],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        var finalURL = url
        if bookmark == nil {
            AppLog.add("导入", "\(url.lastPathComponent)：书签创建失败，尝试拷贝进 App 文档目录")
            if let copied = copyIntoDocuments(url) {
                finalURL = copied
                bookmark = try? copied.bookmarkData(options: [.minimalBookmark],
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
            }
        }
        var item = MediaItem(name: finalURL.deletingPathExtension().lastPathComponent,
                             bookmark: bookmark,
                             urlString: nil)
        item.fileExtension = finalURL.pathExtension.lowercased()
        items.insert(item, at: 0)
        save()
        AppLog.add("导入", "已加入媒体库：\(item.name)（书签\(bookmark == nil ? "无" : "有")）")
    }

    /// 书签建不起来时的兜底：把文件拷进 App 自己的 Documents 目录
    private func copyIntoDocuments(_ url: URL) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            AppLog.add("导入", "\(url.lastPathComponent)：已拷贝到 App 文档目录")
            return dest
        } catch {
            AppLog.add("导入", "\(url.lastPathComponent)：拷贝失败 \(error.localizedDescription)")
            return nil
        }
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
        let result = scanFolderContents(url)
        AppLog.add("扫描", "文件夹 \(url.lastPathComponent)：找到 \(result.found) 个视频，新加入 \(result.added) 个")
        return result
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
        let result = scanFolderContents(url)
        if result.added > 0 {
            AppLog.add("扫描", "自动重扫 \(url.lastPathComponent)：新加入 \(result.added) 个")
        }
        return result
    }

    func clearScanFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
        scanFolderName = nil
    }

    /// 扫描 App 自身的 Documents 目录（通过「文件」App 拷进 Lumen 的视频会出现在这里）
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

    /// 同一部剧的下一集（按文件名识别剧集；没有下一集返回 nil）
    func nextInSeries(after item: MediaItem) -> MediaItem? {
        guard let info = EpisodeParser.parse(item.name) else { return nil }
        let episodes = items
            .filter { EpisodeParser.parse($0.name)?.show == info.show }
            .sorted(by: EpisodeParser.episodeSort)
        guard let index = episodes.firstIndex(where: { $0.id == item.id }),
              index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    // MARK: - 解析可播放地址

    /// 返回可播放 URL；本地文件会开启安全作用域访问，调用方播完后应调用 stopAccessing()
    func resolveURL(for item: MediaItem) -> URL? {
        stopAccessing()
        if let s = item.urlString { return URL(string: s) }
        guard let data = item.bookmark else {
            AppLog.add("播放", "\(item.name)：条目没有书签，无法解析文件")
            return nil
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            AppLog.add("播放", "\(item.name)：书签解析失败")
            return nil
        }
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

// MARK: - 缩略图（真实视频帧；MKV 用重封装后的缓存 MP4 生成）

enum ThumbnailStore {
    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cached(for item: MediaItem) -> UIImage? {
        let url = directory.appendingPathComponent(item.id.uuidString + ".jpg")
        return UIImage(contentsOfFile: url.path)
    }

    /// 生成缩略图并落盘缓存；只处理本地文件（直链跳过）
    @MainActor
    static func generate(for item: MediaItem, store: LibraryStore) async -> UIImage? {
        if let image = cached(for: item) { return image }
        guard item.urlString == nil else { return nil }

        var source: URL?
        var needsScopeStop = false
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let remuxed = caches.appendingPathComponent(item.name + ".mp4")
        if FileManager.default.fileExists(atPath: remuxed.path) {
            source = remuxed // MKV 已重封装过：用缓存 MP4 抽帧（在 App 沙盒里，无需书签）
        } else if let ext = item.fileExtension, ["mp4", "mov", "m4v"].contains(ext) {
            source = store.resolveURL(for: item)
            needsScopeStop = source != nil
        }
        guard let src = source else { return nil }

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: src)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 600)
            let time = CMTime(seconds: 30, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }.value

        if needsScopeStop { store.stopAccessing() }
        if let image, let data = image.jpegData(compressionQuality: 0.75) {
            try? data.write(to: directory.appendingPathComponent(item.id.uuidString + ".jpg"))
        }
        return image
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
