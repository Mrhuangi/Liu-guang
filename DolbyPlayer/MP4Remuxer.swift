import Foundation

// MARK: - 错误

enum RemuxError: LocalizedError {
    case notMatroska
    case noTracks
    case noCluster
    case noHEVCVideo
    case missingCodecPrivate
    case cannotCreateOutput
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notMatroska: return "不是有效的 MKV（Matroska）文件"
        case .noTracks: return "MKV 里没有找到轨道信息"
        case .noCluster: return "MKV 里没有找到数据簇"
        case .noHEVCVideo: return "只支持 HEVC 视频轨的 MKV（这部片的视频编码不是 HEVC）"
        case .missingCodecPrivate: return "视频轨缺少解码配置（hvcC），无法重封装"
        case .cannotCreateOutput: return "无法创建临时 MP4 文件"
        case .readFailed: return "读取源文件失败"
        case .writeFailed: return "写入临时 MP4 失败"
        }
    }
}

// MARK: - 结果

struct RemuxResult {
    var outputURL: URL
    var isDolbyVision: Bool
    var dvProfile: Int?
    var durationSeconds: Double
    var warnings: [String]
}

// MARK: - 字节工具

extension Data {
    mutating func appendU16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xff))
    }
    mutating func appendU32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff)); append(UInt8(v & 0xff))
    }
    mutating func appendU64(_ v: UInt64) {
        appendU32(UInt32(v >> 32)); appendU32(UInt32(v & 0xffff_ffff))
    }
    mutating func appendFourCC(_ s: String) { append(contentsOf: s.utf8) }
}

func mp4Box(_ type: String, _ payload: Data) -> Data {
    var out = Data()
    out.appendU32(UInt32(payload.count + 8))
    out.appendFourCC(type)
    out.append(payload)
    return out
}

/// MSB 优先的位写入器（用于 dac3 / dec3 / dvvC 配置记录）
final class BitWriter {
    private(set) var data = Data()
    private var current: UInt8 = 0
    private var bitsFilled = 0

    func write(_ value: UInt32, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            let bit = UInt8((value >> i) & 1)
            current = (current << 1) | bit
            bitsFilled += 1
            if bitsFilled == 8 {
                data.append(current)
                current = 0
                bitsFilled = 0
            }
        }
    }

    func finish() -> Data {
        if bitsFilled > 0 {
            current <<= (8 - bitsFilled)
            data.append(current)
            current = 0
            bitsFilled = 0
        }
        return data
    }
}

/// MSB 优先的位读取器（解析 AC3 / E-AC3 帧头）
struct BitReader {
    let bytes: [UInt8]
    var position = 0

