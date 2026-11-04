import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 根视图：媒体库 + 搜索（iOS 26 Liquid Glass 基线）

struct ContentView: View {
    @StateObject private var store = LibraryStore()

    var body: some View {
        TabView {
            Tab("媒体库", systemImage: "film.stack") {
                LibraryView()
            }
            Tab("搜索", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environmentObject(store)
        .preferredColorScheme(.dark)
    }
}

// MARK: - 排序 / 显示偏好

enum LibrarySort: String, CaseIterable {
    case recentPlayed, recentAdded, name
    var label: String {
        switch self {
        case .recentPlayed: return "最近播放"
        case .recentAdded: return "最近添加"
        case .name: return "片名"
        }
    }
}

enum LibraryDisplay: String, CaseIterable {
    case grid, list
    var label: String { self == .grid ? "网格" : "列表" }
}

// MARK: - 媒体库

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("library.sort") private var sortRaw = LibrarySort.recentPlayed.rawValue
    @AppStorage("library.display") private var displayRaw = LibraryDisplay.grid.rawValue

    @State private var activeItem: MediaItem?
    @State private var showImporter = false
    @State private var showURLAlert = false
    @State private var urlText = ""
    @State private var showSettings = false
    @State private var subtitleTarget: MediaItem?

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recentPlayed }
    private var display: LibraryDisplay { LibraryDisplay(rawValue: displayRaw) ?? .grid }

