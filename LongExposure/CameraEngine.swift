import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit

enum ExposureStyle: String, CaseIterable, Identifiable {
    case smooth = "スロー", trails = "光跡", sensor = "センサー"
    var id: String { rawValue }
}

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let photo = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var accumulated: CIImage?
    private var count = 0
    private var startTime: Double?
    private var targetSeconds = 10.0
    private var style: ExposureStyle = .smooth
    private var active = false
    private var pendingSensor = false
    private var lastPreview = 0.0
    private var deadline: DispatchWorkItem?
    private var configured = false
    @Published var ready = false
    @Published var shooting = false
    @Published var processing = false
    @Published var elapsed = 0.0
    @Published var frames = 0
    @Published var preview: UIImage?
    @Published var result: UIImage?
    @Published var resultURL: URL?
    @Published var message: String?
    @Published var sensorMax = 1.0
    @Published var sensorMin = 0.001
    @Published var permissionDenied = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            guard allowed else {
                DispatchQueue.main.async { self.permissionDenied = true; self.message = "設定でカメラの使用を許可してください。" }
                return
            }
            self.queue.async {
                do {
                    if !self.configured { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.ready = true }
                } catch { self.report(error.localizedDescription) }
            }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw cameraError("カメラが見つかりません。") }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw cameraError("カメラを開始できません。") }
        session.addInput(input)
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(video), session.canAddOutput(photo) else { throw cameraError("撮影出力を作成できません。") }
        session.addOutput(video)
        session.addOutput(photo)
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if let connection = photo.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        device = camera
        configured = true
        let maximum = CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
        let minimum = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)
        DispatchQueue.main.async {
            self.sensorMax = maximum
            self.sensorMin = max(0.00001, minimum)
        }
    }

    func capture(seconds: Double, style: ExposureStyle, iso: Float?) {
        queue.async {
            guard !self.active, !self.pendingSensor, let camera = self.device, self.session.isRunning else { return }
            do {
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
                if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
                let minDuration = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)
                let maxDuration = CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
                let duration = style == .sensor ? min(max(seconds, minDuration), maxDuration) : CMTimeGetSeconds(camera.exposureDuration)
                let sensitivity = min(max(iso ?? camera.iso, camera.activeFormat.minISO), camera.activeFormat.maxISO)
                guard camera.isExposureModeSupported(.custom) else {
                    camera.unlockForConfiguration()
                    throw self.cameraError("このカメラは手動露光に対応していません。")
                }
                self.style = style
                self.targetSeconds = seconds
                self.count = 0
                self.startTime = nil
                self.accumulated = nil
                self.lastPreview = 0
                self.pendingSensor = style == .sensor
                self.active = style != .sensor
                DispatchQueue.main.async {
                    self.shooting = true; self.processing = false; self.elapsed = 0; self.frames = 0; self.preview = nil; self.message = nil
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                camera.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: sensitivity) { _ in
                    if style == .sensor {
                        self.queue.async {
                            guard self.pendingSensor else { return }
                            self.photo.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
                        }
                    }
                }
                camera.unlockForConfiguration()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.active || self.pendingSensor else { return }
                    self.active = false; self.pendingSensor = false; self.accumulated = nil
                    self.restoreAuto()
                    self.report("撮影が中断されました。カメラを再度開いてください。")
                }
                self.deadline = timeout
                self.queue.asyncAfter(deadline: .now() + seconds + 15, execute: timeout)
            } catch { self.restoreAuto(); self.report(error.localizedDescription) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let now = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if startTime == nil { startTime = now }
            let elapsed = max(0, now - (startTime ?? now))
            let frame = CIImage(cvPixelBuffer: pixel)
            let merged: CIImage
            if let previous = accumulated {
                if style == .trails {
                    merged = frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: previous])
                } else {
                    merged = previous.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: frame, kCIInputTimeKey: 1.0 / Double(count + 1)])
                }
            } else { merged = frame }
            // Materialize every iteration: fixed memory instead of a growing CI graph.
            guard let rendered = context.createCGImage(merged, from: frame.extent, format: .RGBAh, colorSpace: linearSpace) else {
                active = false; accumulated = nil; restoreAuto(); report("写真の合成に失敗しました。"); return
            }
            accumulated = CIImage(cgImage: rendered)
            count += 1
            if elapsed - lastPreview >= 0.25 || count == 1 {
                lastPreview = elapsed
                let thumbnail = makeImage(accumulated!, scale: 0.35)
                let total = count
                DispatchQueue.main.async { self.elapsed = min(elapsed, self.targetSeconds); self.frames = total; self.preview = thumbnail }
            }
            if elapsed >= targetSeconds { finishStack() }
        }
    }

    func stopEarly() { queue.async { if self.active { self.finishStack() } } }

    private func finishStack() {
        guard active else { return }
        active = false
        deadline?.cancel()
        defer { accumulated = nil; restoreAuto() }
        guard let image = accumulated else { report("撮影フレームがありません。"); return }
        deliver(image)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            guard self.pendingSensor else { return }
            self.pendingSensor = false
            self.deadline?.cancel()
            self.restoreAuto()
            if let error { self.report(error.localizedDescription); return }
            guard let data = photo.fileDataRepresentation(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { self.report("写真を取得できませんでした。"); return }
            self.deliver(image)
        }
    }

    private func makeImage(_ image: CIImage, scale: CGFloat = 1) -> UIImage? {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent).map { UIImage(cgImage: $0) }
    }

    private func deliver(_ image: CIImage) {
        DispatchQueue.main.async { self.shooting = false; self.processing = true; UIApplication.shared.isIdleTimerDisabled = false }
        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.97]) else { report("写真の書き出しに失敗しました。"); return }
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = documents.appendingPathComponent("Exposure-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).jpg")
            try data.write(to: url, options: .atomic)
            let uiImage = UIImage(data: data)
            DispatchQueue.main.async { self.result = uiImage; self.resultURL = url; self.preview = nil; self.processing = false }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { self.report("写真への保存は未許可です。撮影画像はアプリ内に保存しました。共有ボタンから書き出せます。"); return }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } completionHandler: { saved, error in
                    if !saved { self.report("アプリ内に保存しました。写真への保存に失敗しました：\(error?.localizedDescription ?? "不明なエラー")") }
                    else { DispatchQueue.main.async { self.message = "写真に保存しました" } }
                }
            }
        } catch { report(error.localizedDescription) }
    }

    func suspend() {
        queue.async {
            if self.active { self.finishStack() }
            if self.pendingSensor { self.pendingSensor = false; self.restoreAuto(); self.report("撮影を中断しました。") }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
    }

    private func restoreAuto() {
        deadline?.cancel()
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
        } catch { report(error.localizedDescription) }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { self.message = text; self.shooting = false; self.processing = false; UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func cameraError(_ text: String) -> NSError { NSError(domain: "LongExposure", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
