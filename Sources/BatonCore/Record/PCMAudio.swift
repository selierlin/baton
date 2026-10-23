import AVFoundation
import CoreMedia
import Foundation

/// 混音用的统一格式：48kHz / 立体声 / Float32 交错。
///
/// 两路声音来源（SCK 系统声、麦克风）格式不一定一样，进混音器前都先摊平成这个样子，
/// 后续只做「按下标相加」，不再关心通道布局。
public enum CanonicalAudio {
    public static let sampleRate: Double = 48_000
    public static let channels = 2
    public static let bytesPerFrame = channels * MemoryLayout<Float>.size

    /// 一段 PCM。`samples` 是交错排列的 [L,R,L,R,…]，长度 = `frames * channels`。
    public struct Segment: Sendable {
        public var frames: Int
        public var samples: [Float]

        public init(frames: Int, samples: [Float]) {
            self.frames = frames
            self.samples = samples
        }

        public static let empty = Segment(frames: 0, samples: [])
    }

    /// 给 writer 和混音输出用的格式描述。造不出来说明进程里音频栈有问题，直接放弃混音。
    public static let formatDescription: CMAudioFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }()

    public static func frames(ofSeconds seconds: Double) -> Int {
        Int((seconds * sampleRate).rounded())
    }

    public static func seconds(ofFrames frames: Int) -> Double {
        Double(frames) / sampleRate
    }

    /// 把任意 LPCM 样本摊平成统一格式。
    ///
    /// 只认 32 位浮点：SCK 与麦克风都给的浮点，遇到别的格式宁可**不混**（退回单路原样写入），
    /// 也不要按猜的字节布局去读 —— 读错就是一片噪声。
    public static func read(_ sampleBuffer: CMSampleBuffer) -> Segment? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return nil }

        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard sourceChannels > 0 else { return nil }
        // 交错格式只有一个 buffer，平面格式每声道一个
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferCount = planar ? sourceChannels : 1

        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: bufferCount),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard status == noErr else { return nil }

        var samples = [Float](repeating: 0, count: frames * channels)
        if planar {
            let usable = min(sourceChannels, channels)
            for channel in 0..<usable {
                guard let pointer = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    samples[frame * channels + channel] = pointer[frame]
                }
            }
        } else {
            guard let pointer = list[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    // 源声道少于立体声就补零；多于两声道只取前两路
                    samples[frame * channels + channel] = channel < sourceChannels
                        ? pointer[frame * sourceChannels + channel]
                        : 0
                }
            }
        }
        // 单声道麦克风：左右都给同一份，否则只出一边
        if sourceChannels == 1 {
            for frame in 0..<frames {
                samples[frame * channels + 1] = samples[frame * channels]
            }
        }
        return Segment(frames: frames, samples: samples)
    }

    /// 把混好的 Float 样本包成 writer 能吃的 CMSampleBuffer。
    public static func makeBuffer(_ samples: [Float], frames: Int, pts: CMTime) -> CMSampleBuffer? {
        guard frames > 0, let format = formatDescription else { return nil }
        let byteCount = frames * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: min(byteCount, raw.count))
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: block,
                                        formatDescription: format,
                                        sampleCount: frames,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 0,
                                        sampleSizeArray: nil,
                                        sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }
}

/// 系统声音 + 麦克风 → 一轨。
///
/// 只在录制的那条 audio queue 上调用，内部不加锁。
///
/// 时间轴按 SCK 的 PTS（mach host time）排布：每段声音换算成「从会话起点数第几帧」，
/// 麦克风数据先存进时间轴，等系统声音走到同一段时再相加。前瞻 `lookahead` 用来等
/// 麦克风那几十毫秒的延迟 —— 不留余量的话，系统声音块先到时麦克风还没到，人声会被切碎。
final class AudioMixer {
    /// 出块前先等这么久，给麦克风留出到达时间
    private let lookahead: Int
    /// 麦克风断流多久就认为「换设备/丢了一大段」，之后的数据另起一段，中间不补零
    private let maxGap: Int = 24_000   // 0.5 s
    /// 出块后麦克风时间轴还留这么久，避免边界处差一帧
    private let keepBack: Int = 24_000

    private var epoch: CMTime = .invalid
    private var micStart = 0
    private var mic: [Float] = []
    private var pending: [(pts: CMTime, start: Int, samples: [Float])] = []
    private var latestEnd = 0

