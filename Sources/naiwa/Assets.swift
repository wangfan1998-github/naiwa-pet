import AppKit
import AVFoundation

/// 素材目录（scripts/make_assets.py 生成）：
///   assets.json  {"fps": 30, "clips": {"laugh": {"video": "laugh.mov", "frames": 122}, …},
///                 "closeup": {"focus": {"x":…, "y":…, "w":…, "h":…}, "glance": …}}
///   *.mov        带透明通道的 HEVC：focus 站姿和眨眼 / glance 转头看你 / laugh 捧腹大笑 / roll 笑到打滚
///   closeup      侧脸特写、转头特写的取景框（0–1 的比例，原点在左上）
struct Assets {
    struct Clip {
        let video: URL
        let frames: Int
    }

    let fps: Double
    let clips: [String: Clip]
    let closeups: [String: CGRect]

    static func load() -> Assets? {
        for dir in candidates() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("assets.json")),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = j["clips"] as? [String: [String: Any]] else { continue }
            var clips: [String: Clip] = [:]
            for (name, c) in list {
                guard let video = c["video"] as? String else { continue }
                clips[name] = Clip(video: dir.appendingPathComponent(video), frames: c["frames"] as? Int ?? 0)
            }
            var closeups: [String: CGRect] = [:]
            for (name, r) in j["closeup"] as? [String: [String: Double]] ?? [:] {
                closeups[name] = CGRect(x: r["x"] ?? 0, y: r["y"] ?? 0, width: r["w"] ?? 1, height: r["h"] ?? 1)
            }
            if clips["laugh"] != nil { return Assets(fps: j["fps"] as? Double ?? 30, clips: clips, closeups: closeups) }
        }
        return nil
    }

    /// NAIWA_ASSETS → Naiwa.app/Contents/Resources/assets → 从可执行文件往上找仓库里的 assets/
    private static func candidates() -> [URL] {
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NAIWA_ASSETS"] {
            out.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent("assets"))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            out.append(dir.appendingPathComponent("assets"))
            dir.deleteLastPathComponent()
        }
        return out
    }
}

/// 一段片段的播放器：系统硬件解码视频，播放时按帧取出 CGImage 交给图层。
final class ClipPlayer {
    let duration: Double
    private let url: URL
    private let item: AVPlayerItem
    private let player: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private var onEnd: (() -> Void)?
    /// 第一帧和最后一帧（站姿、转头看你那一眼），和播放走同一条解码路径，切过去颜色不会跳
    private(set) var first: CGImage?
    private(set) var last: CGImage?

    init(_ clip: Assets.Clip, fps: Double) {
        url = clip.video
        duration = Double(clip.frames) / fps
        item = AVPlayerItem(url: clip.video)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            let done = self?.onEnd
            self?.onEnd = nil
            done?()
        }
    }

    func play(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.player.play() }
    }

    func stop() {
        onEnd = nil
        player.pause()
    }

    /// 当前该显示的新帧；没有新帧返回 nil
    func nextFrame() -> CGImage? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return nil }
        return Self.image(from: pb)
    }

    func loadStills() async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var firstImage: CGImage?, lastImage: CGImage?
        while let sample = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            lastImage = Self.image(from: pb)
            if firstImage == nil { firstImage = lastImage }
        }
        first = firstImage
        last = lastImage
    }

    /// 解码出来的 BGRA 帧（预乘 alpha）→ CGImage。复制一份，像素缓冲马上还给解码器
    static func image(from pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: bpr * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
