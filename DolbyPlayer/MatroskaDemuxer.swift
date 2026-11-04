import Foundation

// MARK: - EBML 基础读取（带缓冲的文件流）

/// EBML 变长整数 / 元素读取器。所有读取都基于文件偏移，帧数据只报偏移与长度、不进内存。
final class EBMLReader {
    let handle: FileHandle
    let fileSize: UInt64
    private(set) var position: UInt64 = 0

    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    private let bufferCapacity = 512 * 1024

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)
    }

    func close() { try? handle.close() }

    func seek(to offset: UInt64) {
        position = offset
        if offset < bufferStart || offset >= bufferStart + UInt64(buffer.count) {
            buffer.removeAll(keepingCapacity: true)
            bufferStart = offset
        }
    }

    private func fillBuffer() throws {
        if position >= bufferStart && position < bufferStart + UInt64(buffer.count) { return }
        bufferStart = position
        try handle.seek(toOffset: position)
        buffer = handle.readData(ofLength: bufferCapacity)
    }

    func readByte() throws -> UInt8 {
        try fillBuffer()
        let idx = Int(position - bufferStart)
        guard idx < buffer.count else { throw EBMLReaderError.endOfFile }
        position += 1
        return buffer[idx]
    }

    func readBytes(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            try fillBuffer()
            let idx = Int(position - bufferStart)
            guard idx < buffer.count else { throw EBMLReaderError.endOfFile }
            let take = min(count - out.count, buffer.count - idx)
            out.append(buffer.subdata(in: idx..<(idx + take)))
            position += UInt64(take)
        }
        return out
    }

    /// 读取元素 ID（最长 4 字节，含标记位）
    func readID() throws -> UInt32 {
        let first = try readByte()
        let len = Self.leadingLength(of: first, max: 4)
        var value = UInt32(first)
        for _ in 1..<len { value = (value << 8) | UInt32(try readByte()) }
        return value
    }

    /// 读取数据大小（变长整数，去标记位）。返回 (值, 字节数, 是否未知大小)
    func readSize() throws -> (value: UInt64, length: Int, unknown: Bool) {
        let first = try readByte()
        let len = Self.leadingLength(of: first, max: 8)
        var value = UInt64(first & (0xFF >> len))
        for _ in 1..<len { value = (value << 8) | UInt64(try readByte()) }
        let maxValue = (UInt64(1) << (7 * len)) - 2
        return (value, len, value > maxValue)
    }

    /// 读取普通变长整数（去标记位），返回（值, 字节数）
    func readVInt() throws -> (value: UInt64, length: Int) {
        let first = try readByte()
        let len = Self.leadingLength(of: first, max: 8)
        var value = UInt64(first & (0xFF >> len))
        for _ in 1..<len { value = (value << 8) | UInt64(try readByte()) }
        return (value, len)
    }

    static func leadingLength(of byte: UInt8, max: Int) -> Int {
        var len = 1
        var mask: UInt8 = 0x80
        while len < max && (byte & mask) == 0 { len += 1; mask >>= 1 }
        return len
    }

    func readUInt(size: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<size { value = (value << 8) | UInt64(try readByte()) }
        return value
    }

    func readFloat(size: Int) throws -> Double {
        if size == 4 {
            let bits = UInt32(try readUInt(size: 4))
            return Double(Float32(bitPattern: bits))
        }
        let bits = try readUInt(size: 8)
        return Double(bitPattern: bits)
    }

    func readString(size: Int) throws -> String {
        let data = try readBytes(size)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func skip(_ size: UInt64) { seek(to: position + size) }
}

enum EBMLReaderError: Error { case endOfFile }

// MARK: - Matroska 元素 ID

enum MatroskaID {
    static let segment: UInt32 = 0x18538067
    static let info: UInt32 = 0x1549A966
    static let timecodeScale: UInt32 = 0x2AD7B1
    static let tracks: UInt32 = 0x1654AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let defaultDuration: UInt32 = 0x23E383
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let channels: UInt32 = 0x9F
    static let blockAdditionMapping: UInt32 = 0x75A1
    static let blockAddIDType: UInt32 = 0xFE
    static let blockAddIDExtraData: UInt32 = 0xED
    static let trackName: UInt32 = 0x536E
    static let trackLanguage: UInt32 = 0x22B59C
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let cluster: UInt32 = 0x1C53BB6B
    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFA
}

// MARK: - 轨道与帧信息

