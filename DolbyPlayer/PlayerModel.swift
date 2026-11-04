import AVFoundation
import Foundation

/// 播放核心：加载、续播位置记忆、格式徽章（杜比视界 / HDR / 编码）识别
@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()

    @Published var title: String = ""
    @Published var formatBadge: String = ""
    @Published var errorMessage: String?

    // 外挂字幕（叠加显示）：条目 + 当前时刻应显示的文本
    @Published private(set) var externalCues: [SubtitleCue] = []
    @Published var currentSubtitleText: String = ""

    private var timeObserver: Any?
    private var currentKey: String = ""
    private var didSeekToResume = false
    private var statusObservation: NSKeyValueObservation?

    init() {
        // 允许画中画 / 后台继续播放（需配合 Info.plist 的 UIBackgroundModes=audio 与音频会话）
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.currentKey.isEmpty else { return }
            let seconds = time.seconds
            if seconds.isFinite, seconds > 3 {
                let duration = self.player.currentItem?.duration.seconds ?? 0
                ResumeStore.save(key: self.currentKey, seconds: seconds,
                                 duration: duration.isFinite ? duration : 0)
            }
            if seconds.isFinite {
                self.updateCurrentSubtitle(at: seconds)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL, title: String, resumeKey: String = "") {
        self.title = title
        currentKey = resumeKey
        didSeekToResume = false
        formatBadge = ""
        errorMessage = nil

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self.detectFormat(asset: asset)
                    self.resumeIfNeeded(item: item)
                    if !self.externalCues.isEmpty,
                       let group = item.asset.mediaSelectionGroup(for: .legible) {
                        item.select(nil, in: group) // 有外挂字幕时不叠内封字幕
                    }
                    self.player.play()
                case .failed:
                    self.errorMessage = item.error?.localizedDescription
                        ?? "无法播放这个文件（格式可能不受系统支持，例如 MKV 需要先转封装成 MP4）"
                default:
                    break
                }
            }
        }
    }

    private func resumeIfNeeded(item: AVPlayerItem) {
        guard !didSeekToResume else { return }
        didSeekToResume = true
        // 设置里关掉「自动续播」时不跳转
        if UserDefaults.standard.object(forKey: "settings.autoResume") as? Bool == false { return }
        let saved = ResumeStore.position(forKey: currentKey) ?? 0
        guard saved > 3 else { return }
        let duration = item.duration.seconds
        if duration.isFinite, saved < duration - 10 {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 读视频轨的编码子类型，给界面显示一个格式徽章
    private func detectFormat(asset: AVAsset) {
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let descriptions = try? await track.load(.formatDescriptions),
                  let description = descriptions.first else { return }
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let code = Self.fourCC(subtype)
            let badge: String
            switch code {
            case "dvh1", "dvhe", "dvh5", "dvvt": // Dolby Vision 常见子类型
                badge = "Dolby Vision"
            case "hvc1", "hev1":
                badge = "HEVC"
            case "avc1":
                badge = "H.264"
            default:
                badge = code
            }
            self.formatBadge = badge
        }
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
    }

    // MARK: - 外挂字幕

    /// 设置外挂字幕条目；有外挂时关掉内封字幕的默认选中，避免两层字幕重叠
    func setExternalSubtitles(_ cues: [SubtitleCue]) {
        externalCues = cues
        currentSubtitleText = ""
        guard !cues.isEmpty,
              let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(for: .legible) else { return }
        item.select(nil, in: group)
    }

    private func updateCurrentSubtitle(at seconds: Double) {
        guard !externalCues.isEmpty else {
            if !currentSubtitleText.isEmpty { currentSubtitleText = "" }
            return
        }
        // 条目按开始时间排序，做一次线性扫描（0.5 秒一跳，量级足够）
        var found = ""
        for cue in externalCues {
            if seconds < cue.start { break }
            if seconds >= cue.start && seconds < cue.end { found = cue.text; break }
        }
        if found != currentSubtitleText { currentSubtitleText = found }
    }
}
