import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var camera = CameraEngine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var style: ExposureStyle = .stars
    @State private var seconds = 30.0
    @State private var sensorSeconds = 0.1
    @State private var iso = 100.0
    @State private var autoISO = true
    @State private var delay = 3
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var showPhoto = false
    @State private var starISO = 1600.0
    @State private var starEV = 2.5
    @State private var starFocus = 1.0
    private var busy: Bool { camera.shooting || camera.processing || countdown > 0 }
    private var duration: Double { style == .sensor ? min(max(sensorSeconds, camera.sensorMin), camera.sensorMax) : seconds }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("長時間露光").font(.title2.weight(.semibold))
                Spacer()
                Menu {
                    Picker("セルフタイマー", selection: $delay) {
                        Text("なし").tag(0)
                        Text("3秒").tag(3)
                        Text("10秒").tag(10)
                    }
                } label: { Label(delay == 0 ? "なし" : "\(delay)秒", systemImage: "timer") }
                .disabled(busy)
            }
            .padding(.horizontal)

            GeometryReader { geometry in
                ZStack {
                    CameraPreview(session: camera.session)
                    if camera.shooting, let preview = camera.preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).background(.black)
                    }
                    if countdown > 0 { Text("\(countdown)").font(.system(size: 92, weight: .thin, design: .rounded)).shadow(radius: 8) }
                    if camera.shooting {
                        VStack {
                            Spacer()
                            if style == .sensor {
                                Label("露光中", systemImage: "camera.aperture")
                            } else {
                                Text("\(camera.elapsed, specifier: "%.1f") / \(seconds, specifier: "%.1f") 秒")
                                ProgressView(value: min(camera.elapsed / seconds, 1))
                                Text("\(camera.frames) フレーム").font(.caption.monospacedDigit())
                                if style == .stars && camera.rejectedFrames > 0 { Text("位置ずれで除外 \(camera.rejectedFrames)枚").font(.caption2) }
                            }
                        }
                        .padding().background(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom) }
                    }
                    if !camera.ready {
                        VStack(spacing: 12) {
                            Image(systemName: "camera").font(.largeTitle)
                            if camera.permissionDenied {
                                Button("設定を開く") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            } else { Text("カメラを準備中") }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            .padding(.horizontal, 10)

            VStack(spacing: 14) {
                Picker("撮影モード", selection: $style) {
                    ForEach(ExposureStyle.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(busy)

                HStack(alignment: .firstTextBaseline) {
                    Text(style == .sensor ? "露光時間" : "撮影時間").foregroundStyle(.secondary)
                    Spacer()
                    Text(duration < 1 ? String(format: "%.3f 秒", duration) : String(format: "%.1f 秒", duration))
                        .font(.title2.monospacedDigit().weight(.medium))
                }
                if style == .sensor {
                    Slider(value: $sensorSeconds, in: camera.sensorMin...max(camera.sensorMax, camera.sensorMin + 0.00001))
                        .disabled(busy)
                    Text("センサー上限 \(camera.sensorMax, specifier: "%.3f") 秒").font(.caption).foregroundStyle(.secondary)
                } else {
                    Slider(value: Binding(get: { log2(max(style == .stars ? 10 : 0.5, seconds)) }, set: { seconds = pow(2, $0) }), in: log2(style == .stars ? 10.0 : 0.5)...log2(600))
                        .disabled(busy)
                    HStack {
                        ForEach(style == .stars ? [10.0, 30, 60, 120, 300, 600] : [1.0, 5, 15, 30, 60, 300], id: \.self) { value in
                            Button(value < 60 ? "\(Int(value))秒" : "\(Int(value / 60))分") { seconds = value }
                                .font(.caption).buttonStyle(.bordered).tint(seconds == value ? .yellow : .gray)
                        }
                    }.disabled(busy)
                }

                if style == .stars {
                    DisclosureGroup("星空の設定") {
                        VStack(spacing: 8) {
                            HStack { Text("ISO"); Spacer(); Text("\(Int(starISO))").monospacedDigit() }
                            Slider(value: $starISO, in: 100...6400, step: 100)
                            HStack { Text("明るさ"); Spacer(); Text("+\(starEV, specifier: "%.1f") EV").monospacedDigit() }
                            Slider(value: $starEV, in: 0...6, step: 0.25)
                            HStack { Text("遠景ピント"); Spacer(); Text("\(starFocus, specifier: "%.2f")").monospacedDigit() }
                            Slider(value: $starFocus, in: 0.75...1, step: 0.005)
                        }.font(.caption)
                    }.font(.subheadline).disabled(busy)
                    if !camera.starStatus.isEmpty { Text(camera.starStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }

                if style == .sensor {
                    HStack {
                        Toggle("ISO 自動選択", isOn: $autoISO)
                        if !autoISO { Text("\(Int(iso))").monospacedDigit() }
                    }.font(.subheadline).disabled(busy)
                    if !autoISO { Slider(value: $iso, in: 25...1600, step: 25).disabled(busy) }
                }

                HStack {
                    Button { showPhoto = true } label: {
                        if let result = camera.result {
                            Image(uiImage: result).resizable().scaledToFill().frame(width: 52, height: 62).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else { Image(systemName: "photo").frame(width: 52, height: 62).foregroundStyle(.secondary) }
                    }.disabled(camera.result == nil || busy).frame(maxWidth: .infinity)

                    Button(action: shutter) {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 3).frame(width: 78, height: 78)
                            if camera.shooting || countdown > 0 {
                                RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 30, height: 30)
                            } else if camera.processing { ProgressView() }
                            else { Circle().fill(.white).frame(width: 66, height: 66) }
                        }
                    }
                    .accessibilityLabel(camera.shooting ? "撮影終了" : "撮影")
                    .disabled(!camera.ready || camera.processing || (camera.shooting && style == .sensor))
                    .frame(maxWidth: .infinity)

                    if let url = camera.resultURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.title2).frame(width: 52, height: 62) }
                            .disabled(busy).frame(maxWidth: .infinity)
                    } else { Color.clear.frame(width: 52, height: 62).frame(maxWidth: .infinity) }
                }
            }.padding(.horizontal)

            Text(camera.message ?? (style == .stars ? "三脚で固定し、空に向けて撮影" : style == .smooth ? "三脚で固定して、水や雲をなめらかに" : style == .trails ? "三脚で固定して、光の軌跡を残す" : "1枚の写真をセンサーで露光"))
                .font(.caption).foregroundStyle(camera.message == nil ? .secondary : .primary)
                .multilineTextAlignment(.center).padding(.horizontal).frame(minHeight: 28)
        }
        .padding(.vertical, 10).background(.black).tint(.yellow)
        .onAppear { camera.start() }
        .onChange(of: camera.ready) { _, ready in if ready { camera.prepare(style: style) } }
        .onChange(of: style) { _, newStyle in
            if newStyle == .stars { seconds = max(10, seconds) }
            camera.prepare(style: newStyle)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else { countdownTask?.cancel(); countdown = 0; camera.suspend() }
        }
        .onChange(of: camera.sensorMax) { _, maximum in sensorSeconds = min(sensorSeconds, maximum) }
        .sheet(isPresented: $showPhoto) {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image = camera.result { Image(uiImage: image).resizable().scaledToFit() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("閉じる") { showPhoto = false } }
                    ToolbarItem(placement: .topBarTrailing) { if let url = camera.resultURL { ShareLink(item: url) } }
                }
            }.preferredColorScheme(.dark)
        }
    }

    private func shutter() {
        if countdown > 0 { countdownTask?.cancel(); countdown = 0; return }
        if camera.shooting { camera.stopEarly(); return }
        countdownTask = Task { @MainActor in
            for remaining in stride(from: delay, through: 1, by: -1) {
                countdown = remaining
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            countdown = 0
            guard !Task.isCancelled else { return }
            camera.capture(seconds: duration, style: style, iso: style == .stars ? Float(starISO) : style == .sensor && !autoISO ? Float(iso) : nil, starEV: starEV, focus: Float(starFocus))
        }
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewSurface, context: Context) {}
}
