import AVFoundation
import CoreImage
import Foundation

/// データモッシュ生成エンジン
///
/// 本物のデータモッシュは「動画Bのキーフレームを落とす」ことで、
/// Bの動きベクトルだけがAの絵に適用され、Aが溶けてBへ崩れる。
/// iPhoneのHEVC/H.264素材ではコーデック単位の改変が安定しないため、
/// ここでは同じ崩れを映像処理で再現する:
///
/// - つなぎ目の間、出力は「1フレーム前までの合成結果」を保持する
/// - Bのフレーム間差分（＝動いた部分）だけを、ブロック状のマスクとして
///   抜き出し、その部分だけをBの絵に置き換える
/// - 静止した部分はAの絵のまま残り、動いた部分からBが滲み出る
/// - 時間とともにリーク量を増やし、最後はBのクリーンな映像に着地する
///
/// 音声は映像とは別に、Aの音声の後ろへBの音声をそのまま繋いで残す。
final class MoshEngine {
    struct Settings {
        var moshSeconds: Double = 1.5
        var intensity: Double = 0.7   // 0...1
        var blockSize: Double = 16    // マスクのブロック（ピクセル）
        // トリミング: 開始位置（秒）と使う長さ（秒）。長さ0以下は最後まで
        var aStart: Double = 0
        var aLength: Double = 0
        var bStart: Double = 0
        var bLength: Double = 0
    }

    /// 元の長さから、実際に使う区間（開始・長さ）を求める
    static func usedRange(duration: Double, start: Double, length: Double) -> (start: Double, length: Double) {
        let safeDuration = max(0.1, duration)
        let s = min(max(0, start), max(0, safeDuration - 0.1))
        let l = length > 0 ? min(length, safeDuration - s) : safeDuration - s
        return (s, max(0.1, l))
    }

