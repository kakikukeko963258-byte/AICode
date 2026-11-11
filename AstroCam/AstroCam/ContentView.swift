import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var durationSelection: Double = 120
    @State private var modeSelection: CaptureMode = .stars
    @State private var frameExposureSelection: Double = 1.0
    @State private var selfTimerSelection: Int = 3
    @State private var showTips = false
    @State private var shareURL: URL?
    // ピント / ISO
    @State private var focusIsManual = true
    @State private var lensPosition: Double = 1.0
    @State private var isoIsManual = true
    @State private var isoValue: Double = 1000
    @State private var isoInitialized = false
    @State private var focusIndicator: CGPoint?
    // セルフタイマー / 暗転
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var screenDimmed = false

    private let nightRed = Color(red: 1.0, green: 0.25, blue: 0.2)

    private var isoRange: ClosedRange<Double> {
        engine.isoMax > engine.isoMin
            ? Double(engine.isoMin)...Double(engine.isoMax)
            : 50...3200
    }

    private let durations: [(value: Double, label: String)] = [
        (30, "30秒"), (60, "1分"), (120, "2分"), (300, "5分"),
        (600, "10分"), (1200, "20分"), (0, "∞")
    ]
    private let frameExposures: [(value: Double, label: String)] = [
        (0.25, "1/4秒"), (0.5, "1/2秒"), (1.0, "1秒")
    ]
    private let selfTimers: [(value: Int, label: String)] = [
        (0, "なし"), (3, "3秒"), (10, "10秒")
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = engine.previewImage {
                GeometryReader { geo in
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard !focusIsManual else { return }
                                let normalized = CGPoint(
                                    x: location.x / max(1, geo.size.width),
                                    y: location.y / max(1, geo.size.height)
                                )
                                engine.focusAtDisplayPoint(normalized)
                                withAnimation(.easeOut(duration: 0.15)) {
                                    focusIndicator = location
                                }
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    if focusIndicator == location {
                                        withAnimation { focusIndicator = nil }
                                    }
                                }
                            }
                        if let point = focusIndicator {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.yellow, lineWidth: 2)
                                .frame(width: 74, height: 74)
                                .position(point)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 54))
                        .foregroundStyle(nightRed)
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

            if let count = countdown {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    Text("\(count)")
                        .font(.system(size: 110, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)
            }

            if screenDimmed {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Text(String(format: "撮影中 %.0f秒 ・ %d枚", engine.elapsed, engine.frameCountPublished))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(nightRed.opacity(0.8))
                        Text("タップで画面を戻す")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .onTapGesture { screenDimmed = false }
            }

            if let finalImage = engine.finalImage {
                reviewOverlay(finalImage)
            }
        }
        .onAppear {
            engine.configure()
            engine.mode = modeSelection
            engine.durationSeconds = durationSelection
            engine.setFrameExposure(seconds: frameExposureSelection)
        }
        .onChange(of: modeSelection) { _, newValue in engine.mode = newValue }
        .onChange(of: durationSelection) { _, newValue in engine.durationSeconds = newValue }
        .onChange(of: frameExposureSelection) { _, newValue in engine.setFrameExposure(seconds: newValue) }
        .onChange(of: focusIsManual) { _, manual in
            if manual { engine.setFocusManual(lensPosition: Float(lensPosition)) }
            else { engine.setFocusAuto() }
        }
        .onChange(of: lensPosition) { _, newValue in
            if focusIsManual { engine.setFocusManual(lensPosition: Float(newValue)) }
        }
        .onChange(of: isoIsManual) { _, manual in
            if manual {
                engine.setISOManual(Float(isoValue))
                engine.setFrameExposure(seconds: frameExposureSelection)
            } else { engine.setISOAuto() }
        }
        .onChange(of: isoValue) { _, newValue in
            if isoIsManual { engine.setISOManual(Float(newValue)) }
        }
        .onChange(of: engine.isoMax) { _, _ in
            if !isoInitialized, engine.isoMax > engine.isoMin {
                isoInitialized = true
                isoValue = Double(engine.isoMin + (engine.isoMax - engine.isoMin) * 0.8)
            }
        }
        .onChange(of: engine.isCapturing) { _, capturing in
            if !capturing { screenDimmed = false }
        }
        .sheet(isPresented: $showTips) { tipsSheet }
    }

    // MARK: - 上部バー

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("星空カメラ")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("ASTRO CAM ・ 無音")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(nightRed)
            }
            Spacer()
            if engine.isCapturing {
                Button {
                    screenDimmed = true
                } label: {
                    Label("暗くする", systemImage: "moon.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.white)
                }
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
            Text("\(engine.frameCountPublished)枚 合成")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 10)
    }

    // MARK: - シャッター開始（セルフタイマー付き）

    private func shutterTapped() {
        if engine.isCapturing {
            engine.stopCapture()
            return
        }
        if countdown != nil {
            countdownTask?.cancel()
            countdown = nil
            return
        }
        let delay = selfTimerSelection
        guard delay > 0 else {
            engine.startCapture()
            return
        }
        countdownTask = Task {
            for remaining in stride(from: delay, through: 1, by: -1) {
                if Task.isCancelled { return }
                countdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            countdown = nil
            engine.startCapture()
        }
    }

    // MARK: - 下部コントロール

    private var bottomControls: some View {
        VStack(spacing: 12) {
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
            .disabled(engine.isCapturing || countdown != nil)

            chipRow(title: "合計", items: durations, selection: $durationSelection)
                .disabled(engine.isCapturing || countdown != nil)

            chipRow(title: "1枚", items: frameExposures, selection: $frameExposureSelection)
                .disabled(engine.isCapturing || countdown != nil)

            // セルフタイマー
            HStack(spacing: 10) {
                Text("タイマー")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .leading)
                Picker("タイマー", selection: $selfTimerSelection) {
                    ForEach(selfTimers, id: \.value) { item in
                        Text(item.label).tag(item.value)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
            }
            .disabled(engine.isCapturing)

            // ピント
            HStack(spacing: 10) {
                Text("ピント")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .leading)
                Picker("ピント", selection: $focusIsManual) {
                    Text("オート").tag(false)
                    Text("手動").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                if focusIsManual {
                    Text("近").font(.caption).foregroundStyle(.white.opacity(0.7))
                    Slider(value: $lensPosition, in: 0...1)
                        .tint(nightRed)
                    Text(lensPosition >= 0.99 ? "∞" : String(format: "%.2f", lensPosition))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 34)
                } else {
                    Text("明るい星をタップ")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            }
            .disabled(engine.isCapturing || countdown != nil)

            // ISO
            HStack(spacing: 10) {
                Text("ISO")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .leading)
                Picker("ISO", selection: $isoIsManual) {
                    Text("オート").tag(false)
                    Text("手動").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
                if isoIsManual {
                    Slider(value: $isoValue, in: isoRange)
                        .tint(nightRed)
                    Text("\(Int(isoValue))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 44)
                } else {
                    Text("明るさは自動調整")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
            }
            .disabled(engine.isCapturing || countdown != nil)

            // シャッター
            Button {
                shutterTapped()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    if engine.isCapturing, durationSelection > 0 {
                        Circle()
                            .trim(from: 0, to: min(1, engine.elapsed / durationSelection))
                            .stroke(nightRed, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 78, height: 78)
                            .rotationEffect(.degrees(-90))
                    }
                    RoundedRectangle(cornerRadius: engine.isCapturing ? 6 : 33)
                        .fill(nightRed)
                        .frame(width: engine.isCapturing ? 30 : 62, height: engine.isCapturing ? 30 : 62)
                }
            }
            .disabled(!engine.cameraAvailable && !engine.isCapturing)
            .opacity(engine.cameraAvailable || engine.isCapturing ? 1 : 0.4)

            Text(engine.isCapturing ? "タップで停止" : (countdown != nil ? "タップでキャンセル" : "無音で撮影開始"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(14)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private func chipRow(title: String, items: [(value: Double, label: String)], selection: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.value) { item in
                        Button {
                            selection.wrappedValue = item.value
                        } label: {
                            Text(item.label)
                                .font(.subheadline.weight(selection.wrappedValue == item.value ? .bold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selection.wrappedValue == item.value ? nightRed : Color.white.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
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
                        .foregroundStyle(nightRed)
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
                    .tint(nightRed)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            if let data = image.jpegData(compressionQuality: 0.92) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("astrocam-\(UUID().uuidString).jpg")
                try? data.write(to: url)
                shareURL = url
            }
        }
    }

    // MARK: - 撮り方シート

    private var tipsSheet: some View {
        NavigationStack {
            List {
                Section("おすすめ設定（最初はこれで）") {
                    Label("モード「星空」、合計2分、1枚1秒", systemImage: "sparkles")
                    Label("ピントは手動で∞（初期設定のまま）", systemImage: "scope")
                    Label("ISOは手動で高め。白飛ばすなら少し下げる", systemImage: "dial.high")
                    Label("タイマー3秒＋三脚。押した振動が収まってから始まる", systemImage: "timer")
                }
                Section("モードの違い") {
                    Text("「星空」は平均合成（スタッキング）です。枚数を重ねるほどノイズが減り、天の川のような暗いものが見えてきます。星は点のまま写りますが、合計が長すぎると自転で少し流れます（2〜5分が目安）。")
                        .font(.footnote)
                    Text("「星跡」は比較明合成です。10〜20分回すと星が弧を描くスタートレイルになります。北極星を中心に入れると同心円になります。")
                        .font(.footnote)
                }
                Section("シャッター音について") {
                    Text("このアプリは写真撮影ではなく映像フレームの合成で撮るため、シャッター音は鳴りません。日本向けiPhoneで通常の写真撮影の音が消せないのは仕様ですが、この方式では「写真を撮る」動作自体をしません。")
                        .font(.footnote)
                }
                Section("現場のコツ") {
                    Label("街明かりから離れる。月が出ていない夜ほど暗い星が写る", systemImage: "moon.stars")
                    Label("撮影中は「暗くする」で画面を暗転でき、暗順応も守れる", systemImage: "moon.fill")
                    Label("レンズの曇り・結露に注意。寒い夜は特に曇りやすい", systemImage: "cloud.fog")
                    Label("長い撮影は電池を食うので、終わったら結果を確認して保存", systemImage: "battery.75percent")
                }
            }
            .navigationTitle("星空撮影のコツ")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showTips = false }
                }
            }
        }
    }
}