struct MKVTrack {
    var number: UInt64 = 0
    var type: UInt64 = 0            // 1 视频 2 音频 17 字幕
    var codecID: String = ""
    var codecPrivate: Data?
    var defaultDurationNs: UInt64?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var sampleRate: Double = 0
    var channels: Int = 0
    var dolbyVisionConfig: Data?    // BlockAdditionMapping 里的 dvvc 记录（若有）
    var name: String = ""           // 轨道名（如「简体中文」）
    var language: String = ""       // 语言代码（如 chi / zho / eng，可能为空）
    var flagDefault: Bool = true
    var flagForced: Bool = false

    /// 可转成 mov_text 的文本字幕编码
    var isTextSubtitle: Bool {
        ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA", "S_TEXT/WEBVTT"]
            .contains(codecID.uppercased())
    }

    /// 图形字幕（PGS / VobSub），无法转文本
    var isImageSubtitle: Bool {
        let c = codecID.uppercased()
        return c.contains("PGS") || c.contains("VOBSUB")
    }
}

struct MKVFrame {
    var trackNumber: UInt64
    var fileOffset: UInt64          // 帧数据在源文件中的偏移
    var length: Int                 // 帧长度
    var timecodeUnits: Int64        // 绝对时间码（单位 = timecodeScale 纳秒）
    var isKeyframe: Bool
    var blockDurationUnits: UInt64? // BlockDuration（若有）
}

// MARK: - 解析器

/// 两段式：parseHeader 解析轨道信息；iterateFrames 流式遍历所有帧（只报偏移/长度/时间戳）。
final class MatroskaDemuxer {
    let reader: EBMLReader
    private(set) var tracks: [MKVTrack] = []
    private(set) var timecodeScaleNs: UInt64 = 1_000_000
    private(set) var firstClusterOffset: UInt64?

    init(url: URL) throws {
        reader = try EBMLReader(url: url)
    }

    func close() { reader.close() }

    /// 遍历一个主元素的子元素。handler 参数：(元素ID, 元素起始偏移, 数据起始偏移, 元素结束偏移)，返回 false 表示提前结束。
    private func eachChild(end: UInt64, _ handler: (UInt32, UInt64, UInt64, UInt64) throws -> Bool) throws {
        while reader.position < end {
            let elemStart = reader.position
            let id = try reader.readID()
            let (size, _, unknown) = try reader.readSize()
            let dataStart = reader.position
            let elemEnd = unknown ? end : min(end, dataStart + size)
            let goOn = try handler(id, elemStart, dataStart, elemEnd)
            if !goOn { return }
            if reader.position != elemEnd { reader.seek(to: elemEnd) }
            if unknown { return }
        }
    }

    func parseHeader() throws {
        // 第一个元素应为 EBML 头，直接跳过
        let firstID = try reader.readID()
        guard firstID == 0x1A45DFA3 else { throw RemuxError.notMatroska }
        let (headSize, _, _) = try reader.readSize()
        reader.skip(headSize)

        // 找 Segment
        while reader.position < reader.fileSize {
            let id = try reader.readID()
            let (size, _, unknown) = try reader.readSize()
            let dataStart = reader.position
            let segEnd = unknown ? reader.fileSize : dataStart + size
            if id == MatroskaID.segment {
                try parseSegment(end: segEnd)
                return
            }
            if unknown { throw RemuxError.notMatroska }
            reader.seek(to: dataStart + size)
        }
        throw RemuxError.notMatroska
    }

    private func parseSegment(end: UInt64) throws {
        var foundTracks = false
        try eachChild(end: end) { id, elemStart, _, elemEnd in
            switch id {
            case MatroskaID.info:
                try self.parseInfo(end: elemEnd)
            case MatroskaID.tracks:
                try self.parseTracks(end: elemEnd)
                foundTracks = true
            case MatroskaID.cluster:
                self.firstClusterOffset = elemStart
                return false // 轨道信息齐了就停，帧遍历从第一个 Cluster 起
            default:
                break
            }
            return true
        }
        if !foundTracks { throw RemuxError.noTracks }
        if firstClusterOffset == nil { throw RemuxError.noCluster }
    }

    private func parseInfo(end: UInt64) throws {
        try eachChild(end: end) { id, _, dataStart, elemEnd in
            if id == MatroskaID.timecodeScale {
                self.timecodeScaleNs = try self.reader.readUInt(size: Int(elemEnd - dataStart))
            }
            return true
        }
    }

