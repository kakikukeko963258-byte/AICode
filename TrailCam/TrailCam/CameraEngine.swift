import AVFoundation
import CoreImage
import Photos
import UIKit

/// 撮影モード
/// - trails: 明るい部分だけを重ねる（比較明合成）。車の光跡が伸びる主役モード
/// - average: 全フレームを平均化。通常の長時間露光に近く、水流や雲が滑らかになる
enum CaptureMode: String, CaseIterable, Identifiable {
    case trails
    case average

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trails: return "光跡"
        case .average: return "長時間露光"
        }
    }
}

/// フレームをリアルタイムに蓄積して長時間露光を合成するエンジン。
///
/// iPhoneの単一シャッターには上限があるため、Spectre等と同じ
/// 「低ISO・やや長めの1フレーム露光 × 大量フレームの合成」で実現する。
/// 静止画部分は重ねても変わらず、動く光だけが軌跡として残る。
final class CameraEngine: NSObject, ObservableObject {
    @Published var previewImage: UIImage?
    @Published var finalImage: UIImage?
    @Published var isCapturing = false
    @Published var elapsed: Double = 0
    @Published var statusText = "カメラを準備中…"
    @Published var saveMessage: String?
    @Published var cameraAvailable = false
    /// 接続中カメラのISO範囲（UIのスライダー用に公開）
    @Published var isoMin: Float = 0
    @Published var isoMax: Float = 0

    private var captureDevice: AVCaptureDevice?
    private var focusManualEnabled = false
    private var isoManualEnabled = true
    private var manualISOValue: Float = 100
    private let frameDuration = CMTime(value: 1, timescale: 6) // 約0.17秒/フレーム

