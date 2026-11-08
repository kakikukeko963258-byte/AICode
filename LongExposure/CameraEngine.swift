import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit

enum ExposureStyle: String, CaseIterable, Identifiable {
    case stars = "星空", smooth = "スロー", trails = "光跡", sensor = "センサー"
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
    private var starActive = false
    private var starStopRequested = false
    private var starCaptureID: Int64?
    private var starData: (Data, Bool)?
    private var starRawFormat: OSType?
    private var starStart = Date()
    private var starStack: StarStacker?
    private var starEV = 2.5
    private var starExposure = 0.0
    private var starISO: Float = 0
    private var starFolder: URL?
    private var starFailures = 0
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
    @Published var rejectedFrames = 0
    @Published var starStatus = ""

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

    func capture(seconds: Double, style: ExposureStyle, iso: Float?, starEV: Double = 2.5, focus: Float = 1) {
        queue.async {
            guard !self.active, !self.pendingSensor, !self.starActive, let camera = self.device, self.session.isRunning else { return }
            if style == .stars {
                self.beginStars(seconds: seconds, iso: iso ?? 1600, ev: starEV, focus: focus)
                return
            }
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

    func stopEarly() {
        queue.async {
            if self.active { self.finishStack() }
            if self.starActive {
                self.starStopRequested = true
                if self.starCaptureID == nil { self.finishStars() }
            }
        }
    }

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
            if self.starCaptureID == photo.resolvedSettings.uniqueID {
                if error == nil, let data = photo.fileDataRepresentation() { self.starData = (data, photo.isRawPhoto) }
                return
            }
            guard self.pendingSensor else { return }
            self.pendingSensor = false
            self.deadline?.cancel()
            self.restoreAuto()
            if let error { self.report(error.localizedDescription); return }
            guard let data = photo.fileDataRepresentation(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { self.report("写真を取得できませんでした。"); return }
            self.deliver(image)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            guard self.starActive, self.starCaptureID == resolvedSettings.uniqueID else { return }
            self.starCaptureID = nil
            let captured = self.starData
            self.starData = nil
            autoreleasepool {
                do {
                    if let error { throw error }
                    guard let (data, raw) = captured else { throw self.cameraError("星空写真を取得できませんでした。") }
                    guard let folder = self.starFolder, let stack = self.starStack else { throw self.cameraError("保存先がありません。") }
                    // Keep the reference original; avoid unbounded DNG disk usage.
                    let sequence = stack.accepted + stack.rejected + 1
                    if sequence == 1 { try data.write(to: folder.appendingPathComponent(raw ? "reference.dng" : "reference.jpg"), options: .atomic) }
                    let image: CIImage
                    if raw {
                        guard let decoder = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else { throw self.cameraError("RAWを現像できません。") }
                        decoder.baselineExposure = 0
                        decoder.boostAmount = 0
                        decoder.exposure = 0
                        decoder.luminanceNoiseReductionAmount = 0
                        decoder.sharpnessAmount = 0
                        decoder.scaleFactor = Float(min(1, 4096 / max(decoder.nativeSize.width, decoder.nativeSize.height)))
                        guard let decoded = decoder.outputImage else { throw self.cameraError("RAWの現像に失敗しました。") }
                        image = decoded
                    } else {
                        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw self.cameraError("写真を読み込めません。") }
                        let scale = min(1, 4096 / max(decoded.extent.width, decoded.extent.height))
                        image = decoded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    }
                    _ = try stack.add(image)
                    self.starFailures = 0
                    let elapsed = Date().timeIntervalSince(self.starStart)
                    let thumbnail = stack.developed(ev: self.starEV).flatMap { self.makeImage($0, scale: 0.18) }
                    let accepted = stack.accepted, rejected = stack.rejected
                    DispatchQueue.main.async {
                        self.elapsed = min(elapsed, self.targetSeconds); self.frames = accepted; self.rejectedFrames = rejected; self.preview = thumbnail
                    }
                    if rejected >= 5 && accepted < 2 {
                        self.starStopRequested = true
                        DispatchQueue.main.async { self.message = "星の位置を合わせられませんでした。三脚で固定してピントを確認してください。" }
                    }
                } catch {
                    self.starFailures += 1
                    if self.starRawFormat != nil {
                        self.starRawFormat = nil
                        DispatchQueue.main.async { self.starStatus = "写真合成（RAW非対応）" }
                    } else if self.starFailures >= 2 {
                        self.starStopRequested = true
                        DispatchQueue.main.async { self.message = error.localizedDescription }
                    }
                }
            }
            if self.starStopRequested || Date().timeIntervalSince(self.starStart) >= self.targetSeconds { self.finishStars() }
            else { self.captureStarFrame() }
        }
    }