    init(lookaheadSeconds: Double = 0.08) {
        lookahead = CanonicalAudio.frames(ofSeconds: lookaheadSeconds)
    }

    var micFrameCount: Int { mic.count / CanonicalAudio.channels }

    /// 系统声音进来：入队，并把「等够前瞻」的块混好吐出去。
    func ingestSystem(_ segment: CanonicalAudio.Segment, pts: CMTime) -> [(pts: CMTime, samples: [Float])] {
        guard segment.frames > 0 else { return [] }
        let start = frameIndex(pts)
        guard start >= 0 else { return [] }
        pending.append((pts, start, segment.samples))
        latestEnd = max(latestEnd, start + segment.frames)
        return drain(upTo: latestEnd - lookahead)
    }

    /// 麦克风进来：只存时间轴，不产出（它得等系统声音来对齐）。
    func ingestMic(_ segment: CanonicalAudio.Segment, pts: CMTime) {
        guard segment.frames > 0 else { return }
        let start = frameIndex(pts)
        guard start >= 0 else { return }
        add(start: start, samples: segment.samples)
    }

    /// 停止时把还压在前瞻里的块全部吐出来。
    func flush() -> [(pts: CMTime, samples: [Float])] {
        drain(upTo: Int.max)
    }

    var pendingFrameCount: Int { pending.count }

    // MARK: - 内部

    private func frameIndex(_ pts: CMTime) -> Int {
        if !epoch.isValid {
            epoch = pts
            return 0
        }
        let offset = CMTimeGetSeconds(CMTimeSubtract(pts, epoch))
        guard offset.isFinite else { return -1 }
        return Int((offset * CanonicalAudio.sampleRate).rounded())
    }

    private func drain(upTo limit: Int) -> [(pts: CMTime, samples: [Float])] {
        var output: [(pts: CMTime, samples: [Float])] = []
        let channels = CanonicalAudio.channels
        while let first = pending.first,
              first.start + first.samples.count / channels <= limit {
            pending.removeFirst()
            var samples = first.samples
            let offset = (first.start - micStart) * channels
            if offset < mic.count {
                // offset 是「这一块的第 0 帧在麦克风时间轴上的下标」。
                // 麦克风晚于这一块开始（offset < 0）时，前半段没有可叠加的数据。
                var mixIndex = max(0, -offset)
                var micIndex = max(0, offset)
                while mixIndex < samples.count, micIndex < mic.count {
                    let sum = samples[mixIndex] + mic[micIndex]
                    // 叠过头就削顶：宁可轻微失真，也不要爆音
                    samples[mixIndex] = min(1, max(-1, sum))
                    mixIndex += 1
                    micIndex += 1
                }
            }
            output.append((first.pts, samples))

            // 已经混过的麦克风数据不再需要，定期裁掉，否则长录会一直涨
            let end = first.start + first.samples.count / channels
            trimMic(below: end - keepBack)
        }
        return output
    }

    /// 把一段麦克风数据按帧号叠进时间轴。
    private func add(start: Int, samples: [Float]) {
        let channels = CanonicalAudio.channels
        let segFrames = samples.count / channels
        guard segFrames > 0 else { return }

        if mic.isEmpty {
            micStart = start
            mic = samples
            return
        }

        if start + segFrames <= micStart {
            return   // 整段都是已经裁掉的旧数据
        }
        if start < micStart {
            // 迟到的旧数据：去掉越界部分，从 micStart 处叠加
            let kept = Array(samples.dropFirst((micStart - start) * channels))
            let usable = min(kept.count, mic.count)
            for index in 0..<usable { mic[index] += kept[index] }
            return
        }

        let gap = start - (micStart + micFrameCount)
        if gap > 0 {
            if gap > maxGap {
                // 断流太久：不补零，另起一段
                micStart = start
                mic = samples
                return
            }
            mic.append(contentsOf: [Float](repeating: 0, count: gap * channels))
        }

        let offset = (start - micStart) * channels
        let needed = offset + samples.count
        if mic.count < needed {
            mic.append(contentsOf: [Float](repeating: 0, count: needed - mic.count))
        }
        for index in 0..<samples.count {
            mic[offset + index] += samples[index]
        }
    }

    private func trimMic(below frame: Int) {
        let channels = CanonicalAudio.channels
        let dropFrames = frame - micStart
        guard dropFrames > keepBack else { return }
        let drop = min(dropFrames, micFrameCount) * channels
        guard drop > 0 else { return }
        mic.removeFirst(drop)
        micStart += drop / channels
    }
}
