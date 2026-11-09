import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var durationSelection: Double = 10
    @State private var modeSelection: CaptureMode = .trails
    @State private var gradeSelection: GradeStyle = .cyber
    @State private var showTips = false
    @State private var shareURL: URL?

    private let durations: [(value: Double, label: String)] = [
        (3, "3秒"), (5, "5秒"), (10, "10秒"), (15, "15秒"), (30, "30秒"), (0, "∞")
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // プレビュー / 蓄積中の合成画像
            if let image = engine.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 54))
                        .foregroundStyle(.cyan)
                    Text(engine.statusText)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            VStack {
                topBar
                Spacer()
                if engine.isCapturing {
                    capturingBadge
                }
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let finalImage = engine.finalImage {
                reviewOverlay(finalImage)
            }
        }
        .onAppear {
            engine.configure()
            engine.mode = modeSelection
            engine.gradeStyle = gradeSelection
            engine.durationSeconds = durationSelection
        }
        .onChange(of: modeSelection) { _, newValue in engine.mode = newValue }
        .onChange(of: gradeSelection) { _, newValue in engine.gradeStyle = newValue }
        .onChange(of: durationSelection) { _, newValue in engine.durationSeconds = newValue }
        .sheet(isPresented: $showTips) { tipsSheet }
    }

    // MARK: - 上部バー

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("光跡カメラ")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("TRAIL CAM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.cyan)
            }
            Spacer()
            Menu {
                Picker("色味", selection: $gradeSelection) {
                    ForEach(GradeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } label: {
                Label(gradeSelection.title, systemImage: "paintpalette")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button {
                showTips = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - 撮影中バッジ

    private var capturingBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 10, height: 10)
            if durationSelection > 0 {
                Text(String(format: "%.0f / %.0f 秒", engine.elapsed, durationSelection))
                    .monospacedDigit()
            } else {
                Text(String(format: "%.0f 秒", engine.elapsed))
                    .monospacedDigit()
            }
            Text("動かさないで")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 10)
    }

    // MARK: - 下部コントロール

    private var bottomControls: some View {
        VStack(spacing: 14) {
            Text(engine.statusText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            Picker("モード", selection: $modeSelection) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.isCapturing)

            // 露光時間
            HStack(spacing: 8) {
                ForEach(durations, id: \.value) { item in
                    Button {
                        durationSelection = item.value
                    } label: {
                        Text(item.label)
                            .font(.subheadline.weight(durationSelection == item.value ? .bold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                durationSelection == item.value ? Color.cyan : Color.white.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(durationSelection == item.value ? .black : .white)
                    }
                    .disabled(engine.isCapturing)
                }
            }

            // シャッター
            Button {
                if engine.isCapturing {
                    engine.stopCapture()
                } else {
                    engine.startCapture()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    if engine.isCapturing, durationSelection > 0 {
                        Circle()
                            .trim(from: 0, to: min(1, engine.elapsed / durationSelection))
                            .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 78, height: 78)
                            .rotationEffect(.degrees(-90))
                    }
                    RoundedRectangle(cornerRadius: engine.isCapturing ? 6 : 33)
                        .fill(.red)
                        .frame(width: engine.isCapturing ? 30 : 62, height: engine.isCapturing ? 30 : 62)
                }
            }
            .disabled(!engine.cameraAvailable && !engine.isCapturing)
            .opacity(engine.cameraAvailable || engine.isCapturing ? 1 : 0.4)

            Text(engine.isCapturing ? "タップで停止" : "タップで撮影開始")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(14)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - 完成プレビュー

    private func reviewOverlay(_ image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.top, 24)
                if let message = engine.saveMessage {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                HStack(spacing: 12) {
                    Button {
                        engine.discardFinal()
                    } label: {
                        Label("撮り直す", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("共有", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    Button {
                        engine.saveFinal()
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            if let data = image.jpegData(compressionQuality: 0.92) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("trailcam-\(UUID().uuidString).jpg")
                try? data.write(to: url)
                shareURL = url
            }
        }
    }

    // MARK: - 撮り方シート

    private var tipsSheet: some View {
        NavigationStack {
            List {
                Section("サンプル写真の撮り方") {
                    Label("歩道橋や高台から、高速道路・大きな交差点を見下ろす", systemImage: "road.lanes")
                    Label("iPhoneを三脚や手すりに固定して絶対に動かさない", systemImage: "tripod")
                    Label("モードは「光跡」、時間は10〜30秒がおすすめ", systemImage: "timer")
                    Label("色味は「サイバー」で青とオレンジの夜景になる", systemImage: "paintpalette")
                    Label("車が流れ続けているタイミングで撮る。信号で止まると光跡も止まる", systemImage: "car.2")
                }
                Section("仕組み") {
                    Text("iPhoneのシャッターだけでは数秒以上の露光ができないため、このアプリは低ISOのフレームを何十枚も重ねて合成しています。止まっている景色はそのまま、動く車のライトだけが線になって伸びます。")
                        .font(.footnote)
                    Text("「長時間露光」モードは全フレームの平均化で、滝や川の流れ、人の残像を滑らかにしたいときに使います。")
                        .font(.footnote)
                }
                Section("注意") {
                    Text("手持ちだと景色ごとブレます。必ず固定してください。明るい場所では光跡が出にくいので、夜〜夕方が最適です。")
                        .font(.footnote)
                }
            }
            .navigationTitle("撮影のコツ")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showTips = false }
                }
            }
        }
    }
}