    private func parseTracks(end: UInt64) throws {
        try eachChild(end: end) { id, _, _, elemEnd in
            if id == MatroskaID.trackEntry {
                if let track = try self.parseTrackEntry(end: elemEnd) {
                    self.tracks.append(track)
                }
            }
            return true
        }
    }

    private func parseTrackEntry(end: UInt64) throws -> MKVTrack? {
        var track = MKVTrack()
        try eachChild(end: end) { id, _, dataStart, elemEnd in
            let size = Int(elemEnd - dataStart)
            switch id {
            case MatroskaID.trackNumber:
                track.number = try self.reader.readUInt(size: size)
            case MatroskaID.trackType:
                track.type = try self.reader.readUInt(size: size)
            case MatroskaID.codecID:
                track.codecID = try self.reader.readString(size: size)
            case MatroskaID.codecPrivate:
                track.codecPrivate = try self.reader.readBytes(size)
            case MatroskaID.defaultDuration:
                track.defaultDurationNs = try self.reader.readUInt(size: size)
            case MatroskaID.trackName:
                track.name = try self.reader.readString(size: size)
            case MatroskaID.trackLanguage:
                track.language = try self.reader.readString(size: size)
            case MatroskaID.flagDefault:
                track.flagDefault = try self.reader.readUInt(size: size) != 0
            case MatroskaID.flagForced:
                track.flagForced = try self.reader.readUInt(size: size) != 0
            case MatroskaID.video:
                try self.eachChild(end: elemEnd) { cid, _, cs, ce in
                    switch cid {
                    case MatroskaID.pixelWidth:
                        track.pixelWidth = Int(try self.reader.readUInt(size: Int(ce - cs)))
                    case MatroskaID.pixelHeight:
                        track.pixelHeight = Int(try self.reader.readUInt(size: Int(ce - cs)))
                    default: break
                    }
                    return true
                }
            case MatroskaID.audio:
                try self.eachChild(end: elemEnd) { cid, _, cs, ce in
                    switch cid {
                    case MatroskaID.samplingFrequency:
                        track.sampleRate = try self.reader.readFloat(size: Int(ce - cs))
                    case MatroskaID.channels:
                        track.channels = Int(try self.reader.readUInt(size: Int(ce - cs)))
                    default: break
                    }
                    return true
                }
            case MatroskaID.blockAdditionMapping:
                var addType: UInt64 = 0
                var extra: Data?
                try self.eachChild(end: elemEnd) { cid, _, cs, ce in
                    switch cid {
                    case MatroskaID.blockAddIDType:
                        addType = try self.reader.readUInt(size: Int(ce - cs))
                    case MatroskaID.blockAddIDExtraData:
                        extra = try self.reader.readBytes(Int(ce - cs))
                    default: break
                    }
                    return true
                }
                // 0x64767663 = 'dvvc'
                if addType == 0x6476_7663, let extra { track.dolbyVisionConfig = extra }
            default:
                break
            }
            return true
        }
        return track.number > 0 ? track : nil
    }

    // MARK: - 帧遍历

    /// 从第一个 Cluster 起遍历全文件，逐帧回调。body 返回 false 可提前终止。
    func iterateFrames(_ body: (MKVFrame) throws -> Bool) throws {
        guard let start = firstClusterOffset else { throw RemuxError.noCluster }
        reader.seek(to: start)
        var clusterTimecode: Int64 = 0

        while reader.position < reader.fileSize {
            let elemStart = reader.position
            let id: UInt32
            let size: UInt64
            let unknown: Bool
            do {
                id = try reader.readID()
                let s = try reader.readSize()
                size = s.value; unknown = s.unknown
            } catch { break } // 读到残缺尾部就结束
            let dataStart = reader.position
            let elemEnd = unknown ? reader.fileSize : min(reader.fileSize, dataStart + size)

            if id == MatroskaID.cluster {
                clusterTimecode = 0
                var goOn = true
                try eachChild(end: elemEnd) { cid, _, cs, ce in
                    switch cid {
                    case MatroskaID.clusterTimestamp:
                        clusterTimecode = Int64(try self.reader.readUInt(size: Int(ce - cs)))
                    case MatroskaID.simpleBlock:
                        goOn = try self.emitBlock(dataStart: cs, size: Int(ce - cs),
                                                  clusterTimecode: clusterTimecode,
                                                  keyframeFlagKnown: true, body)
                    case MatroskaID.blockGroup:
                        goOn = try self.emitBlockGroup(end: ce, clusterTimecode: clusterTimecode, body)
                    default:
                        break
                    }
                    return goOn
                }
                if !goOn { return }
            }
            if reader.position != elemEnd { reader.seek(to: elemEnd) }
            _ = elemStart
        }
    }

