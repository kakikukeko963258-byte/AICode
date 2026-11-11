import AVFoundation
import CoreImage
import Photos
import UIKit

/// 撮影モード
/// - stars: 平均合成（スタッキング）。何十〜何百フレームを平均して
///   ノイズを消し、天の川や暗い星を引き出す星空撮影の本命モード
/// - trails: 比較明合成。地球の自転で星が線になる星跡（スタートレイル）
enum CaptureMode: String, CaseIterable, Identifiable {
    case stars
    case trails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stars: return "星空"
        case .trails: return "星跡"
        }
    }
}

/// 無音・長時間スタッキング撮影エンジン。
///
/// シャッター音について:
/// 通常の写真撮影（AVCapturePhotoOutput）では、日本向けモデルは
/// 消音設定でもシャッター音が強制的に鳴り、アプリから消すことはできない。
/// このエンジンは AVCaptureVideoDataOutput の映像フレームを合成する方式で、
/// 「写真を撮る」動作自体をしないため、シャッター音は一切鳴らない。
///
/// 星空について:
/// iPhoneの1フレーム露光は最大でも約1秒のため、高ISO・長めの
/// 1フレーム露光を大量に重ねて（スタッキング）等価的な長時間露光を作る。
/// 平均合成ではランダムノイズがフレーム数の平方根に反比例して減る。
final class CameraEngine: NSObject, ObservableObject {
    @Published var previewImage: UIImage?
    @Published var finalImage: UIImage?
    @Published var isCapturing = false
    @Published var elapsed: Double = 0
    @Published var frameCountPublished: Int = 0
    @Published var statusText = "カメラを準備中…"
    @Published var saveMessage: String?
    @Published var cameraAvailable = false
    @Published var isoMin: Float = 0
    @Published var isoMax: Float = 0
    /// 実際に適用された1フレーム露光（秒）。機器の上限で丸められる
    @Published var appliedExposureSeconds: Double = 1.0

    private var captureDevice: AVCaptureDevice?
    private var focusManualEnabled = true
    private var isoManualEnabled = true
    private var manualISOValue: Float = 800
    private var frameExposureSeconds: Double = 1.0

    // UIから設定される値
    var mode: CaptureMode = .stars
    var durationSeconds: Double = 120   // 0 = 無制限

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "jp.astrocam.video")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var isConfigured = false

    // videoQueue 上でのみ触る蓄積状態
    private var capturingFlag = false
    private var accumulated: CIImage?
    private var frameCount = 0
    private var captureStart = Date()
    private var activeMode: CaptureMode = .stars
    private var activeDuration: Double = 120
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
                self.statusText = "三脚に固定して、シャッターを押してください（音は鳴りません）"
            }
        }
    }

    /// 初期設定: 星空向けにピントは無限遠に固定、ISOは高めの手動値から始める。
    private func configureDevice(_ device: AVCaptureDevice) {
        captureDevice = device
        let format = device.activeFormat
        manualISOValue = format.minISO + (format.maxISO - format.minISO) * 0.8
        DispatchQueue.main.async {
            self.isoMin = format.minISO
            self.isoMax = format.maxISO
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: 1.0)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
            applyCustomExposureLocked(device)
        } catch {
            // 設定できなくても自動露光で撮影は続行する
        }
    }

    /// ロック取得済みの状態で手動露光（フレーム露光時間＋手動ISO）を適用する。
    private func applyCustomExposureLocked(_ device: AVCaptureDevice) {
        guard device.isExposureModeSupported(.custom) else { return }
        let format = device.activeFormat
        let maxDuration = format.maxExposureDuration
        let minDuration = format.minExposureDuration
        var duration = CMTimeMakeWithSeconds(frameExposureSeconds, preferredTimescale: 1_000_000)
        if CMTimeCompare(duration, maxDuration) == 1 { duration = maxDuration }
        if CMTimeCompare(duration, minDuration) == -1 { duration = minDuration }
        let iso = min(format.maxISO, max(format.minISO, manualISOValue))
        device.setExposureModeCustom(duration: duration, iso: iso)
        let applied = CMTimeGetSeconds(duration)
        DispatchQueue.main.async { self.appliedExposureSeconds = applied }
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

    func focusAtDisplayPoint(_ normalized: CGPoint) {
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

    /// lensPosition: 0.0 = 最至近、1.0 = 無限遠（星は1.0）
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

    /// 1フレームあたりの露光時間（秒）。機器の上限で丸められる。
    func setFrameExposure(seconds: Double) {
        frameExposureSeconds = seconds
        if isoManualEnabled {
            withDevice { [weak self] device in
                self?.applyCustomExposureLocked(device)
            }
        }
    }

    // MARK: - 撮影制御

    func startCapture() {
        guard cameraAvailable, !isCapturing else { return }
        let modeSnapshot = mode
        let durationSnapshot = durationSeconds
        DispatchQueue.main.async {
            self.finalImage = nil
            self.saveMessage = nil
            self.elapsed = 0
            self.frameCountPublished = 0
            self.isCapturing = true
            self.statusText = "撮影中… iPhoneを動かさないでください"
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.activeMode = modeSnapshot
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

    /// 仕上げ: 軽いコントラスト・彩度強調で星を引き立てる。
    private func enhance(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.15,
            kCIInputContrastKey: 1.12,
            kCIInputBrightnessKey: 0.0
        ])
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
        let graded = enhance(accumulated)
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
            self.statusText = "三脚に固定して、シャッターを押してください（音は鳴りません）"
        }
    }

    // MARK: - プレビュー公開

    private func publish(_ image: CIImage, enhanced: Bool) {
        let shown = enhanced ? enhance(image) : image
        guard let cg = ciContext.createCGImage(shown, from: shown.extent) else { return }
        let ui = UIImage(cgImage: cg)
        DispatchQueue.main.async { self.previewImage = ui }
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
                case .stars:
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
            // 重要: 合成結果を毎フレーム実体化して平坦化する。
            // フィルタを重ねただけのCIImageを持ち回すとグラフが際限なく育ち、
            // 数秒で描画が詰まって撮影が止まり、メモリも圧迫して保存まで失敗する。
            if let cg = ciContext.createCGImage(merged, from: merged.extent) {
                accumulated = CIImage(cgImage: cg)
            } else {
                accumulated = merged
            }
            frameCount += 1

            let elapsedNow = now.timeIntervalSince(captureStart)
            if now.timeIntervalSince(lastPublish) > 0.25, let acc = accumulated {
                lastPublish = now
                publish(acc, enhanced: true)
                let count = frameCount
                DispatchQueue.main.async {
                    self.elapsed = elapsedNow
                    self.frameCountPublished = count
                }
            }
            if activeDuration > 0, elapsedNow >= activeDuration {
                finishCaptureOnQueue()
            }
        } else {
            if now.timeIntervalSince(lastPublish) > 0.25 {
                lastPublish = now
                publish(frame, enhanced: false)
            }
        }
    }
}