    mutating func read(_ bits: Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<bits {
            let byteIndex = position / 8
            guard byteIndex < bytes.count else { return value }
            let bit = (bytes[byteIndex] >> (7 - (position % 8))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }

    mutating func skip(_ bits: Int) { position += bits }
}

// MARK: - 采样表

private struct Sample {
    var offset: UInt64 = 0   // 在输出 MP4 中的绝对偏移
    var size: Int = 0
    var ptsMs: Int64 = 0
    var isKey: Bool = false
    var durationMs: Int64 = 0  // >0 时直接采用（字幕轨用）
}

/// 一条从 MKV 字幕块读出的原始字幕（文本已清洗）
private struct RawSubtitleCue {
    var startMs: Int64
    var durationMs: Int64?   // 来自 BlockDuration，可能没有
    var text: String
}

private final class OutputTrack {
    var source: MKVTrack
    let isVideo: Bool
    let isSubtitle: Bool
    var samples: [Sample] = []
    var firstFrame: Data?
    var entryType: String = ""
    var entryConfigBox: Data?     // hvcC / esds / dac3 / dec3 / dvvC 等子盒子拼好的数据
    var skipped = false
    var subtitleCues: [RawSubtitleCue] = []

    init(source: MKVTrack, isVideo: Bool, isSubtitle: Bool = false) {
        self.source = source
        self.isVideo = isVideo
        self.isSubtitle = isSubtitle
    }
}

// MARK: - 重封装服务

/// MKV → MP4 无损重封装：EBML 解析 → 帧流式拷贝 → 生成 dvh1/dvvC + 采样表 → AVPlayer 可播的 MP4。
/// 只换容器、不重新编码；视频流（含杜比视界 RPU）原样搬运。
final class RemuxService {

    func remux(input: URL, progress: @escaping (Double) -> Void) throws -> RemuxResult {
        // 重封装缓存：来源文件指纹（路径+大小+修改时间）没变且产物还在 → 直接复用，二次起播免重封装
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let plainOutName = input.deletingPathExtension().lastPathComponent + ".mp4"
        if let fingerprint = Self.sourceFingerprint(input),
           let saved = Self.stampIndex()[plainOutName],
           saved.hasPrefix(fingerprint + "|") {
            let parts = saved.split(separator: "|", omittingEmptySubsequences: false)
            let plainOut = cachesDir.appendingPathComponent(plainOutName)
            if parts.count == 6,
               ((try? plainOut.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 {
                AppLog.add("播放", "重封装缓存命中，跳过重封装：\(plainOutName)")
                progress(1.0)
                return RemuxResult(outputURL: plainOut,
                                   isDolbyVision: parts[3] == "1",
                                   dvProfile: Int(parts[4]).flatMap { $0 >= 0 ? $0 : nil },
                                   durationSeconds: Double(parts[5]) ?? 0,
                                   warnings: [])
            }
        }

        let demuxer = try MatroskaDemuxer(url: input)
        defer { demuxer.close() }
        try demuxer.parseHeader()

        // 选轨
        guard let videoTrack = demuxer.tracks.first(where: { $0.type == 1 && $0.codecID == "V_MPEGH/ISO/HEVC" }) else {
            throw RemuxError.noHEVCVideo
        }
        guard let hvcC = videoTrack.codecPrivate, hvcC.count > 22, hvcC[0] == 1 else {
            throw RemuxError.missingCodecPrivate
        }
        let nalLengthSize = Int(hvcC[21] & 0x03) + 1

        var warnings: [String] = []
        var outputTracks: [OutputTrack] = [OutputTrack(source: videoTrack, isVideo: true)]
        var audioByNumber: [UInt64: OutputTrack] = [:]
        for track in demuxer.tracks where track.type == 2 {
            if ["A_AC3", "A_EAC3", "A_AAC"].contains(track.codecID) {
                let ot = OutputTrack(source: track, isVideo: false)
                outputTracks.append(ot)
                audioByNumber[track.number] = ot
            } else {
                warnings.append("跳过不支持的音频轨（\(track.codecID)）")
            }
        }
        var subtitleByNumber: [UInt64: OutputTrack] = [:]
        for track in demuxer.tracks where track.type == 17 {
            if track.isTextSubtitle {
                let ot = OutputTrack(source: track, isVideo: false, isSubtitle: true)
                // 语言缺失时按轨道名兜底（如「简体中文」「CHS」），让播放器认得出中文字幕、能默认选中
                if ot.source.language.isEmpty {
                    let n = ot.source.name
                    let upper = n.uppercased()
                    if n.contains("简") || n.contains("繁") || n.contains("中文")
                        || upper.contains("CHS") || upper.contains("CHT") || upper.contains("CHI") {
                        ot.source.language = "chi"
                    } else if upper.contains("ENG") || n.contains("英文") {
                        ot.source.language = "eng"
                    } else if n.contains("日") || upper.contains("JPN") {
                        ot.source.language = "jpn"
                    }
                }
                outputTracks.append(ot)
                subtitleByNumber[track.number] = ot
            } else if track.isImageSubtitle {
                warnings.append("跳过图形字幕轨（\(track.codecID)）：PGS/VobSub 是图片字幕，无法转成文本字幕")
            } else {
                warnings.append("跳过不支持的字幕轨（\(track.codecID)）")
            }
        }
        let videoOut = outputTracks[0]

        // 输出文件
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let outURL = caches.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".mp4")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: outURL) else {
            throw RemuxError.cannotCreateOutput
        }
        defer { try? outHandle.close() }
        guard let readHandle = try? FileHandle(forReadingFrom: input) else {
            throw RemuxError.readFailed
        }
        defer { try? readHandle.close() }

        var writeOffset: UInt64 = 0
        func write(_ data: Data) throws {
            do { try outHandle.write(contentsOf: data) } catch { throw RemuxError.writeFailed }
            writeOffset += UInt64(data.count)
        }

        // ftyp
        var ftypPayload = Data()
        ftypPayload.appendFourCC("isom")
        ftypPayload.appendU32(0x200)
        ftypPayload.appendFourCC("isom"); ftypPayload.appendFourCC("iso6"); ftypPayload.appendFourCC("mp41")
        if videoTrack.dolbyVisionConfig != nil { ftypPayload.appendFourCC("dvh1") }
        try write(mp4Box("ftyp", ftypPayload))

        // mdat（64 位 largesize，先占位、最后回填）
        let mdatStart = writeOffset
        var mdatHeader = Data()
        mdatHeader.appendU32(1)
        mdatHeader.appendFourCC("mdat")
        mdatHeader.appendU64(0)
        try write(mdatHeader)

        // 帧流式拷贝
        let scale = Double(demuxer.timecodeScaleNs)
        var frameCounter = 0
        try demuxer.iterateFrames { frame in
            let target: OutputTrack?
            if frame.trackNumber == videoTrack.number {
                target = videoOut
            } else if let sub = subtitleByNumber[frame.trackNumber] {
                target = sub
            } else {
                target = audioByNumber[frame.trackNumber]
            }
            guard let track = target else { return true } // 未选轨道跳过

            // 字幕帧：整帧读入内存清洗成文本条目，先攒着，最后统一写成 mov_text 采样
            if track.isSubtitle {
                try readHandle.seek(toOffset: frame.fileOffset)
                let data = readHandle.readData(ofLength: frame.length)
                guard data.count == frame.length else { throw RemuxError.readFailed }
                let rawText = SubtitleParser.decodeText(data) ?? ""
                let cleaned: String
                switch track.source.codecID.uppercased() {
                case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA":
                    cleaned = SubtitleParser.textFromMKVASSBlock(rawText)
                case "S_TEXT/WEBVTT":
                    cleaned = SubtitleParser.textFromMKVWebVTTBlock(rawText)
                default:
                    cleaned = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !cleaned.isEmpty {
                    let startMs = Int64((Double(frame.timecodeUnits) * scale / 1_000_000.0).rounded())
                    let durMs = frame.blockDurationUnits.map {
                        Int64((Double($0) * scale / 1_000_000.0).rounded())
                    }
                    track.subtitleCues.append(RawSubtitleCue(startMs: startMs,
                                                             durationMs: durMs,
                                                             text: cleaned))
                }
                return true
            }

            // 拷贝帧数据（分块流式，避免大帧占内存）
            var copied = 0
            var capture = Data()
            let wantCapture = track.firstFrame == nil
            try readHandle.seek(toOffset: frame.fileOffset)
            while copied < frame.length {
                let chunk = min(256 * 1024, frame.length - copied)
                let data = readHandle.readData(ofLength: chunk)
                guard data.count == chunk else { throw RemuxError.readFailed }
                if wantCapture && capture.count < 131_072 {
                    capture.append(data.prefix(131_072 - capture.count))
                }
                try write(data)
                copied += chunk
            }
            if wantCapture { track.firstFrame = capture }

            track.samples.append(Sample(
                offset: writeOffset - UInt64(frame.length),
                size: frame.length,
                ptsMs: Int64((Double(frame.timecodeUnits) * scale / 1_000_000.0).rounded()),
                isKey: frame.isKeyframe))

            frameCounter += 1
            if frameCounter % 300 == 0 {
                progress(min(0.98, Double(demuxer.reader.position) / Double(max(1, demuxer.reader.fileSize))))
            }
            return true
        }

        // 字幕采样物化：算每条的结束时间、补空白采样填时间空档，写成 mov_text 采样追加进 mdat
        for track in outputTracks where track.isSubtitle {
            let cues = track.subtitleCues.sorted { $0.startMs < $1.startMs }
            var cursor: Int64 = 0
            for (index, cue) in cues.enumerated() {
                let nextStart = index + 1 < cues.count ? cues[index + 1].startMs : nil
                var end = cue.durationMs.map { cue.startMs + $0 } ?? nextStart ?? (cue.startMs + 2500)
                if end <= cue.startMs { end = nextStart ?? (cue.startMs + 1000) }
                if let nextStart, end > nextStart { end = nextStart }
                if end <= cue.startMs { continue }

                if cue.startMs > cursor {
                    // 空档（含第一条之前的偏移）：写一个空采样把时间轴补齐
                    var empty = Data()
                    empty.appendU16(0)
                    track.samples.append(Sample(offset: writeOffset, size: empty.count,
                                                ptsMs: cursor, durationMs: cue.startMs - cursor))
                    try write(empty)
                }
                var sampleData = Data()
                let utf8 = Array(cue.text.utf8.prefix(65_535))
                sampleData.appendU16(UInt16(utf8.count))
                sampleData.append(contentsOf: utf8)
                track.samples.append(Sample(offset: writeOffset, size: sampleData.count,
                                            ptsMs: cue.startMs, durationMs: end - cue.startMs))
                try write(sampleData)
                cursor = end
            }
            if track.samples.isEmpty {
                track.skipped = true
                warnings.append("一条字幕轨没有可用文本，已跳过（\(track.source.codecID)）")
            }
        }

        // 回填 mdat 大小
        let mdatTotal = writeOffset - mdatStart
        try outHandle.seek(toOffset: mdatStart + 8)
        var sizeData = Data()
        sizeData.appendU64(mdatTotal)
        try outHandle.write(contentsOf: sizeData)
        try outHandle.seek(toOffset: writeOffset)

        // 杜比视界判定：优先轨道里的 dvvc 配置；否则扫第一帧找 RPU NAL（type 62）
        var dvConfigRecord: Data? = videoTrack.dolbyVisionConfig
        var dvProfile: Int?
        var hasEL = false
        if let record = dvConfigRecord, record.count >= 3 {
            dvProfile = Int(record[2] >> 1)
        } else if let first = videoOut.firstFrame {
            let (foundRPU, foundEL) = Self.scanDV(in: first, nalLengthSize: nalLengthSize)
            hasEL = foundEL
            if foundRPU {
                dvProfile = 5 // Netflix 等 WEB-DL 的单层 DV 绝大多数是 Profile 5
                let level: UInt32 = (videoTrack.pixelWidth >= 3840 || videoTrack.pixelHeight >= 2160) ? 9
                    : (videoTrack.pixelWidth >= 1920 ? 6 : 3)
                let bw = BitWriter()
                bw.write(1, bits: 8)          // dv_version_major
                bw.write(0, bits: 8)          // dv_version_minor
                bw.write(5, bits: 7)          // dv_profile
                bw.write(level, bits: 6)      // dv_level
                bw.write(1, bits: 1)          // rpu_present_flag
                bw.write(0, bits: 1)          // el_present_flag
                bw.write(1, bits: 1)          // bl_present_flag
                bw.write(0, bits: 4)          // dv_bl_signal_compatibility_id（P5 = 0）
                bw.write(0, bits: 28)         // reserved
                for _ in 0..<4 { bw.write(0, bits: 32) } // reserved
                dvConfigRecord = bw.finish()
            }
        }
        if hasEL {
            warnings.append("检测到双层杜比视界（EL），简单重封装可能无法正确呈现增强层")
        }
        let isDV = dvConfigRecord != nil

        // 音频轨配置（需要第一帧的轨在这里生成配置盒；生成失败的轨跳过）
        for track in outputTracks where !track.isVideo && !track.isSubtitle {
            if !Self.buildAudioEntry(track) {
                track.skipped = true
                warnings.append("一条音频轨配置解析失败，已跳过（\(track.source.codecID)）")
            }
        }
        let activeTracks = outputTracks.filter { !$0.skipped && !$0.samples.isEmpty }
        guard activeTracks.contains(where: { $0.isVideo }) else { throw RemuxError.noHEVCVideo }

        // moov
        let moov = Self.buildMoov(tracks: activeTracks, isDV: isDV, dvConfig: dvConfigRecord, hvcC: hvcC)
        try write(moov)
        progress(1.0)

        let durationMs = activeTracks.map { Self.trackEndMs($0) }.max() ?? 0
        // 记录缓存指纹，并只保留最近两个重封装产物，避免大文件塞满缓存目录
        if let fingerprint = Self.sourceFingerprint(input) {
            var index = Self.stampIndex()
            index[outURL.lastPathComponent] = "\(fingerprint)|\(isDV ? 1 : 0)|\(dvProfile ?? -1)|\(Double(durationMs) / 1000.0)"
            Self.pruneRemuxOutputs(in: caches, keeping: outURL, index: &index)
            UserDefaults.standard.set(index, forKey: Self.stampKey)
        }
        return RemuxResult(outputURL: outURL,
                           isDolbyVision: isDV,
                           dvProfile: dvProfile,
                           durationSeconds: Double(durationMs) / 1000.0,
                           warnings: warnings)
    }

    // MARK: 重封装缓存指纹

    private static let stampKey = "remux.cache.v1"

    private static func sourceFingerprint(_ input: URL) -> String? {
        guard let values = try? input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let mtime = values.contentModificationDate else { return nil }
        return "\(input.path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
    }

    private static func stampIndex() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: stampKey) as? [String: String] ?? [:]
    }

    private static func pruneRemuxOutputs(in dir: URL, keeping: URL, index: inout [String: String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        var dated: [(url: URL, date: Date)] = []
        for file in files where file.pathExtension.lowercased() == "mp4" {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
               values.isDirectory != true {
                dated.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        dated.sort { $0.date > $1.date }
        var keptOthers = 0
        for entry in dated where entry.url != keeping {
            keptOthers += 1
            if keptOthers > 1 {
                try? FileManager.default.removeItem(at: entry.url)
                index.removeValue(forKey: entry.url.lastPathComponent)
            }
        }
    }

    // MARK: - DV 扫描

    /// 在 HEVC 样本里找 RPU（NAL type 62）与 EL（type 63）
    private static func scanDV(in sample: Data, nalLengthSize: Int) -> (rpu: Bool, el: Bool) {
        var rpu = false, el = false
        var pos = 0
        let bytes = [UInt8](sample)
        while pos + nalLengthSize < bytes.count {
            var len = 0
            for i in 0..<nalLengthSize { len = (len << 8) | Int(bytes[pos + i]) }
            let nalStart = pos + nalLengthSize
            guard len > 0, nalStart < bytes.count else { break }
            let nalType = (bytes[nalStart] >> 1) & 0x3F
            if nalType == 62 { rpu = true }
            if nalType == 63 { el = true }
            pos = nalStart + len
        }
        return (rpu, el)
    }

    // MARK: - 音频配置盒

    private static func buildAudioEntry(_ track: OutputTrack) -> Bool {
        let src = track.source
        let channels = src.channels > 0 ? src.channels : 2
        let rate = src.sampleRate > 0 ? Int(src.sampleRate) : 48_000
        track.entryType = ""

        switch src.codecID {
        case "A_AAC":
            guard let asc = src.codecPrivate, asc.count >= 2 else { return false }
            track.entryType = "mp4a"
            track.entryConfigBox = mp4Box("esds", esdsPayload(asc: asc))
        case "A_AC3":
            guard let first = track.firstFrame, let dac3 = dac3Payload(firstFrame: first) else { return false }
            track.entryType = "ac-3"
            track.entryConfigBox = mp4Box("dac3", dac3)
        case "A_EAC3":
            guard let first = track.firstFrame,
                  let dec3 = dec3Payload(firstFrame: first, channels: channels) else { return false }
            track.entryType = "ec-3"
            track.entryConfigBox = mp4Box("dec3", dec3)
        default:
            return false
        }
        // 声道/采样率存回 source，供 stsd 使用
        track.source.channels = channels
        track.source.sampleRate = Double(rate)
        return true
    }

    private static func esdsPayload(asc: Data) -> Data {
        var d = Data()
        d.appendU32(0) // version/flags
        // ES_Descriptor (tag 0x03)
        var es = Data()
        es.appendU16(0)          // ES_ID
        es.append(0)             // flags
        // DecoderConfigDescriptor (tag 0x04)
        var dc = Data()
        dc.append(0x40)          // objectTypeIndication = AAC
        dc.append(0x15)          // streamType = audio, upstream = 0
        dc.append(contentsOf: [0, 0, 0]) // bufferSizeDB
        dc.appendU32(0)          // maxBitrate
        dc.appendU32(0)          // avgBitrate
        // DecoderSpecificInfo (tag 0x05)
        dc.append(0x05)
        dc.append(UInt8(asc.count))
        dc.append(asc)
        es.append(0x04)
        es.append(UInt8(dc.count))
        es.append(dc)
        // SLConfigDescriptor (tag 0x06)
        es.append(0x06); es.append(1); es.append(0x02)
        d.append(0x03)
        d.append(UInt8(es.count))
        d.append(es)
        return d
    }

    /// AC-3 dac3（3 字节）：fscod(2) frmsizecod/2(5) bsid(5) bsmod(3) acmod(3) lfeon(1) reserved(5)
    private static func dac3Payload(firstFrame: Data) -> Data? {
        var br = BitReader(bytes: [UInt8](firstFrame))
        guard br.read(16) == 0x0B77 else { return nil }
        br.skip(16) // crc1
        let fscod = br.read(2)
        let frmsizecod = br.read(6)
        let bsid = br.read(5)
        let bsmod = br.read(3)
        let acmod = br.read(3)
        if acmod == 0 {
            br.skip(2) // dsurmod
        } else {
            if (acmod & 1) == 1 && acmod != 1 { br.skip(2) } // cmixlev
            if (acmod & 4) == 4 { br.skip(2) }               // surmixlev
        }
        let lfeon = br.read(1)
        let bw = BitWriter()
        bw.write(fscod, bits: 2)
        bw.write(frmsizecod >> 1, bits: 5)
        bw.write(bsid, bits: 5)
        bw.write(bsmod, bits: 3)
        bw.write(acmod, bits: 3)
        bw.write(lfeon, bits: 1)
        bw.write(0, bits: 5)
        return bw.finish()
    }

    /// E-AC3 dec3：data_rate(13) num_ind_sub(3)，每子流 fscod(2) bsid(5) asvc(1) bsmod(3) acmod(3) lfeon(1) reserved(3) num_dep_sub(4)
    private static func dec3Payload(firstFrame: Data, channels: Int) -> Data? {
        var br = BitReader(bytes: [UInt8](firstFrame))
        guard br.read(16) == 0x0B77 else { return nil }
        br.skip(2)  // strmtyp
        br.skip(3)  // substreamid
        let frmsiz = br.read(11)
        let fscod = br.read(2)
        let sampleRate: Int
        let samplesPerFrame: Int
        if fscod == 3 {
            let fscod2 = br.read(2)
            sampleRate = [24_000, 22_050, 16_000, 12_000][Int(fscod2)]
            samplesPerFrame = 1536
        } else {
            sampleRate = [48_000, 44_100, 32_000][Int(fscod)]
            let numblkscod = br.read(2)
            samplesPerFrame = [256, 512, 768, 1536][Int(numblkscod)]
        }
        let frameBytes = (Int(frmsiz) + 1) * 2
        let dataRate = max(1, frameBytes * 8 * sampleRate / samplesPerFrame / 1000)

        // acmod 由声道数推导（2=2/0，6=3/2+LFE 等），bsid E-AC3 常见为 11
        let acmod: UInt32 = channels >= 6 ? 7 : (channels == 2 ? 2 : 7)
        let lfeon: UInt32 = channels >= 6 ? 1 : 0

        let bw = BitWriter()
        bw.write(UInt32(dataRate), bits: 13)
        bw.write(0, bits: 3)   // num_ind_sub = 0（1 个独立子流）
        bw.write(fscod, bits: 2)
        bw.write(11, bits: 5)  // bsid
        bw.write(0, bits: 1)   // asvc
        bw.write(0, bits: 3)   // bsmod
        bw.write(acmod, bits: 3)
        bw.write(lfeon, bits: 1)
        bw.write(0, bits: 3)   // reserved
        bw.write(0, bits: 4)   // num_dep_sub
        return bw.finish()
    }

    // MARK: - 时间表计算

    /// 计算每轨的 DTS 数组与时长数组（毫秒）
    private static func timing(for track: OutputTrack) -> (dts: [Int64], durations: [Int64], endMs: Int64) {
        let samples = track.samples
        guard !samples.isEmpty else { return ([], [], 0) }
        var dts = [Int64](repeating: 0, count: samples.count)

        if track.isVideo {
            // 解码序的 DTS 用呈现时间排序近似（标准重封装近似法）
            let sorted = samples.map { $0.ptsMs }.sorted()
            for i in samples.indices { dts[i] = sorted[i] }
            // 安全修正：保证单调且不大于自身 PTS
            for i in samples.indices {
                if i > 0 && dts[i] <= dts[i - 1] { dts[i] = dts[i - 1] + 1 }
                if dts[i] > samples[i].ptsMs { dts[i] = samples[i].ptsMs }
                if i > 0 && dts[i] <= dts[i - 1] { dts[i] = dts[i - 1] + 1 }
            }
        } else {
            for i in samples.indices { dts[i] = samples[i].ptsMs }
        }

        var durations = [Int64](repeating: 0, count: samples.count)
        for i in samples.indices {
            if samples[i].durationMs > 0 {
                durations[i] = samples[i].durationMs
            } else if i + 1 < samples.count {
                durations[i] = max(1, dts[i + 1] - dts[i])
            } else if i > 0 {
                durations[i] = durations[i - 1]
            } else {
                durations[i] = track.isVideo ? 42 : 32
            }
        }
        var end: Int64 = 0
        for i in samples.indices {
            end = max(end, max(dts[i], samples[i].ptsMs) + durations[i])
        }
        return (dts, durations, end)
    }

    fileprivate static func trackEndMs(_ track: OutputTrack) -> Int64 {
        timing(for: track).endMs
    }

    // MARK: - moov 构建

    private static func buildMoov(tracks: [OutputTrack], isDV: Bool, dvConfig: Data?, hvcC: Data) -> Data {
        let movieDuration = tracks.map { trackEndMs($0) }.max() ?? 0
        let now1904 = UInt32(Date().timeIntervalSince1970 + 2_082_844_800)

        var mvhd = Data()
        mvhd.appendU32(0) // version/flags
        mvhd.appendU32(now1904); mvhd.appendU32(now1904)
        mvhd.appendU32(1000) // timescale
        mvhd.appendU32(UInt32(movieDuration))
        mvhd.appendU32(0x0001_0000) // rate
        mvhd.appendU16(0x0100)      // volume
        mvhd.appendU16(0)
        mvhd.appendU32(0); mvhd.appendU32(0)
        for v in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] as [Int32] { mvhd.appendU32(UInt32(bitPattern: v)) }
        for _ in 0..<6 { mvhd.appendU32(0) }
        mvhd.appendU32(UInt32(tracks.count + 1)) // nextTrackID

        var moovPayload = Data()
        moovPayload.append(mp4Box("mvhd", mvhd))
        for (index, track) in tracks.enumerated() {
            moovPayload.append(buildTrak(track: track, trackID: index + 1,
                                         movieDuration: movieDuration, now1904: now1904,
                                         isDV: isDV, dvConfig: dvConfig, hvcC: hvcC))
        }
        return mp4Box("moov", moovPayload)
    }

    private static func buildTrak(track: OutputTrack, trackID: Int, movieDuration: Int64,
                                  now1904: UInt32, isDV: Bool, dvConfig: Data?, hvcC: Data) -> Data {
        let (dts, durations, endMs) = timing(for: track)
        let samples = track.samples
        let src = track.source

        // tkhd
        var tkhd = Data()
        tkhd.appendU32(0x0000_0007) // version 0, flags = enabled|in_movie|in_preview
        tkhd.appendU32(now1904); tkhd.appendU32(now1904)
        tkhd.appendU32(UInt32(trackID))
        tkhd.appendU32(0)
        tkhd.appendU32(UInt32(endMs)) // duration（电影时间尺度 1000）
        tkhd.appendU32(0); tkhd.appendU32(0)
        tkhd.appendU16(0) // layer
        tkhd.appendU16(0) // alternate group
        tkhd.appendU16(track.isVideo || track.isSubtitle ? 0 : 0x0100) // volume
        tkhd.appendU16(0)
        for v in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] as [Int32] { tkhd.appendU32(UInt32(bitPattern: v)) }
        tkhd.appendU32(track.isVideo ? UInt32(src.pixelWidth) << 16 : 0)
        tkhd.appendU32(track.isVideo ? UInt32(src.pixelHeight) << 16 : 0)

        var trakPayload = Data()
        trakPayload.append(mp4Box("tkhd", tkhd))

        // edts/elst：第一帧呈现时间不为 0 时补编辑列表
        if track.isVideo, let first = samples.first, first.ptsMs > 0 {
            var elst = Data()
            elst.appendU32(0)
            elst.appendU32(1)
            elst.appendU32(UInt32(movieDuration))
            elst.appendU32(UInt32(first.ptsMs)) // media_time
            elst.appendU16(1) // rate integer
            elst.appendU16(0)
            trakPayload.append(mp4Box("edts", mp4Box("elst", elst)))
        }

        // mdhd
        var mdhd = Data()
        mdhd.appendU32(0)
        mdhd.appendU32(now1904); mdhd.appendU32(now1904)
        mdhd.appendU32(1000) // track timescale = 毫秒
        mdhd.appendU32(UInt32(endMs))
        mdhd.appendU16(packLanguage(track.isSubtitle || !track.isVideo ? src.language : "")) // 语言
        mdhd.appendU16(0)

        // hdlr
        var hdlr = Data()
        hdlr.appendU32(0)
        hdlr.appendU32(0)
        hdlr.appendFourCC(track.isVideo ? "vide" : (track.isSubtitle ? "text" : "soun"))
        hdlr.appendU32(0); hdlr.appendU32(0); hdlr.appendU32(0)
        hdlr.append(contentsOf: (track.isVideo ? "VideoHandler" : (track.isSubtitle ? "TextHandler" : "SoundHandler")).utf8)
        hdlr.append(0)

        // stbl
        var stbl = Data()
        stbl.append(mp4Box("stsd", stsd(for: track, isDV: isDV, dvConfig: dvConfig, hvcC: hvcC)))
        stbl.append(mp4Box("stts", rleBox(pairs: rle(durations.map { UInt32(max(1, $0)) }))))
        if track.isVideo {
            let ctts = zip(samples, dts).map { UInt32(max(0, $0.ptsMs - $1)) }
            if ctts.contains(where: { $0 > 0 }) {
                stbl.append(mp4Box("ctts", rleBox(pairs: rle(ctts))))
            }
            let keys = samples.enumerated().filter { $0.element.isKey }.map { UInt32($0.offset + 1) }
            if !keys.isEmpty {
                var stss = Data()
                stss.appendU32(0); stss.appendU32(UInt32(keys.count))
                for k in keys { stss.appendU32(k) }
                stbl.append(mp4Box("stss", stss))
            }
        }
        var stsc = Data()
        stsc.appendU32(0); stsc.appendU32(1)
        stsc.appendU32(1); stsc.appendU32(1); stsc.appendU32(1) // 每块 1 个采样
        stbl.append(mp4Box("stsc", stsc))
        var stsz = Data()
        stsz.appendU32(0); stsz.appendU32(0); stsz.appendU32(UInt32(samples.count))
        for s in samples { stsz.appendU32(UInt32(s.size)) }
        stbl.append(mp4Box("stsz", stsz))
        var co64 = Data()
        co64.appendU32(0); co64.appendU32(UInt32(samples.count))
        for s in samples { co64.appendU64(s.offset) }
        stbl.append(mp4Box("co64", co64))

        // minf
        var minfPayload = Data()
        if track.isVideo {
            var vmhd = Data()
            vmhd.appendU32(1) // version 0, flags 1
            vmhd.appendU16(0); vmhd.appendU16(0); vmhd.appendU16(0); vmhd.appendU16(0)
            minfPayload.append(mp4Box("vmhd", vmhd))
        } else if track.isSubtitle {
            var nmhd = Data()
            nmhd.appendU32(0) // version/flags
            minfPayload.append(mp4Box("nmhd", nmhd))
        } else {
            var smhd = Data()
            smhd.appendU32(0); smhd.appendU16(0); smhd.appendU16(0)
            minfPayload.append(mp4Box("smhd", smhd))
        }
        var urlBox = Data()
        urlBox.appendU32(1) // self-contained
        var dref = Data()
        dref.appendU32(0); dref.appendU32(1)
        dref.append(mp4Box("url ", urlBox))
        minfPayload.append(mp4Box("dinf", mp4Box("dref", dref)))
        minfPayload.append(mp4Box("stbl", stbl))

        var mdia = Data()
        mdia.append(mp4Box("mdhd", mdhd))
        mdia.append(mp4Box("hdlr", hdlr))
        mdia.append(mp4Box("minf", minfPayload))
        trakPayload.append(mp4Box("mdia", mdia))

        return mp4Box("trak", trakPayload)
    }

    /// ISO 639 语言代码打包成 mdhd 的 15 位格式（每字符 5 位，值 = ASCII - 0x60）
    private static func packLanguage(_ raw: String) -> UInt16 {
        var code = raw.lowercased()
        let twoLetter: [String: String] = [
            "zh": "chi", "en": "eng", "ja": "jpn", "ko": "kor", "fr": "fra",
            "de": "ger", "es": "spa", "ru": "rus", "it": "ita", "pt": "por"
        ]
        if code.count == 2, let mapped = twoLetter[code] { code = mapped }
        if code == "zho" { code = "chi" }
        if code == "yue" { code = "chi" }
        let chars = Array(code.utf8.prefix(3))
        guard chars.count == 3 else { return 0x55C4 } // 'und'
        var packed: UInt16 = 0
        for c in chars {
            packed = (packed << 5) | UInt16(max(0, Int(c) - 0x60))
        }
        return packed
    }

    /// stts / ctts 的游程编码盒内容（version/flags + count + pairs）
    private static func rleBox(pairs: [(UInt32, UInt32)]) -> Data {
        var d = Data()
        d.appendU32(0)
        d.appendU32(UInt32(pairs.count))
        for (count, value) in pairs {
            d.appendU32(count); d.appendU32(value)
        }
        return d
    }

    private static func rle(_ values: [UInt32]) -> [(UInt32, UInt32)] {
        var out: [(UInt32, UInt32)] = []
        for v in values {
            if var last = out.last, last.1 == v {
                last.0 += 1
                out[out.count - 1] = last
            } else {
                out.append((1, v))
            }
        }
        return out
    }

    // MARK: - stsd

    private static func stsd(for track: OutputTrack, isDV: Bool, dvConfig: Data?, hvcC: Data) -> Data {
        let src = track.source
        var entry = Data()
        entry.append(contentsOf: [UInt8](repeating: 0, count: 6)) // reserved
        entry.appendU16(1) // data_reference_index

        if track.isVideo {
            entry.appendU32(0) // pre_defined(2) + reserved(2)
            entry.appendU32(0) // pre_defined[0]
            entry.appendU32(0) // pre_defined[1]
            entry.appendU32(0) // pre_defined[2]
            entry.appendU16(UInt16(src.pixelWidth))
            entry.appendU16(UInt16(src.pixelHeight))
            entry.appendU32(0x0048_0000) // horizresolution 72dpi
            entry.appendU32(0x0048_0000) // vertresolution
            entry.appendU32(0)           // reserved
            entry.appendU16(1)           // frame_count
            entry.append(contentsOf: [UInt8](repeating: 0, count: 32)) // compressorname
            entry.appendU16(0x0018)      // depth
            entry.append(UInt8(0xFF)); entry.append(UInt8(0xFF)) // pre_defined = -1
            entry.append(mp4Box("hvcC", hvcC))
            if isDV, let dvConfig {
                entry.append(mp4Box("dvvC", dvConfig))
            }
            let type = isDV ? "dvh1" : "hvc1"
            var sd = Data()
            sd.appendU32(0); sd.appendU32(1)
            sd.append(mp4Box(type, entry))
            return sd
        } else if track.isSubtitle {
            // tx3g（mov_text）样本入口
            entry.appendU32(0)            // displayFlags
            entry.append(1)               // horizontal-justification = 居中
            entry.append(UInt8(bitPattern: -1)) // vertical-justification = 底部
            entry.append(contentsOf: [0, 0, 0, 0]) // 背景色 RGBA（透明）
            entry.appendU16(0); entry.appendU16(0) // box top / left
            entry.appendU16(0); entry.appendU16(0) // box bottom / right（0 = 全轨）
            // StyleRecord
            entry.appendU16(0)            // startChar
            entry.appendU16(0)            // endChar（0 = 全部）
            entry.appendU16(1)            // font-ID
            entry.append(0)               // face-style-flags
            entry.append(18)              // font-size（系统会按字幕设置再缩放）
            entry.append(contentsOf: [255, 255, 255, 255]) // 文字色 RGBA（白）
            // FontTableBox 'ftab'
            var ftab = Data()
            ftab.appendU16(1)             // entry count
            ftab.appendU16(1)             // font-ID
            let fontName = "Serif"
            ftab.append(UInt8(fontName.count))
            ftab.append(contentsOf: fontName.utf8)
            entry.append(mp4Box("ftab", ftab))
            var sd = Data()
            sd.appendU32(0); sd.appendU32(1)
            sd.append(mp4Box("tx3g", entry))
            return sd
        } else {
            entry.appendU16(0) // version
            entry.appendU16(0) // revision
            entry.appendU32(0) // vendor
            entry.appendU16(UInt16(src.channels))
            entry.appendU16(16) // sample size
            entry.appendU16(0)  // compression
            entry.appendU16(0)  // packet size
            entry.appendU32(UInt32(src.sampleRate) << 16)
            if let config = track.entryConfigBox {
                entry.append(config)
            }
            var sd = Data()
            sd.appendU32(0); sd.appendU32(1)
            sd.append(mp4Box(track.entryType, entry))
            return sd
        }
    }
}