    private func emitBlockGroup(end: UInt64, clusterTimecode: Int64,
                                _ body: (MKVFrame) throws -> Bool) throws -> Bool {
        var frames: [MKVFrame] = []
        var duration: UInt64?
        var hasReference = false
        try eachChild(end: end) { id, _, cs, ce in
            switch id {
            case MatroskaID.block:
                _ = try self.collectBlock(dataStart: cs, size: Int(ce - cs),
                                          clusterTimecode: clusterTimecode, into: &frames)
            case MatroskaID.blockDuration:
                duration = try self.reader.readUInt(size: Int(ce - cs))
            case MatroskaID.referenceBlock:
                hasReference = true
                _ = try self.reader.readBytes(Int(ce - cs))
            default:
                break
            }
            return true
        }
        if !frames.isEmpty {
            frames[0].isKeyframe = !hasReference
        }
        for i in frames.indices {
            if let duration { frames[i].blockDurationUnits = duration }
            if try !body(frames[i]) { return false }
        }
        return true
    }

    /// 解析 SimpleBlock 并逐帧回调
    private func emitBlock(dataStart: UInt64, size: Int, clusterTimecode: Int64,
                           keyframeFlagKnown: Bool,
                           _ body: (MKVFrame) throws -> Bool) throws -> Bool {
        var frames: [MKVFrame] = []
        _ = try collectBlock(dataStart: dataStart, size: size,
                             clusterTimecode: clusterTimecode, into: &frames)
        for frame in frames {
            if try !body(frame) { return false }
        }
        return true
    }

    /// 解析 Block 数据头（轨道号、时间码、标志、花边），算出每帧的偏移与长度
    private func collectBlock(dataStart: UInt64, size: Int, clusterTimecode: Int64,
                              into frames: inout [MKVFrame]) throws -> Bool {
        reader.seek(to: dataStart)
        let blockEnd = dataStart + UInt64(size)
        let (trackNumber, _) = try reader.readVInt()
        let tcRaw = try reader.readBytes(2)
        let relative = Int64(Int16(bitPattern: UInt16(tcRaw[0]) << 8 | UInt16(tcRaw[1])))
        let flags = try reader.readByte()
        let isKeyframe = (flags & 0x80) != 0
        let laceType = (flags >> 1) & 0x3
        let hasLace = (flags & 0x01) != 0

        var frameSizes: [Int] = []
        if !hasLace {
            frameSizes = [Int(blockEnd - reader.position)]
        } else {
            let laceCount = Int(try reader.readByte()) // 实际帧数 - 1
            if laceType == 0 {
                // Xiph 花边
                var sizes: [Int] = []
                for _ in 0..<laceCount {
                    var s = 0
                    while true {
                        let b = try reader.readByte()
                        s += Int(b)
                        if b < 255 { break }
                    }
                    sizes.append(s)
                }
                let used = sizes.reduce(0, +)
                sizes.append(Int(blockEnd - reader.position) - used)
                frameSizes = sizes
            } else if laceType == 1 {
                // 固定大小花边
                let remaining = Int(blockEnd - reader.position)
                let each = remaining / (laceCount + 1)
                frameSizes = Array(repeating: each, count: laceCount + 1)
            } else {
                // EBML 花边（有符号差分）
                var sizes: [Int] = []
                let (first, _) = try reader.readVInt()
                sizes.append(Int(first))
                var previous = Int(first)
                for _ in 1..<laceCount {
                    let (raw, len) = try reader.readVInt()
                    let bias = (1 << (7 * len - 1)) - 1
                    let delta = Int(raw) - bias
                    let current = previous + delta
                    sizes.append(current)
                    previous = current
                }
                let used = sizes.reduce(0, +)
                sizes.append(Int(blockEnd - reader.position) - used)
                frameSizes = sizes
            }
        }

        var offset = reader.position
        for (index, frameSize) in frameSizes.enumerated() {
            frames.append(MKVFrame(trackNumber: trackNumber,
                                   fileOffset: offset,
                                   length: frameSize,
                                   timecodeUnits: clusterTimecode + relative,
                                   isKeyframe: isKeyframe && index == 0,
                                   blockDurationUnits: nil))
            offset += UInt64(frameSize)
        }
        reader.seek(to: blockEnd)
        return true
    }
}