    func prepare(style: ExposureStyle) {
        queue.async {
            guard self.configured, !self.active, !self.pendingSensor, !self.starActive else { return }
            self.setPhotoMode(style == .stars)
        }
    }

    private func setPhotoMode(_ enabled: Bool) {
        guard let camera = device else { return }
        session.beginConfiguration()
        let preset: AVCaptureSession.Preset = enabled ? .photo : .hd1920x1080
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        if let preferred = dimensions.last(where: { Int64($0.width) * Int64($0.height) <= 16_000_000 }) ?? dimensions.first { photo.maxPhotoDimensions = preferred }
        photo.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
        let maximum = CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
        let minimum = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)
        DispatchQueue.main.async { self.sensorMax = maximum; self.sensorMin = max(0.00001, minimum) }
    }

    private func beginStars(seconds: Double, iso: Float, ev: Double, focus: Float) {
        guard let camera = device else { return }
        do {
            setPhotoMode(true)
            starActive = true; starStopRequested = false; starData = nil; starFailures = 0
            targetSeconds = seconds; starEV = ev
            starStack = StarStacker(context: context)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            starFolder = documents.appendingPathComponent("Stars-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: starFolder!, withIntermediateDirectories: true)
            starRawFormat = photo.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            try camera.lockForConfiguration()
            guard camera.isExposureModeSupported(.custom) else { camera.unlockForConfiguration(); throw cameraError("手動露光に対応していません。") }
            starExposure = min(2, CMTimeGetSeconds(camera.activeFormat.maxExposureDuration))
            starISO = min(max(iso, camera.activeFormat.minISO), camera.activeFormat.maxISO)
            if camera.isLockingFocusWithCustomLensPositionSupported { camera.setFocusModeLocked(lensPosition: min(max(focus, 0), 1), completionHandler: nil) }
            if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
            starStart = Date()
            let label = "\(starRawFormat == nil ? "写真" : "RAW") · \(String(format: "%.2f", starExposure))秒 · ISO \(Int(starISO))"
            DispatchQueue.main.async {
                self.shooting = true; self.processing = false; self.elapsed = 0; self.frames = 0; self.rejectedFrames = 0; self.preview = nil; self.message = nil; self.starStatus = label
                UIApplication.shared.isIdleTimerDisabled = true
            }
            camera.setExposureModeCustom(duration: CMTime(seconds: starExposure, preferredTimescale: 1_000_000_000), iso: starISO) { _ in
                self.queue.async { if self.starActive { self.starStart = Date(); self.captureStarFrame() } }
            }
            camera.unlockForConfiguration()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.starActive else { return }
                self.starCaptureID = nil; self.finishStars()
            }
            deadline = timeout
            queue.asyncAfter(deadline: .now() + seconds + 45, execute: timeout)
        } catch { starActive = false; starStack = nil; restoreAuto(); report(error.localizedDescription) }
    }

    private func captureStarFrame() {
        guard starActive else { return }
        let settings = starRawFormat.map { AVCapturePhotoSettings(rawPixelFormatType: $0) } ?? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = .off
        settings.maxPhotoDimensions = photo.maxPhotoDimensions
        settings.photoQualityPrioritization = starRawFormat == nil ? .quality : .speed
        starCaptureID = settings.uniqueID
        photo.capturePhoto(with: settings, delegate: self)
    }

    private func finishStars() {
        guard starActive else { return }
        starActive = false; starCaptureID = nil; deadline?.cancel()
        defer { starStack = nil; restoreAuto() }
        guard let stack = starStack, stack.accepted >= 2, let image = stack.developed(ev: starEV) else { report("位置合わせできる写真が2枚未満でした。三脚とピントを確認してください。撮影原本はファイルに残しています。"); return }
        if let folder = starFolder {
            let metadata: [String: Any] = ["accepted": stack.accepted, "rejected": stack.rejected, "exposureSeconds": starExposure, "iso": starISO, "brightenEV": starEV, "captureSeconds": Date().timeIntervalSince(starStart), "source": "real-camera-frames"]
            do {
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("capture.json"))
                if let linear = stack.linearImage, let tiff = context.tiffRepresentation(of: linear, format: .RGBAh, colorSpace: linearSpace, options: [:]) { try tiff.write(to: folder.appendingPathComponent("stack-linear.tiff"), options: .atomic) }
            } catch { DispatchQueue.main.async { self.message = "原本の追加保存に失敗：\(error.localizedDescription)" } }
        }
        deliver(image)
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
            if self.starActive { self.starCaptureID = nil; self.finishStars() }
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
