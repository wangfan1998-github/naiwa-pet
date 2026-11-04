import AppKit
import AVFoundation

/// 素材目录（scripts/make_art.py 生成）：
///   assets.json  {"fps": 24, "credit": {"text": "画：防御老猫（B 站）", "url": "…"},
///                 "pets": ["sleep", "listen", …],
///                 "clips": {"listen": {"video": "listen.mov", "frames": 96, "loop": true, "title": "听歌", "desc": "…"}, …},
///                 "idle": [{"from": 12, "pets": ["listen", "relax"]}, …],
///                 "work": "immerse", "look": "look", "done": "glance"}
///   *.mov        带透明通道的 HEVC，画面是防御老猫画的奶蛙，逐帧抠出来的
///   pets         有哪几只（菜单里的顺序）；循环的那些空闲、干活都能用
///   idle / work  默认的安排，用户可以在 ~/.config/naiwa/config.json 里换（见 Schedule）
///   look / done  等你（播完停在最后一帧）/ 做完（惊鸿一瞥）
struct Assets {
    struct Clip {
        let video: URL
        let frames: Int
        let loop: Bool
        let title: String
        let desc: String
    }

    let fps: Double
    let clips: [String: Clip]
    let pets: [String]
    let defaults: Schedule
    let look: String, done: String
    let credit: (text: String, url: URL?)

    /// 能拿来空闲、干活的（循环的）那几只
    var loopPets: [String] { pets.filter { clips[$0]?.loop == true } }

    func title(_ name: String) -> String { clips[name]?.title ?? name }

    static func load() -> Assets? {
        for dir in candidates() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("assets.json")),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = j["clips"] as? [String: [String: Any]] else { continue }
            var clips: [String: Clip] = [:]
            for (name, c) in list {
                guard let video = c["video"] as? String else { continue }
                clips[name] = Clip(video: dir.appendingPathComponent(video), frames: c["frames"] as? Int ?? 0, loop: c["loop"] as? Bool ?? false,
                                   title: c["title"] as? String ?? name, desc: c["desc"] as? String ?? "")
            }
            let pets = (j["pets"] as? [String] ?? clips.keys.sorted()).filter { clips[$0] != nil }
            let defaults = Schedule(json: j, known: Set(clips.keys))
            let look = j["look"] as? String ?? "", done = j["done"] as? String ?? ""
            guard let defaults, clips[done] != nil else { continue }
            let c = j["credit"] as? [String: String] ?? [:]
            return Assets(fps: j["fps"] as? Double ?? 24, clips: clips, pets: pets, defaults: defaults, look: look, done: done,
                          credit: (c["text"] ?? "", c["url"].flatMap(URL.init(string:))))
        }
        return nil
    }

    /// NAIWA_ASSETS → Naiwa.app/Contents/Resources/assets → 可执行文件旁边的 ../Resources/assets → 往上找仓库里的 assets/
    private static func candidates() -> [URL] {
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NAIWA_ASSETS"] {
            out.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent("assets"))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        // 经过 ~/.local/bin/naiwa 软链跑的时候 Bundle.main 认不出 App，按可执行文件的位置找 Contents/Resources/assets
        out.append(dir.deletingLastPathComponent().appendingPathComponent("Resources/assets"))
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
    /// 第一帧和最后一帧，和播放走同一条解码路径，切过去颜色不会跳
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
