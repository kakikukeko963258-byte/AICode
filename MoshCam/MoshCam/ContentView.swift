import AVFoundation
import AVKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 選択した動画ファイル

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie, importing: { received in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        })
    }
}

struct VideoInfo {
    var url: URL
    var duration: Double = 0
    var thumbnail: UIImage?
}

// MARK: - ViewModel

@MainActor
final class MoshViewModel: ObservableObject {
    @Published var videoA: VideoInfo?
    @Published var videoB: VideoInfo?
    @Published var moshSeconds: Double = 1.5
    @Published var intensity: Double = 0.7
    @Published var blockSize: Double = 16

    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusText = "動画を2本選んでください"
    @Published var resultURL: URL?
    @Published var player: AVPlayer?
    @Published var errorMessage: String?
    @Published var saveMessage: String?

    private let engine = MoshEngine()
    private var renderTask: Task<Void, Never>?

    var canMosh: Bool { videoA != nil && videoB != nil && !isProcessing }

    func loadPicked(_ picked: PickedVideo, into slotA: Bool) {
        let url = picked.url
        Task {
            let asset = AVURLAsset(url: url)
            var info = VideoInfo(url: url)
            info.duration = (try? await asset.load(.duration).seconds) ?? asset.duration.seconds
            if let cg = await Self.thumbnail(of: asset) {
                info.thumbnail = UIImage(cgImage: cg)
            }
            if slotA { videoA = info } else { videoB = info }
            updateIdleStatus()
        }
    }

    private static func thumbnail(of asset: AVURLAsset) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }.value
    }

    func swap() {
        (videoA, videoB) = (videoB, videoA)
        resultURL = nil
        player = nil
        updateIdleStatus()
    }

    private func updateIdleStatus() {
        guard !isProcessing else { return }
        switch (videoA != nil, videoB != nil) {
        case (true, true): statusText = "準備OK。「モッシュする」を押してください"
        case (true, false): statusText = "動画Bを選んでください"
        case (false, true): statusText = "動画Aを選んでください"
        default: statusText = "動画を2本選んでください"
        }
    }

    func startMosh() {
        guard let a = videoA, let b = videoB, !isProcessing else { return }
        isProcessing = true
        progress = 0
        errorMessage = nil
        saveMessage = nil
        resultURL = nil
        player = nil
        statusText = "モッシュ中…"
        let settings = MoshEngine.Settings(moshSeconds: moshSeconds,
                                           intensity: intensity,
                                           blockSize: blockSize)
        let engine = self.engine
        renderTask = Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try engine.render(videoA: a.url, videoB: b.url, settings: settings) { value in
                        Task { @MainActor in
                            self.progress = value
                        }
                    }
                }.value
                resultURL = url
                player = AVPlayer(url: url)
                statusText = "完成しました。プレビューで確認できます"
            } catch is CancellationError {
                statusText = "キャンセルしました"
            } catch {
                if (error as NSError).domain == NSOSStatusErrorDomain {
                    errorMessage = error.localizedDescription
                } else {
                    errorMessage = error.localizedDescription
                }
                updateIdleStatusFallback()
            }
            isProcessing = false
        }
    }

    private func updateIdleStatusFallback() {
        statusText = "失敗しました。もう一度試してください"
    }

    func cancel() {
        engine.cancel()
        renderTask?.cancel()
    }

    func saveToPhotos() {
        guard let url = resultURL else { return }
        saveMessage = nil
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saveMessage = "写真に保存しました"
            } catch {
                saveMessage = "保存に失敗しました（写真へのアクセス許可を確認してください）"
            }
        }
    }

    func discardResult() {
        resultURL = nil
        player = nil
        saveMessage = nil
        updateIdleStatus()
    }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 画面

struct ContentView: View {
    @StateObject private var vm = MoshViewModel()
    @State private var itemA: PhotosPickerItem?
    @State private var itemB: PhotosPickerItem?
    @State private var showHelp = false