    // UIから設定される値（撮影開始時に videoQueue 側へ取り込む）
    var mode: CaptureMode = .trails
    var gradeStyle: GradeStyle = .cyber
    var durationSeconds: Double = 10   // 0 = 無制限（バルブ）

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "jp.trailcam.video")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var isConfigured = false

    // videoQueue 上でのみ触る蓄積状態
    private var capturingFlag = false
    private var accumulated: CIImage?
    private var frameCount = 0
    private var captureStart = Date()
    private var activeMode: CaptureMode = .trails
    private var activeGrade: GradeStyle = .cyber
    private var activeDuration: Double = 10
    private var lastPublish = Date.distantPast

    // MARK: - セットアップ

    func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.setupSession() }
                else {
                    DispatchQueue.main.async {
                        self?.statusText = "カメラの許可が必要です。設定アプリで許可してください"
                    }
                }
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.statusText = "カメラの許可が必要です。設定アプリで許可してください"
            }
        }
    }

    private func setupSession() {
        guard !isConfigured else { return }
        isConfigured = true
        videoQueue.async { [weak self] in
            guard let self else { return }
            // 注意: startRunning は beginConfiguration〜commitConfiguration の
            // 外で呼ばなければならない（中だと例外でクラッシュする）。
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.statusText = "背面カメラが見つかりません（実機で使ってください）" }
                return
            }
            self.session.addInput(input)
            self.configureDevice(device)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.videoQueue)
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(output)
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.cameraAvailable = true
                self.statusText = "三脚などで固定して、シャッターを押してください"
            }
        }
    }

    /// 初期設定: ピントは連続オート（タップAFが効く状態）、
    /// ISOは低めの手動値（夜景の光跡向け）から始める。
    private func configureDevice(_ device: AVCaptureDevice) {
        captureDevice = device
        let format = device.activeFormat
        manualISOValue = format.minISO + (format.maxISO - format.minISO) * 0.15
        DispatchQueue.main.async {
            self.isoMin = format.minISO
            self.isoMax = format.maxISO
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            applyCustomExposureLocked(device)
        } catch {
            // 設定できなくても自動露光で撮影は続行する
        }
    }

    /// ロック取得済みの状態で手動露光（固定フレーム時間＋現在の手動ISO）を適用する。
    private func applyCustomExposureLocked(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }
        let maxDuration = device.activeFormat.maxExposureDuration
        let duration = CMTimeCompare(frameDuration, maxDuration) == 1 ? maxDuration : frameDuration
        let iso = min(device.activeFormat.maxISO, max(device.activeFormat.minISO, manualISOValue))
        device.setExposureModeCustom(duration: duration, iso: iso)
    }

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        videoQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                body(device)
            } catch {
                // ロックに失敗した変更は次回に持ち越す
            }
        }
    }

    // MARK: - 手動コントロール（UIから呼ぶ）

    /// プレビューのタップ位置（0〜1に正規化、表示画像基準）でピントを合わせる。
    /// ISOがオートのときは露出もその地点に合わせる。
    func focusAtDisplayPoint(_ normalized: CGPoint) {
        // 表示はセンサー画像を90度回転したものなので座標を変換する
        let devicePoint = CGPoint(x: normalized.y, y: 1 - normalized.x)
        withDevice { [weak self] device in
            guard let self else { return }
            if !self.focusManualEnabled, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            if !self.isoManualEnabled, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func setFocusAuto() {
        focusManualEnabled = false
        withDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    /// lensPosition: 0.0 = 最至近、1.0 = 無限遠
    func setFocusManual(lensPosition: Float) {
        focusManualEnabled = true
        withDevice { device in
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: min(1, max(0, lensPosition)))
            }
        }
    }

    func setISOAuto() {
        isoManualEnabled = false
        withDevice { device in
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    func setISOManual(_ iso: Float) {
        isoManualEnabled = true
        manualISOValue = iso
        withDevice { [weak self] device in
            self?.applyCustomExposureLocked(device)
        }
    }

    // MARK: - 撮影制御

    func startCapture() {
        guard cameraAvailable, !isCapturing else { return }
        let modeSnapshot = mode
        let gradeSnapshot = gradeStyle
        let durationSnapshot = durationSeconds
        DispatchQueue.main.async {
            self.finalImage = nil
            self.saveMessage = nil
            self.elapsed = 0
            self.isCapturing = true
            self.statusText = "撮影中… iPhoneを動かさないでください"
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.activeMode = modeSnapshot
            self.activeGrade = gradeSnapshot
            self.activeDuration = durationSnapshot
            self.accumulated = nil
            self.frameCount = 0
            self.captureStart = Date()
            self.capturingFlag = true
        }
    }

    func stopCapture() {
        videoQueue.async { [weak self] in self?.finishCaptureOnQueue() }
    }

    private func finishCaptureOnQueue() {
        guard capturingFlag else { return }
        capturingFlag = false
        guard let accumulated else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.statusText = "フレームを取得できませんでした"
            }
            return
        }
        let graded = ColorGrade.apply(to: accumulated, style: activeGrade)
        var result: UIImage?
        if let cg = ciContext.createCGImage(graded, from: graded.extent) {
            result = UIImage(cgImage: cg)
        }
        DispatchQueue.main.async {
            self.isCapturing = false
            self.finalImage = result
            self.statusText = result != nil ? "完成。保存するか撮り直してください" : "画像の生成に失敗しました"
        }
    }

    // MARK: - 保存

    func saveFinal() {
        guard let image = finalImage, let data = image.jpegData(compressionQuality: 0.92) else {
            DispatchQueue.main.async { self.saveMessage = "保存できる画像がまだありません" }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.saveMessage = "写真への保存が許可されていません" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self?.saveMessage = success ? "写真に保存しました" : "保存に失敗しました"
                }
            }
        }
    }

    func discardFinal() {
        DispatchQueue.main.async {
            self.finalImage = nil
            self.statusText = "三脚などで固定して、シャッターを押してください"
        }
    }

    // MARK: - フレーム合成

    private func publish(_ image: CIImage, graded: Bool) {
        let shown = graded ? ColorGrade.apply(to: image, style: activeGradeForPreview) : image
        guard let cg = ciContext.createCGImage(shown, from: shown.extent) else { return }
        let ui = UIImage(cgImage: cg)
        DispatchQueue.main.async { self.previewImage = ui }
    }

    private var activeGradeForPreview: GradeStyle {
        capturingFlag ? activeGrade : gradeStyle
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var frame = CIImage(cvPixelBuffer: buffer)

        // 蓄積サイズを最大1600pxに抑えて処理を軽くする
        let maxDimension: CGFloat = 1600
        let longest = max(frame.extent.width, frame.extent.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            frame = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let now = Date()
        if capturingFlag {
            var merged: CIImage
            if let acc = accumulated {
                switch activeMode {
                case .trails:
                    merged = frame.applyingFilter("CILightenBlendMode", parameters: [
                        kCIInputBackgroundImageKey: acc
                    ])
                case .average:
                    let weight = CGFloat(1.0 / Double(frameCount + 1))
                    let faded = frame.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight),
                        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
                    ])
                    merged = faded.applyingFilter("CISourceOverCompositing", parameters: [
                        kCIInputBackgroundImageKey: acc
                    ])
                }
            } else {
                merged = frame
            }
            // 重要: 合成結果を毎フレーム実体化（レンダリング）して平坦化する。
            // フィルタを重ねただけのCIImageを持ち回すとグラフが際限なく育ち、
            // 数秒で描画が詰まって撮影が止まり、メモリも圧迫して保存まで失敗する。
            if let cg = ciContext.createCGImage(merged, from: merged.extent) {
                accumulated = CIImage(cgImage: cg)
            } else {
                accumulated = merged
            }
            frameCount += 1

            let elapsedNow = now.timeIntervalSince(captureStart)
            if now.timeIntervalSince(lastPublish) > 0.12, let acc = accumulated {
                lastPublish = now
                publish(acc, graded: true)
                DispatchQueue.main.async { self.elapsed = elapsedNow }
            }
            if activeDuration > 0, elapsedNow >= activeDuration {
                finishCaptureOnQueue()
            }
        } else {
            if now.timeIntervalSince(lastPublish) > 0.12 {
                lastPublish = now
                publish(frame, graded: true)
            }
        }
    }
}
