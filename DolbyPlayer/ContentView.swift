import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 根视图：媒体库 + 搜索（iOS 26 Liquid Glass 基线）

struct ContentView: View {
    @StateObject private var store = LibraryStore()
    @StateObject private var scrape = ScrapeStore()
    @AppStorage("appearance.mode") private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        TabView {
            Tab("媒体库", systemImage: "film.stack") {
                LibraryView()
            }
            Tab("文件源", systemImage: "folder") {
                SourcesView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
            Tab("搜索", systemImage: "magnifyingglass") {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environmentObject(store)
        .environmentObject(scrape)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.scheme ?? nil)
    }
}

// MARK: - 外观（跟随系统 / 浅色 / 深色）

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
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

// MARK: - 剧集识别（按文件名自动收纳：S01E02 / 第X集）

enum EpisodeParser {
    struct Info {
        let show: String
        let season: Int
        let episode: Int
    }

    static func parse(_ name: String) -> Info? {
        if let m = match(#"[Ss](\d{1,2})[Ee](\d{1,3})"#, in: name),
           let season = Int(m.1), let episode = Int(m.2) {
            let show = cleanShow(String(name[..<m.range.lowerBound]))
            return Info(show: show.isEmpty ? name : show, season: season, episode: episode)
        }
        if let m = match(#"第\s*(\d{1,3})\s*集"#, in: name),
           let episode = Int(m.1) {
            let show = cleanShow(String(name[..<m.range.lowerBound]))
            return Info(show: show.isEmpty ? name : show, season: 1, episode: episode)
        }
        return nil
    }

    static func episodeSort(_ a: MediaItem, _ b: MediaItem) -> Bool {
        let ia = parse(a.name)
        let ib = parse(b.name)
        if let ia, let ib {
            if ia.season != ib.season { return ia.season < ib.season }
            if ia.episode != ib.episode { return ia.episode < ib.episode }
        }
        return a.name.localizedCompare(b.name) == .orderedAscending
    }

    private static func match(_ pattern: String, in text: String)
        -> (range: Range<String.Index>, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: full),
              let r = Range(m.range, in: text) else { return nil }
        func group(_ index: Int) -> String {
            guard m.numberOfRanges > index, let gr = Range(m.range(at: index), in: text) else { return "" }
            return String(text[gr])
        }
        return (r, group(1), group(2))
    }

    private static func cleanShow(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-·"))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 媒体库

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("library.sort") private var sortRaw = LibrarySort.recentPlayed.rawValue
    @AppStorage("library.display") private var displayRaw = LibraryDisplay.grid.rawValue

    @State private var activeItem: MediaItem?
    @State private var showImporter = false
    @State private var showFolderImporter = false
    @State private var scanSummary: String?
    @State private var importError: String?
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
                    EmptyLibraryView(
                        onImport: { showImporter = true },
                        onScan: { showFolderImporter = true }
                    )
                } else if effectiveDisplay == .grid {
                    homeBody
                } else {
                    listBody
                }
            }
            .navigationTitle("Lumen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showFolderImporter = true } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }
                        Button { showImporter = true } label: { Label("导入文件", systemImage: "doc.badge.plus") }
                        if !store.sources.isEmpty {
                            Button { rescan() } label: { Label("重新扫描", systemImage: "arrow.triangle.2.circlepath") }
                        }
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                AppLog.add("导入", "文件选择器返回 \(urls.count) 个文件")
                urls.forEach(store.addFile)
            case .failure(let error):
                AppLog.add("导入", "文件选择器失败：\(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    let r = store.addSource(url: folder)
                    scanSummary = "已添加文件源「\(folder.lastPathComponent)」：共找到 \(r.found) 个视频，新加入媒体库 \(r.added) 个。之后每次打开 App 都会自动扫描。"
                }
            case .failure(let error):
                AppLog.add("扫描", "文件夹选择器失败：\(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("扫描完成", isPresented: Binding(
            get: { scanSummary != nil },
            set: { if !$0 { scanSummary = nil } }
        )) {
            Button("好") { scanSummary = nil }
        } message: {
            Text(scanSummary ?? "")
        }
        .task {
            // 启动自动扫描：App 自身文档目录 + 全部文件源；剧集自动刮削元数据
            store.scanOwnDocuments()
            store.rescanSavedFolder()
            scrape.ensureAll(items: store.items)
        }
        .onChange(of: store.items.count) { _, _ in
            scrape.ensureAll(items: store.items)
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

    // MARK: 首页分区（继续观看 / 最近添加 / 剧集 / 其他）

    private var seriesGroups: [(show: String, episodes: [MediaItem])] {
        var dict: [String: [MediaItem]] = [:]
        for item in store.items {
            if let info = EpisodeParser.parse(item.name) {
                dict[info.show, default: []].append(item)
            }
        }
        return dict.filter { $0.value.count >= 2 }
            .map { (show: $0.key, episodes: $0.value.sorted(by: EpisodeParser.episodeSort)) }
            .sorted { $0.show.localizedCompare($1.show) == .orderedAscending }
    }

    private var groupedIDs: Set<UUID> {
        Set(seriesGroups.flatMap { $0.episodes.map(\.id) })
    }

    private var standaloneItems: [MediaItem] {
        sortedItems.filter { !groupedIDs.contains($0.id) }
    }

    private var recentItems: [MediaItem] {
        Array(store.items.sorted { $0.addedAt > $1.addedAt }.prefix(10))
    }

    private var homeBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !store.continueWatching.isEmpty {
                    continueSection
                }
                recentSection
                if !seriesGroups.isEmpty {
                    seriesSection
                }
                standaloneSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("继续观看")
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近添加")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recentItems) { item in
                        MediaCell(item: item, showName: true) { activeItem = item }
                            .frame(width: 110)
                            .contextMenu { mediaMenu(item) }
                    }
                }
            }
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("剧集")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(seriesGroups, id: \.show) { group in
                        NavigationLink {
                            SeriesView(show: group.show)
                        } label: {
                            SeriesCard(show: group.show,
                                       representative: group.episodes[0],
                                       count: group.episodes.count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var standaloneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(seriesGroups.isEmpty ? "全部影片" : "电影与其他",
                         count: standaloneItems.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 18) {
                ForEach(standaloneItems) { item in
                    MediaCell(item: item, showName: true) { activeItem = item }
                        .contextMenu { mediaMenu(item) }
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

    private func rescan() {
        if let r = store.rescanSavedFolder() {
            scanSummary = "重新扫描完成：共 \(r.found) 个视频，新加入 \(r.added) 个。"
        }
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

// MARK: - 空库引导（自绘以保证对比度与按钮层级，深浅色都清晰）

struct EmptyLibraryView: View {
    let onImport: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂无影片")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("添加一个文件夹作为文件源，视频会自动入库。\nMKV 会无损重封装为 MP4 后原生播放杜比视界。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button(action: onScan) {
                    Text("添加文件夹").frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: onImport) {
                    Text("导入单个文件").frame(maxWidth: 220)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        if let e = fileExtension, !e.isEmpty { return e.uppercased() }
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
    var showName = false
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                PosterView(item: item)
                if let p = store.progressMap[item.id] {
                    ProgressBar(value: p)
                }
                if showName {
                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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

/// 海报：有真实视频帧缩略图时显示缩略图，否则用标题占位图
struct PosterView: View {
    @EnvironmentObject private var store: LibraryStore
    let item: MediaItem
    var wide = false
    @State private var thumb: UIImage?

    var body: some View {
        ZStack {
            PosterArt(item: item, wide: wide)
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(wide ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: item.id) {
            if let cached = ThumbnailStore.cached(for: item) {
                thumb = cached
            } else {
                thumb = await ThumbnailStore.generate(for: item, store: store)
            }
        }
    }
}

/// 剧集卡（首页「剧集」分区）：优先用刮削到的官方海报
struct SeriesCard: View {
    @EnvironmentObject private var scrape: ScrapeStore
    let show: String
    let representative: MediaItem
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = scrape.posterImage(for: show) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                PosterView(item: representative)
            }
            Text(show)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("共 \(count) 集")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 110)
    }
}

/// 剧集详情页：海报头图 + 简介 + 演职人员 + 带剧照的分集列表（刮削数据来自 TVmaze）
struct SeriesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scrape: ScrapeStore
    let show: String
    @State private var activeItem: MediaItem?

    private var episodes: [MediaItem] {
        store.items
            .filter { EpisodeParser.parse($0.name)?.show == show }
            .sorted(by: EpisodeParser.episodeSort)
    }

    private var meta: ShowMeta? { scrape.meta(for: show) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let meta, !meta.cast.isEmpty {
                    castSection(meta)
                }
                episodesSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .navigationTitle(show)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeItem) { item in
            PlaybackFlow(item: item, store: store)
        }
        .task { scrape.ensureAll(items: store.items) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let img = scrape.posterImage(for: show) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else if let first = episodes.first {
                    PosterView(item: first)
                }
            }
            .frame(width: 104, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(meta?.title ?? show)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let meta {
                    HStack(spacing: 6) {
                        if let year = meta.year { Text(year) }
                        if let rating = meta.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                        if !meta.genres.isEmpty {
                            Text(meta.genres.prefix(3).joined(separator: " · "))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let summary = meta.summary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("正在匹配剧集信息…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("共 \(episodes.count) 集")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func castSection(_ meta: ShowMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演职人员")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(meta.cast.indices, id: \.self) { index in
                        let member = meta.cast[index]
                        VStack(spacing: 5) {
                            castAvatar(member)
                            Text(member.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let character = member.character {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 64)
                    }
                }
            }
        }
    }

    private func castAvatar(_ member: CastMember) -> some View {
        Group {
            if let img = ScrapeStore.image(named: member.imageFile) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.25))
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("分集")
                .font(.headline)
                .padding(.bottom, 4)
            ForEach(episodes) { item in
                episodeRow(item)
                Divider()
            }
        }
    }

    private func episodeRow(_ item: MediaItem) -> some View {
        let info = EpisodeParser.parse(item.name)
        let em = info.flatMap { meta?.episodes[ScrapeStore.episodeKey(season: $0.season, episode: $0.episode)] }
        return Button {
            activeItem = item
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let info, let img = scrape.stillImage(for: show, season: info.season, episode: info.episode) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        PosterView(item: item, wide: true)
                    }
                }
                .frame(width: 118, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    if let info {
                        Text("第 \(info.episode) 集 · \(ScrapeStore.episodeKey(season: info.season, episode: info.episode))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(em?.title ?? item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let runtime = em?.runtime {
                        Text("\(runtime) 分钟")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let p = store.progressMap[item.id] {
                        ProgressBar(value: p)
                            .frame(maxWidth: 140)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { activeItem = item } label: { Label("播放", systemImage: "play.fill") }
            Button(role: .destructive) { store.remove(item) } label: { Label("删除", systemImage: "trash") }
        }
    }
}

struct MediaRow: View {
    let item: MediaItem
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                PosterView(item: item)
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
                    PosterView(item: item, wide: true)
                    if let p = store.progressMap[item.id] {
                        ProgressBar(value: p, height: 4, onDarkBackground: true)
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
    var onDarkBackground = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(onDarkBackground ? .white.opacity(0.25) : Color.primary.opacity(0.15))
                Capsule().fill(onDarkBackground ? .white : Color.accentColor)
                    .frame(width: geo.size.width * min(1, max(0, value)))
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

// MARK: - 文件源（本地来源管理：扫描文件夹 / 导入）

struct SourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showImporter = false
    @State private var showFolderImporter = false
    @State private var summary: String?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("文件源（文件夹）") {
                    if store.sources.isEmpty {
                        Text("还没有添加文件夹。添加后，文件夹里的视频会原地读取、自动入库，不拷贝文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { source in
                        Label(source.name, systemImage: "folder.fill")
                    }
                    .onDelete { offsets in
                        offsets.map { store.sources[$0] }.forEach(store.removeSource)
                    }
                    Button {
                        showFolderImporter = true
                    } label: {
                        Label("添加文件夹", systemImage: "folder.badge.plus")
                    }
                    if !store.sources.isEmpty {
                        Button {
                            rescan()
                        } label: {
                            Label("重新扫描全部", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    Text("每次打开 App 都会自动扫描文件源里的新视频。左滑可移除文件源（已入库的条目不受影响）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("导入单个文件") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("从「文件」导入", systemImage: "doc.badge.plus")
                    }
                    Text("单个大文件（几个 GB）经系统选择器导出会很慢，建议用上面的「添加文件夹」加入它所在的文件夹。也可以把视频拷进「文件」App 里 Lumen 的文件夹，下次打开 App 时会自动入库。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("媒体库") {
                    LabeledContent("视频总数", value: "\(store.items.count)")
                }
            }
            .navigationTitle("文件源")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                AppLog.add("导入", "文件选择器返回 \(urls.count) 个文件")
                urls.forEach(store.addFile)
            case .failure(let error):
                AppLog.add("导入", "文件选择器失败：\(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    let r = store.addSource(url: folder)
                    summary = "已添加文件源「\(folder.lastPathComponent)」：共找到 \(r.found) 个视频，新加入媒体库 \(r.added) 个。"
                }
            case .failure(let error):
                AppLog.add("扫描", "文件夹选择器失败：\(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
        .alert("扫描完成", isPresented: Binding(
            get: { summary != nil },
            set: { if !$0 { summary = nil } }
        )) {
            Button("好") { summary = nil }
        } message: {
            Text(summary ?? "")
        }
        .alert("操作失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func rescan() {
        let r = store.rescanAllSources()
        summary = "重新扫描完成：共 \(r.found) 个视频，新加入 \(r.added) 个。"
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance.mode") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("settings.autoResume") private var autoResume = true
    @AppStorage("settings.autoNext") private var autoNext = true
    @AppStorage("settings.autoPiP") private var autoPiP = true
    @AppStorage("settings.rememberRate") private var rememberRate = true
    @AppStorage("settings.subFontSize") private var subFontSize: Double = 17
    @State private var cacheNote: String?
    @State private var scanNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("外观", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("播放器界面始终为深色，不受此设置影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("播放") {
                    Toggle("自动续播", isOn: $autoResume)
                    Toggle("自动连播下一集", isOn: $autoNext)
                    Toggle("退出时自动画中画", isOn: $autoPiP)
                    Toggle("记住播放速度", isOn: $rememberRate)
                    Stepper(value: $subFontSize, in: 13...26, step: 1) {
                        LabeledContent("外挂字幕字号", value: "\(Int(subFontSize))")
                    }
                }
                Section("扫描") {
                    LabeledContent("文件源数量", value: "\(store.sources.count)")
                    if !store.sources.isEmpty {
                        Button("重新扫描全部") {
                            let r = store.rescanAllSources()
                            scanNote = "共 \(r.found) 个视频，新加入 \(r.added) 个。"
                        }
                        Button("清除全部文件源", role: .destructive) {
                            store.clearScanFolder()
                            scanNote = nil
                        }
                    } else {
                        Text("在「文件源」页点「添加文件夹」，选一次文件夹，之后每次打开 App 都会自动把里面的新视频加入媒体库。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let scanNote {
                        Text(scanNote).font(.footnote).foregroundStyle(.secondary)
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
                Section("日志") {
                    NavigationLink("错误日志") { LogView() }
                    Text("导入、扫描、播放失败都会记在这里。遇到问题把日志复制发给我，就能定位在哪一步断的。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "5.0")
                    Text("本地重封装引擎：MKV 无损转 MP4（dvh1），杜比视界单层原生输出；文本字幕转内嵌字幕轨，图形字幕（PGS/VobSub）暂跳过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
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

// MARK: - 错误日志页

struct LogView: View {
    @State private var lines: [String] = []

    var body: some View {
        List {
            if lines.isEmpty {
                Text("暂无日志")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("错误日志")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: { Label("复制全部", systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        AppLog.clear()
                        lines = []
                    } label: { Label("清空日志", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { lines = AppLog.all() }
    }
}

// MARK: - 播放流程：MKV 先重封装，再进系统播放器

struct PlaybackFlow: View {
    let item: MediaItem
    @ObservedObject var store: LibraryStore
    @StateObject private var model = PlayerModel()
    @Environment(\.dismiss) private var dismiss

    @State private var currentItem: MediaItem
    @State private var playURL: URL?
    @State private var remuxProgress: Double?
    @State private var failure: String?
    @State private var warnings: [String] = []
    @State private var showWarnings = false

    init(item: MediaItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _currentItem = State(initialValue: item)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let playURL {
                PlayerScreen(url: playURL, title: currentItem.name,
                             subtitleCues: store.loadExternalSubtitleCues(for: currentItem),
                             resumeKey: currentItem.id.uuidString,
                             model: model) { dismiss() }
                    .id(playURL)
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
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .onAppear {
            store.touchPlayed(currentItem)
            model.onPlaybackEnded = { advanceToNext() }
            OrientationHelper.unlockForPlayback()
        }
        .onDisappear {
            model.stop()
            store.stopAccessing()
            store.refreshProgress()
            OrientationHelper.lockToPortrait()
        }
        .alert("重封装提示", isPresented: $showWarnings) {
            Button("继续播放") { }
        } message: {
            Text(warnings.joined(separator: "\n"))
        }
    }

    /// 自动连播：当前集播完后切到同剧的下一集（设置里可关）
    private func advanceToNext() {
        guard UserDefaults.standard.object(forKey: "settings.autoNext") as? Bool != false else { return }
        guard let next = store.nextInSeries(after: currentItem) else { return }
        AppLog.add("播放", "自动连播下一集：\(next.name)")
        model.stop()
        currentItem = next
        playURL = nil
        remuxProgress = nil
        failure = nil
        warnings = []
        store.touchPlayed(next)
        Task { await prepare() }
    }

    private var remuxCard: some View {
        VStack(spacing: 14) {
            LiuGuangGlyph()
            Text(currentItem.name)
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
        guard let url = store.resolveURL(for: currentItem) else {
            failure = "无法读取这个文件（书签失效或链接不可用），请删除后重新导入。"
            return
        }
        // 是否 MKV 按解析出的真实文件地址判断（片名不带扩展名，不能只看名字）
        if url.pathExtension.lowercased() != "mkv" {
            playURL = url
            return
        }
        AppLog.add("播放", "\(currentItem.name)：开始重封装 MKV")
        remuxProgress = 0
        let runner = RemuxRunner()
        do {
            let result = try await runner.run(input: url) { value in
                Task { @MainActor in remuxProgress = value }
            }
            remuxProgress = nil
            warnings = result.warnings
            playURL = result.outputURL
            AppLog.add("播放", "\(currentItem.name)：重封装完成，警告 \(result.warnings.count) 条")
            if !warnings.isEmpty { showWarnings = true }
        } catch let error as RemuxError {
            failure = error.errorDescription ?? "重封装失败。"
            AppLog.add("播放", "\(currentItem.name)：重封装失败 \(failure ?? "")")
        } catch {
            failure = "重封装失败：\(error.localizedDescription)"
            AppLog.add("播放", "\(currentItem.name)：\(failure ?? "")")
        }
    }
}

/// 把回调式 MP4Remuxer 包成 async
final class RemuxRunner {
    func run(input: URL, progress: @escaping (Double) -> Void) async throws -> RemuxResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try RemuxService().remux(input: input, progress: progress)
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
        ZStack(alignment: .topTrailing) {
            PlayerView(player: model.player, subtitleText: model.currentSubtitleText)
                .ignoresSafeArea()
            // 只保留一个关闭按钮：标题/徽章不再自绘，避免和系统播放器自带的标题层重叠
            VStack(alignment: .trailing, spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .onChange(of: model.videoIsLandscape) { _, isLandscape in
            // 横屏视频自动转横屏全屏
            if isLandscape == true {
                OrientationHelper.requestLandscape()
            }
        }
        .task {
            model.load(url: url, title: title, resumeKey: resumeKey)
            if let subtitleCues { model.setExternalSubtitles(subtitleCues) }
            model.player.play()
        }
    }
}