    private let cyan = Color(red: 0.2, green: 0.9, blue: 1.0)
    private let magenta = Color(red: 1.0, green: 0.25, blue: 0.75)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                videoCard(title: "動画A（崩れる側）", info: vm.videoA, accent: cyan, item: $itemA)
                swapButton
                videoCard(title: "動画B（滲み出る側）", info: vm.videoB, accent: magenta, item: $itemB)
                settingsCard
                moshButton
                if let url = vm.resultURL {
                    resultCard(url: url)
                }
                Text(vm.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                Spacer(minLength: 8)
            }
            .padding(16)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.08).ignoresSafeArea())
        .onChange(of: itemA) { _, newItem in load(newItem, slotA: true) }
        .onChange(of: itemB) { _, newItem in load(newItem, slotA: false) }
        .alert("エラー", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $showHelp) { helpSheet }
    }

    private func load(_ item: PhotosPickerItem?, slotA: Bool) {
        guard let item else { return }
        Task {
            if let picked = try? await item.loadTransferable(type: PickedVideo.self) {
                vm.loadPicked(picked, into: slotA)
            } else {
                vm.errorMessage = "動画を読み込めませんでした。別の動画で試してください。"
            }
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .leading) {
                    Text("データモッシュ")
                        .font(.title.bold())
                        .foregroundStyle(cyan.opacity(0.8))
                        .offset(x: 2, y: 0)
                    Text("データモッシュ")
                        .font(.title.bold())
                        .foregroundStyle(magenta.opacity(0.8))
                        .offset(x: -2, y: 0)
                    Text("データモッシュ")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                }
                Text("MOSHCAM ・ 違う動画同士を溶かして繋ぐ")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: 動画カード

    private func videoCard(title: String, info: VideoInfo?, accent: Color,
                           item: Binding<PhotosPickerItem?>) -> some View {
        PhotosPicker(selection: item, matching: .videos) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 96, height: 64)
                    if let thumbnail = info?.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundStyle(accent)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if let info {
                        Text("長さ \(MoshViewModel.timeLabel(info.duration)) ・ タップで変更")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    } else {
                        Text("タップして写真から選ぶ")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.5), lineWidth: 1))
        }
        .disabled(vm.isProcessing)
    }

    private var swapButton: some View {
        Button { vm.swap() } label: {
            Label("AとBを入れ替える", systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
        .disabled(vm.videoA == nil && vm.videoB == nil || vm.isProcessing)
    }

    // MARK: 設定

    private var settingsCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("モッシュ")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .leading)
                Slider(value: $vm.moshSeconds, in: 0.3...4.0, step: 0.1)
                    .tint(magenta)
                Text(String(format: "%.1f秒", vm.moshSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44)
            }
            HStack(spacing: 10) {
                Text("崩れ")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .leading)
                Slider(value: $vm.intensity, in: 0...1, step: 0.05)
                    .tint(cyan)
                Text("\(Int(vm.intensity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 44)
            }
            HStack(spacing: 10) {
                Text("ブロック")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .leading)
                Picker("ブロック", selection: $vm.blockSize) {
                    Text("細かい").tag(8.0)
                    Text("普通").tag(16.0)
                    Text("粗い").tag(32.0)
                    Text("最大").tag(48.0)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .disabled(vm.isProcessing)
    }

    // MARK: 実行

    private var moshButton: some View {
        VStack(spacing: 10) {
            if vm.isProcessing {
                ProgressView(value: vm.progress) {
                    Text("モッシュ中… \(Int(vm.progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .tint(magenta)
                Button("キャンセル") { vm.cancel() }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                Button { vm.startMosh() } label: {
                    Label("モッシュする", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(vm.canMosh
                                    ? LinearGradient(colors: [cyan, magenta],
                                                     startPoint: .leading, endPoint: .trailing)
                                    : LinearGradient(colors: [.gray, .gray],
                                                     startPoint: .leading, endPoint: .trailing),
                                  in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .disabled(!vm.canMosh)
                .opacity(vm.canMosh ? 1 : 0.5)
            }
        }
    }

    // MARK: 結果

    private func resultCard(url: URL) -> some View {
        VStack(spacing: 12) {
            if let player = vm.player {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let message = vm.saveMessage {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(cyan)
            }
            HStack(spacing: 10) {
                Button { vm.discardResult() } label: {
                    Label("消す", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button { vm.saveToPhotos() } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(magenta)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: ヘルプ

    private var helpSheet: some View {
        NavigationStack {
            List {
                Section("使い方") {
                    Label("動画A（崩れる側）と動画B（滲み出る側）を選ぶ", systemImage: "film.stack")
                    Label("「モッシュ」でAの終わりにBが溶け込む動画を書き出す", systemImage: "waveform.path.ecg")
                    Label("完成したら写真に保存するか共有する", systemImage: "square.and.arrow.down")
                }
                Section("データモッシュの仕組み") {
                    Text("本物のデータモッシュは、動画Bのキーフレームを落として「Bの動きだけ」をAの絵に適用することで崩壊させます。このアプリは同じ崩れを映像処理で再現しています: つなぎ目の間、動いた部分だけがブロック状にBへ置き換わり、静止した部分はAの絵が残ります。だから「動きの大きいB」を選ぶほど派手に崩れます。")
                        .font(.footnote)
                    Text("おすすめ: Aは風景などの静かな動画、Bは人やカメラが大きく動く動画。モッシュ1.5秒・崩れ70%から試してください。")
                        .font(.footnote)
                }
                Section("仕様と制限") {
                    Text("出力は動画Aのサイズ・向きに合わせ、長辺は最大1280pxです。Bの比率が違う場合は中央で切り抜きます。")
                        .font(.footnote)
                    Text("音声はAの音声の後ろにBの音声をそのまま繋ぎます（つなぎ目でパッと切り替わります）。")
                        .font(.footnote)
                    Text("長い動画同士は処理に時間がかかります。まずは10〜20秒程度同士で試すのがおすすめです。")
                        .font(.footnote)
                }
            }
            .navigationTitle("データモッシュについて")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showHelp = false }
                }
            }
        }
    }
}