    enum MoshError: LocalizedError {
        case noVideoTrack(String)
        case readerFailed(String)
        case writerFailed(String)
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack(let name): return "\(name)に映像トラックがありませんでした。"
            case .readerFailed(let name): return "\(name)を読み込めませんでした。iCloud上の動画は本体にダウンロードしてから試してください。"
            case .writerFailed: return "書き出しの準備に失敗しました。"
            case .exportFailed: return "音声を繋ぐ処理に失敗しました。"
            case .cancelled: return "キャンセルしました。"
            }
        }
    }

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var cancelled = false
    private let cancelLock = NSLock()

    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    // MARK: - メイン処理（ブロッキング。バックグラウンドで呼ぶこと）

    /// - Returns: 完成したMP4のURL（音声があれば音声付き）
    func render(videoA urlA: URL, videoB urlB: URL, settings: Settings,
                progress: @escaping (Double) -> Void) throws -> URL {
        cancelLock.lock()
        cancelled = false
        cancelLock.unlock()

        let assetA = AVURLAsset(url: urlA)
        let assetB = AVURLAsset(url: urlB)
        guard let trackA = assetA.tracks(withMediaType: .video).first else {
            throw MoshError.noVideoTrack("動画A")
        }
        guard let trackB = assetB.tracks(withMediaType: .video).first else {
            throw MoshError.noVideoTrack("動画B")
        }

        // 出力サイズは動画Aの表示サイズに合わせ、長辺1280pxに制限する
        let displayA = Self.displaySize(of: trackA)
        let canvas = Self.canvasSize(from: displayA, maxSide: 1280)
        let canvasRect = CGRect(origin: .zero, size: canvas)
        // トリミング後の区間で全体の長さを計算する
        let rangeA = Self.usedRange(duration: assetA.duration.seconds,
                                    start: settings.aStart, length: settings.aLength)
        let rangeB = Self.usedRange(duration: assetB.duration.seconds,
                                    start: settings.bStart, length: settings.bLength)
        let totalSeconds = max(0.1, rangeA.length + rangeB.length)

        let silentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosh-silent-\(UUID().uuidString).mp4")
        let aEndTime = try renderVideo(assetA: assetA, trackA: trackA,
                                       assetB: assetB, trackB: trackB,
                                       rangeA: rangeA, rangeB: rangeB,
                                       canvas: canvas, canvasRect: canvasRect,
                                       settings: settings, totalSeconds: totalSeconds,
                                       outputURL: silentURL, progress: progress)
        if isCancelled { throw MoshError.cancelled }
        progress(0.97)

        // 音声: Aの後ろにBを繋ぐ。どちらにも無ければ無音のまま完成。
        let hasAudio = !assetA.tracks(withMediaType: .audio).isEmpty
            || !assetB.tracks(withMediaType: .audio).isEmpty
        guard hasAudio else {
            progress(1.0)
            return silentURL
        }
        do {
            let muxed = try muxAudio(videoURL: silentURL, assetA: assetA, assetB: assetB,
                                     rangeA: rangeA, rangeB: rangeB, aEndTime: aEndTime)
            try? FileManager.default.removeItem(at: silentURL)
            progress(1.0)
            return muxed
        } catch {
            // 音声付けに失敗しても映像は完成品として返す
            progress(1.0)
            return silentURL
        }
    }

    // MARK: - 映像レンダリング

    /// 映像だけを書き出し、Aの終了時刻（出力タイムライン上）を返す
    private func renderVideo(assetA: AVURLAsset, trackA: AVAssetTrack,
                             assetB: AVURLAsset, trackB: AVAssetTrack,
                             rangeA: (start: Double, length: Double),
                             rangeB: (start: Double, length: Double),
                             canvas: CGSize, canvasRect: CGRect,
                             settings: Settings, totalSeconds: Double,
                             outputURL: URL,
                             progress: @escaping (Double) -> Void) throws -> CMTime {
        let (readerA, outputA) = try makeReader(asset: assetA, track: trackA, name: "動画A", range: rangeA)
        let (readerB, outputB) = try makeReader(asset: assetB, track: trackB, name: "動画B", range: rangeB)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitRate = Int(canvas.width * canvas.height * 6)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height)
            ])
        guard writer.canAdd(input) else { throw MoshError.writerFailed("入力") }
        writer.add(input)
        guard writer.startWriting() else {
            throw MoshError.writerFailed(writer.error?.localizedDescription ?? "開始失敗")
        }
        writer.startSession(atSourceTime: .zero)

        func append(_ image: CIImage, at time: CMTime) -> Bool {
            while !input.isReadyForMoreMediaData {
                if isCancelled || writer.status != .writing { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var optionalBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
            guard let buffer = optionalBuffer else { return false }
            ciContext.render(image, to: buffer)
            return adaptor.append(buffer, withPresentationTime: time)
        }

        // ---- フェーズA: そのまま書き出す（最後のフレームを保持） ----
        var firstAPts: CMTime?
        var lastAImage: CIImage?
        var lastARaw: CVPixelBuffer?   // lastAImageの裏付けバッファを保持する
        var lastAOutPts = CMTime.zero
        var lastADuration = CMTime(value: 1, timescale: 30)
        readerA.startReading()
        while let sample = outputA.copyNextSampleBuffer() {
            if isCancelled { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstAPts == nil { firstAPts = pts }
            let outPts = CMTimeSubtract(pts, firstAPts ?? .zero)
            let image = normalize(pixelBuffer, track: trackA, canvas: canvas, canvasRect: canvasRect)
            if !append(image, at: outPts) { break }
            lastAImage = image
            lastARaw = pixelBuffer
            lastAOutPts = outPts
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isValid && duration > .zero { lastADuration = duration }
            progress(min(0.95, outPts.seconds / totalSeconds))
        }
        guard readerA.status != .failed, let moshStartImage = lastAImage else {
            writer.cancelWriting()
            throw isCancelled ? MoshError.cancelled : MoshError.readerFailed("動画A")
        }
        _ = lastARaw
        let aEndTime = CMTimeAdd(lastAOutPts, lastADuration)

        // ---- フェーズB: つなぎ目はモッシュ、それ以降はクリーン ----
        var moshBuffer: CIImage = moshStartImage
        var rasterizedBuffer: CVPixelBuffer?  // moshBufferの裏付けを保持する
        var prevBImage: CIImage?
        var prevBRaw: CVPixelBuffer?
        var firstBPts: CMTime?
        readerB.startReading()
        while let sample = outputB.copyNextSampleBuffer() {
            if isCancelled { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if firstBPts == nil { firstBPts = pts }
            let relPts = CMTimeSubtract(pts, firstBPts ?? .zero)
            let outPts = CMTimeAdd(aEndTime, relPts)
            let current = normalize(pixelBuffer, track: trackB, canvas: canvas, canvasRect: canvasRect)

            let output: CIImage
            if relPts.seconds < settings.moshSeconds {
                let moshed = moshFrame(current: current, previousB: prevBImage,
                                       moshBuffer: moshBuffer,
                                       progressInMosh: relPts.seconds / max(0.01, settings.moshSeconds),
                                       settings: settings, canvasRect: canvasRect)
                // フィルタグラフが伸び続けないよう毎フレーム実体化する
                if let flat = rasterize(moshed, canvas: canvas) {
                    moshBuffer = flat.image
                    rasterizedBuffer = flat.buffer
                } else {
                    moshBuffer = moshed
                }
                output = moshed
            } else {
                output = current
            }
            if !append(output, at: outPts) { break }
            prevBImage = current
            prevBRaw = pixelBuffer
            progress(min(0.95, (aEndTime.seconds + relPts.seconds) / totalSeconds))
        }
        _ = prevBRaw
        _ = rasterizedBuffer
        if readerB.status == .failed && !isCancelled {
            writer.cancelWriting()
            throw MoshError.readerFailed("動画B")
        }
        if isCancelled {
            writer.cancelWriting()
            throw MoshError.cancelled
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw MoshError.writerFailed(writer.error?.localizedDescription ?? "書き出し失敗")
        }
        return aEndTime
    }

    // MARK: - モッシュ1フレーム

    private func moshFrame(current: CIImage, previousB: CIImage?, moshBuffer: CIImage,
                           progressInMosh: Double, settings: Settings,
                           canvasRect: CGRect) -> CIImage {
        // リーク: 時間とともに必ずBへ寄っていく最低限の置き換え量
        let leak = pow(progressInMosh, 2.0) * (0.10 + 0.45 * settings.intensity)
        var mask: CIImage

        if let previousB {
            // Bのフレーム間差分 = 動いた部分
            let diff = filter("CIDifferenceBlendMode",
                              ["inputImage": current, "inputBackgroundImage": previousB])
                ?? current
            // 差分を増幅して白黒マスク化する
            let ev = Float(1.5 + 3.0 * settings.intensity)
            let boosted = filter("CIExposureAdjust",
                                 ["inputImage": diff, "inputEV": NSNumber(value: ev)]) ?? diff
            var mono = filter("CIColorControls",
                              ["inputImage": boosted,
                               "inputSaturation": NSNumber(value: 0.0),
                               "inputContrast": NSNumber(value: 1.3 + settings.intensity),
                               "inputBrightness": NSNumber(value: -0.04)]) ?? boosted
            // コーデックのブロック感: マスクをブロック状に量子化する
            mono = filter("CIPixellate",
                          ["inputImage": mono,
                           "inputScale": NSNumber(value: settings.blockSize),
                           "inputCenter": CIVector(x: canvasRect.midX, y: canvasRect.midY)]) ?? mono
            // リーク量との最大値 = 動いてない場所も少しずつBに置き換わる
            let leakImage = CIImage(color: CIColor(red: CGFloat(leak), green: CGFloat(leak),
                                                   blue: CGFloat(leak)))
                .cropped(to: canvasRect)
            mask = filter("CIMaximumCompositing",
                          ["inputImage": mono.cropped(to: canvasRect),
                           "inputBackgroundImage": leakImage]) ?? mono
        } else {
            // Bの先頭フレーム: まだ差分が無いのでリーク分だけ滲ませる
            mask = CIImage(color: CIColor(red: CGFloat(leak), green: CGFloat(leak),
                                          blue: CGFloat(leak)))
                .cropped(to: canvasRect)
        }

        let blended = filter("CIBlendWithMask",
                             ["inputImage": current,
                              "inputBackgroundImage": moshBuffer,
                              "inputMaskImage": mask.cropped(to: canvasRect)])
        return (blended ?? current).cropped(to: canvasRect)
    }

    // MARK: - 音声ミックス（別パス）

    private func muxAudio(videoURL: URL, assetA: AVURLAsset, assetB: AVURLAsset,
                          rangeA: (start: Double, length: Double),
                          rangeB: (start: Double, length: Double),
                          aEndTime: CMTime) throws -> URL {
        let composition = AVMutableComposition()
        let rendered = AVURLAsset(url: videoURL)
        guard let renderedVideo = rendered.tracks(withMediaType: .video).first,
              let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MoshError.exportFailed("映像トラック") }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: rendered.duration),
                                      of: renderedVideo, at: .zero)
        compVideo.preferredTransform = renderedVideo.preferredTransform

        if let audioA = assetA.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: rangeA.start, preferredTimescale: 600),
                            duration: CMTime(seconds: rangeA.length, preferredTimescale: 600)),
                of: audioA, at: .zero)
            if let audioB = assetB.tracks(withMediaType: .audio).first {
                try? compAudio.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: rangeB.start, preferredTimescale: 600),
                                duration: CMTime(seconds: rangeB.length, preferredTimescale: 600)),
                    of: audioB, at: aEndTime)
            }
        }

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality)
        else { throw MoshError.exportFailed("セッション") }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mosh-\(UUID().uuidString).mp4")
        session.outputURL = outURL
        session.outputFileType = .mp4
        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        guard session.status == .completed else {
            throw MoshError.exportFailed(session.error?.localizedDescription ?? "不明")
        }
        return outURL
    }

    // MARK: - ヘルパー

    private func makeReader(asset: AVURLAsset, track: AVAssetTrack, name: String,
                            range: (start: Double, length: Double)) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 600),
                duration: CMTime(seconds: range.length, preferredTimescale: 600))
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MoshError.readerFailed(name) }
            reader.add(output)
            return (reader, output)
        } catch let error as MoshError {
            throw error
        } catch {
            throw MoshError.readerFailed(name)
        }
    }

    /// 表示向きを適用した実サイズ
    static func displaySize(of track: AVAssetTrack) -> CGSize {
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    /// 長辺を制限し、H.264用に偶数へ丸める
    static func canvasSize(from display: CGSize, maxSide: CGFloat) -> CGSize {
        var width = display.width > 0 ? display.width : 1280
        var height = display.height > 0 ? display.height : 720
        let longest = max(width, height)
        if longest > maxSide {
            let scale = maxSide / longest
            width *= scale
            height *= scale
        }
        return CGSize(width: max(16, floor(width / 2) * 2),
                      height: max(16, floor(height / 2) * 2))
    }

    /// フレームを表示向きに直し、キャンバスへアスペクトフィルで合わせる
    private func normalize(_ pixelBuffer: CVPixelBuffer, track: AVAssetTrack,
                           canvas: CGSize, canvasRect: CGRect) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        image = image.transformed(by: track.preferredTransform)
        let extent = image.extent
        if extent.minX != 0 || extent.minY != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image.cropped(to: canvasRect) }
        let scale = max(canvas.width / source.width, canvas.height / source.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaled = image.extent
        let dx = (scaled.width - canvas.width) / 2 + scaled.minX
        let dy = (scaled.height - canvas.height) / 2 + scaled.minY
        image = image.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        return image.cropped(to: canvasRect)
    }

    /// CIImageをピクセルバッファへ焼き付け、平らなCIImageとして返す
    private func rasterize(_ image: CIImage, canvas: CGSize) -> (image: CIImage, buffer: CVPixelBuffer)? {
        var optionalBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(nil, Int(canvas.width), Int(canvas.height),
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                         &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else { return nil }
        ciContext.render(image, to: buffer)
        return (CIImage(cvPixelBuffer: buffer), buffer)
    }

    private func filter(_ name: String, _ parameters: [String: Any]) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        for (key, value) in parameters { filter.setValue(value, forKey: key) }
        return filter.outputImage
    }
}