    private var sortedItems: [MediaItem] {
        switch sort {
        case .recentPlayed:
            return store.items.sorted { ($0.lastPlayedAt ?? $0.addedAt) > ($1.lastPlayedAt ?? $1.addedAt) }
        case .recentAdded:
            return store.items.sorted { $0.addedAt > $1.addedAt }
        case .name:
            return store.items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// 大字体（无障碍字号）时网格自动降为列表，避免小屏崩版
    private var effectiveDisplay: LibraryDisplay {
        typeSize.isAccessibilitySize ? .list : display
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("暂无影片", systemImage: "film.stack")
                    } description: {
                        Text("导入本地 MKV / MP4 文件，或添加网络直链。MKV 会无损重封装为 MP4 后原生播放杜比视界。")
                    } actions: {
                        Button("导入文件") { showImporter = true }
                        Button("添加网址") { showURLAlert = true }
                    }
                } else if effectiveDisplay == .grid {
                    gridBody
                } else {
                    listBody
                }
            }
            .navigationTitle("流光")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showImporter = true } label: { Label("导入文件", systemImage: "doc.badge.plus") }
                        Button { showURLAlert = true } label: { Label("添加网址", systemImage: "link.badge.plus") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Picker("显示", selection: $displayRaw) {
                            ForEach(LibraryDisplay.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Divider()
                        Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(store.addFile) }
        }
        .alert("添加网络直链", isPresented: $showURLAlert) {
            TextField("https://…/movie.mkv", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") { store.addURL(urlText); urlText = "" }
            Button("取消", role: .cancel) { urlText = "" }
        } message: {
            Text("支持 http/https 的 MKV、MP4 直链。")
        }
        .fileImporter(isPresented: Binding(
            get: { subtitleTarget != nil },
            set: { if !$0 { subtitleTarget = nil } }
        ), allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let target = subtitleTarget {
                store.attachSubtitle(item: target, url: url)
            }
            subtitleTarget = nil
        }
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store)
        }
    }

    private var gridBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !store.continueWatching.isEmpty {
                    continueSection
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 18) {
                    ForEach(sortedItems) { item in
                        MediaCell(item: item) { activeItem = item }
                            .contextMenu { mediaMenu(item) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续观看")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.continueWatching) { item in
                        ContinueCard(item: item) { activeItem = item }
                            .contextMenu { mediaMenu(item) }
                    }
                }
            }
        }
    }

    private var listBody: some View {
        List {
            if !store.continueWatching.isEmpty {
                Section("继续观看") {
                    ForEach(store.continueWatching) { item in
                        MediaRow(item: item) { activeItem = item }
                            .contextMenu { mediaMenu(item) }
                    }
                }
            }
            Section("全部影片") {
                ForEach(sortedItems) { item in
                    MediaRow(item: item) { activeItem = item }
                        .contextMenu { mediaMenu(item) }
                }
                .onDelete { offsets in
                    offsets.map { sortedItems[$0] }.forEach(store.remove)
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func mediaMenu(_ item: MediaItem) -> some View {
        Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
        if item.subtitleName == nil {
            Button { subtitleTarget = item } label: { Label("添加外挂字幕", systemImage: "captions.bubble") }
        } else {
            Button { subtitleTarget = item } label: { Label("更换外挂字幕", systemImage: "captions.bubble") }
            Button(role: .destructive) { store.detachSubtitle(item: item) } label: {
                Label("移除外挂字幕", systemImage: "captions.bubble.slash")
            }
        }
        Divider()
        Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - 海报占位图（无海报时按片名生成的标题图，2:3）

struct PosterArt: View {
    let item: MediaItem
    var wide = false

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.16, green: 0.19, blue: 0.30), Color(red: 0.03, green: 0.03, blue: 0.07)),
        (Color(red: 0.26, green: 0.14, blue: 0.27), Color(red: 0.07, green: 0.03, blue: 0.09)),
        (Color(red: 0.10, green: 0.24, blue: 0.19), Color(red: 0.02, green: 0.07, blue: 0.05)),
        (Color(red: 0.30, green: 0.21, blue: 0.11), Color(red: 0.08, green: 0.05, blue: 0.02)),
        (Color(red: 0.09, green: 0.23, blue: 0.27), Color(red: 0.02, green: 0.07, blue: 0.08)),
        (Color(red: 0.30, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.03, blue: 0.04)),
    ]

    private var palette: (Color, Color) {
        let seed = item.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.palettes[abs(seed) % Self.palettes.count]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack {
                HStack {
                    LiuGuangGlyph()
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
            Text(item.name)
                .font(wide ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(10)
        }
        .aspectRatio(wide ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// 流光三线（与 App 图标 A 款一致的符号）
struct LiuGuangGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            bar(width: 30)
            bar(width: 21)
            bar(width: 26)
        }
    }
    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(.white.opacity(0.92))
            .frame(width: width, height: 5)
    }
}

// MARK: - 网格单元 / 列表行 / 继续观看卡

extension MediaItem {
    var isRemote: Bool { urlString != nil }
    var formatText: String {
        let ext = ((urlString ?? name) as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "视频" : ext
    }
    var captionText: String {
        var parts = [isRemote ? "直链" : "本地", formatText]
        if subtitleName != nil { parts.append("外挂字幕") }
        return parts.joined(separator: " · ")
    }
}

struct MediaCell: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                PosterArt(item: item)
                if let p = store.progressMap[item.id] {
                    ProgressBar(value: p)
                }
                Text(item.captionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放 \(item.name)")
    }
}

struct MediaRow: View {
    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                PosterArt(item: item)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.captionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MediaProgress(item: item)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 行内进度（独立小组件以便读取环境中的 store）
struct MediaProgress: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    var body: some View {
        if let p = store.progressMap[item.id] {
            ProgressBar(value: p).frame(maxWidth: 160)
        }
    }
}

struct ContinueCard: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    PosterArt(item: item, wide: true)
                    if let p = store.progressMap[item.id] {
                        ProgressBar(value: p, height: 4)
                    }
                }
                if let p = store.progressMap[item.id] {
                    Text("已看 \(Int(p * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 232)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("继续播放 \(item.name)")
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 搜索

struct SearchView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var activeItem: MediaItem?

    private var results: [MediaItem] {
        query.isEmpty ? store.items : store.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { item in
                        MediaRow(item: item) { activeItem = item }
                            .contextMenu {
                                Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
                                Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("搜索")
        }
        .searchable(text: $query, prompt: "搜索片名")
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store)
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.autoResume") private var autoResume = true
    @AppStorage("settings.subFontSize") private var subFontSize: Double = 17
    @State private var cacheNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("自动续播", isOn: $autoResume)
                    Stepper(value: $subFontSize, in: 13...26, step: 1) {
                        LabeledContent("外挂字幕字号", value: "\(Int(subFontSize))")
                    }
                }
                Section("数据") {
                    Button("清除续播记录", role: .destructive) {
                        ResumeStore.clearAll()
                        store.refreshProgress()
                    }
                    Button("清除重封装缓存") { clearRemuxCache() }
                    if let cacheNote {
                        Text(cacheNote).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("关于") {
                    LabeledContent("版本", value: "4.0")
                    Text("本地重封装引擎：MKV 无损转 MP4（dvh1），杜比视界单层原生输出；文本字幕转内嵌字幕轨，图形字幕（PGS/VobSub）暂跳过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func clearRemuxCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var removed = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "mp4" {
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        cacheNote = removed > 0 ? "已清除 \(removed) 个重封装缓存文件。" : "没有可清除的缓存。"
    }
}

// MARK: - 播放流程：MKV 先重封装，再进系统播放器

struct PlaybackFlow: View {
    let item: MediaItem
    @ObservedObject var store: LibraryStore
    @StateObject private var model = PlayerModel()
    @Environment(\.dismiss) private var dismiss

    @State private var playURL: URL?
    @State private var remuxProgress: Double?
    @State private var failure: String?
    @State private var warnings: [String] = []
    @State private var showWarnings = false

    private var isMKV: Bool {
        let source = item.urlString ?? item.name
        return (source as NSString).pathExtension.lowercased() == "mkv"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let playURL {
                PlayerScreen(url: playURL, title: item.name,
                             subtitleCues: store.loadExternalSubtitleCues(for: item),
                             resumeKey: item.id.uuidString,
                             model: model) { dismiss() }
            } else if let failure {
                ContentUnavailableView {
                    Label("无法播放", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("关闭") { dismiss() }
                }
                .foregroundStyle(.white)
            } else {
                remuxCard
            }
        }
        .task { await prepare() }
        .onAppear { store.touchPlayed(item) }
        .onDisappear {
            model.stop()
            store.stopAccessing()
            store.refreshProgress()
        }
        .alert("重封装提示", isPresented: $showWarnings) {
            Button("继续播放") { }
        } message: {
            Text(warnings.joined(separator: "\n"))
        }
    }

    private var remuxCard: some View {
        VStack(spacing: 14) {
            LiuGuangGlyph()
            Text(item.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let progress = remuxProgress {
                Text("正在重封装 \(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 200)
                Text("无损转换，不重新编码，速度取决于文件大小")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView().tint(.white)
                Text("正在准备…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 32)
    }

    private func prepare() async {
        guard let url = store.resolveURL(for: item) else {
            failure = "无法读取这个文件（书签失效或链接不可用），请删除后重新导入。"
            return
        }
        if !isMKV {
            playURL = url
            return
        }
        remuxProgress = 0
        let runner = RemuxRunner()
        do {
            let result = try await runner.run(input: url) { value in
                Task { @MainActor in remuxProgress = value }
            }
            remuxProgress = nil
            warnings = result.warnings
            playURL = result.url
            if !warnings.isEmpty { showWarnings = true }
        } catch let error as RemuxError {
            failure = error.errorDescription ?? "重封装失败。"
        } catch {
            failure = "重封装失败：\(error.localizedDescription)"
        }
    }
}

/// 把回调式 MP4Remuxer 包成 async
final class RemuxRunner {
    func run(input: URL, progress: @escaping (Double) -> Void) async throws -> RemuxResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try MP4Remuxer().remux(input: input, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - 播放器界面（系统播放器 + 标题/关闭 + 外挂字幕层）

struct PlayerScreen: View {
    let url: URL
    let title: String
    var subtitleCues: [SubtitleCue]? = nil
    var resumeKey: String = ""
    @ObservedObject var model: PlayerModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerView(player: model.player, subtitleText: model.currentSubtitleText)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                        if !model.formatBadge.isEmpty {
                            Text(model.formatBadge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
            }
            .padding()
        }
        .task {
            model.load(url: url, title: title, resumeKey: resumeKey)
            if let subtitleCues { model.setExternalSubtitles(subtitleCues) }
            model.player.play()
        }
    }
}

