import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm: PlayerViewModel

    @State private var showControls = true
    @State private var isLocked = false
    @State private var hideTask: Task<Void, Never>?

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    @State private var isBoosting = false
    @State private var seekFlashText: String?
    @State private var gestureOverlay: GestureOverlay?
    @State private var gestureStartValue: Float = 0

    @State private var showTranslationsSheet = false
    @State private var showEpisodesSheet = false
    @State private var showSettingsSheet = false

    private enum GestureOverlay: Equatable {
        case brightness(Float)
        case volume(Float)
    }

    init(request: PlayerLaunchRequest, app: AppContainer) {
        _vm = StateObject(wrappedValue: PlayerViewModel(request: request, app: app))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                MpvVideoView(engine: vm.engine)
                    .ignoresSafeArea()

                // Hidden MPVolumeView to control hardware volume smoothly via right-side swipe
                VolumeSliderBridge()
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)

                gestureLayer(size: geo.size)

                if isBoosting {
                    boostPill
                }

                if let flash = seekFlashText {
                    seekFlashPill(flash)
                }

                if let overlay = gestureOverlay {
                    sideGestureHUD(overlay)
                }

                if let notice = vm.markedWatchedNotice {
                    VStack {
                        Spacer()
                        Text(notice)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Nf.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Nf.mint, in: Capsule())
                            .padding(.bottom, showControls ? 116 : 28)
                    }
                    .transition(.opacity)
                }

                if vm.loadingStream || vm.engine.isBuffering {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
                        .padding(18)
                        .background(.ultraThinMaterial, in: Circle())
                }

                if let err = vm.errorMessage ?? vm.engine.playbackError {
                    errorOverlay(err)
                } else if showControls {
                    if isLocked {
                        lockedOverlay
                    } else {
                        controlsOverlay
                    }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            requestOrientation(.landscape)
            vm.start()
            scheduleControlsHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            vm.stop()
            requestOrientation(.portrait)
        }
        .sheet(isPresented: $showTranslationsSheet) {
            PlayerTranslationsSheet(vm: vm)
        }
        .sheet(isPresented: $showEpisodesSheet) {
            PlayerEpisodesSheet(vm: vm)
        }
        .sheet(isPresented: $showSettingsSheet) {
            PlayerSettingsSheet(vm: vm)
        }
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                guard !isLocked else { return }
                let step = Double(prefs.seekStep)
                if location.x < size.width * 0.45 {
                    vm.engine.seekRelative(-step)
                    flashSeek("−\(Int(step)) с")
                } else if location.x > size.width * 0.55 {
                    vm.engine.seekRelative(step)
                    flashSeek("+\(Int(step)) с")
                } else {
                    vm.engine.togglePause()
                }
            }
            .onTapGesture(count: 1) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls { scheduleControlsHide() }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard !isLocked && prefs.holdBoost else { return }
                        isBoosting = true
                        vm.engine.setSpeed(2.0)
                    }
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { _ in
                        if isBoosting {
                            isBoosting = false
                            vm.engine.setSpeed(vm.speed)
                        }
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard !isLocked && prefs.sideGestures && !isBoosting else { return }
                        let dx = abs(value.translation.width)
                        let dy = abs(value.translation.height)
                        guard dy > dx * 1.25 else { return }

                        let isLeft = value.startLocation.x < size.width * 0.5
                        if gestureOverlay == nil {
                            gestureStartValue = isLeft
                                ? Float(UIScreen.main.brightness)
                                : VolumeController.currentVolume()
                        }

                        let delta = Float(-value.translation.height / max(size.height * 0.65, 180))
                        let next = min(max(gestureStartValue + delta, 0), 1)
                        if isLeft {
                            UIScreen.main.brightness = CGFloat(next)
                            gestureOverlay = .brightness(next)
                        } else {
                            VolumeController.setVolume(next)
                            gestureOverlay = .volume(next)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            gestureOverlay = nil
                        }
                    }
            )
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.request.animeTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let ep = vm.currentEpisode {
                            Text(ep.label)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        if let tr = vm.currentTranslation {
                            Text("· \(tr.author)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        } else if vm.isOfflinePlayback {
                            Text("· Офлайн")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Nf.mint)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if vm.sleepTimer != .off {
                        playerIconButton("moon.fill", tint: Nf.amber) {
                            showSettingsSheet = true
                        }
                    }

                    playerIconButton(vm.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        vm.toggleAspectFill()
                        scheduleControlsHide()
                    }

                    playerIconButton("lock.open") {
                        withAnimation { isLocked = true }
                        scheduleControlsHide()
                    }

                    playerIconButton("gearshape") {
                        showSettingsSheet = true
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .background(
                LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            )

            Spacer()

            // Center playback buttons
            HStack(spacing: 42) {
                Button {
                    vm.engine.seekRelative(-Double(prefs.seekStep))
                    flashSeek("−\(prefs.seekStep) с")
                    scheduleControlsHide()
                } label: {
                    Image(systemName: "gobackward.\(prefs.seekStep)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                }

                Button {
                    vm.engine.togglePause()
                    scheduleControlsHide()
                } label: {
                    Image(systemName: vm.engine.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 68, height: 68)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Button {
                    vm.engine.seekRelative(Double(prefs.seekStep))
                    flashSeek("+\(prefs.seekStep) с")
                    scheduleControlsHide()
                } label: {
                    Image(systemName: "goforward.\(prefs.seekStep)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                }
            }

            Spacer()

            // Bottom timeline + quick action pills
            VStack(spacing: 12) {
                timelineBar

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            vm.skipOpening()
                            flashSeek("+85 с")
                            scheduleControlsHide()
                        } label: {
                            Label("+85 с", systemImage: "forward.end.fill")
                                .font(.caption.weight(.bold))
                                .foregroundColor(Nf.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Nf.mint, in: Capsule())
                        }

                        if !vm.isOfflinePlayback {
                            playerChip(
                                title: vm.currentTranslation?.author ?? "Озвучка",
                                icon: "waveform"
                            ) {
                                showTranslationsSheet = true
                            }
                        }

                        if !vm.availableQualities.isEmpty {
                            Menu {
                                ForEach(vm.availableQualities, id: \.height) { stream in
                                    Button {
                                        vm.selectQuality(stream)
                                    } label: {
                                        if stream.height == vm.selectedHeight {
                                            Label("\(stream.height)p", systemImage: "checkmark")
                                        } else {
                                            Text("\(stream.height)p")
                                        }
                                    }
                                }
                            } label: {
                                playerChipLabel(title: "\(vm.selectedHeight)p", icon: "sparkles.tv")
                            }
                        }

                        if vm.hasSubtitles {
                            playerChip(
                                title: vm.subtitlesVisible ? "Субтитры" : "Без субт.",
                                icon: vm.subtitlesVisible ? "captions.bubble.fill" : "captions.bubble",
                                active: vm.subtitlesVisible
                            ) {
                                vm.toggleSubtitles()
                                scheduleControlsHide()
                            }
                        }

                        Menu {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                                Button {
                                    vm.setSpeed(rate)
                                } label: {
                                    let label = rate == 1.0 ? "1× (обычная)" : String(format: "%.2g×", rate)
                                    if abs(vm.speed - rate) < 0.01 {
                                        Label(label, systemImage: "checkmark")
                                    } else {
                                        Text(label)
                                    }
                                }
                            }
                        } label: {
                            playerChipLabel(
                                title: String(format: "%.2g×", vm.speed),
                                icon: "speedometer",
                                active: abs(vm.speed - 1.0) > 0.01
                            )
                        }

                        if vm.request.episodes.count > 1 {
                            playerChip(title: "Серии", icon: "list.bullet") {
                                showEpisodesSheet = true
                            }
                        }

                        if vm.hasNext {
                            playerChip(title: "Следующая", icon: "forward.fill") {
                                vm.playNext()
                                scheduleControlsHide()
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .transition(.opacity)
    }

    private var timelineBar: some View {
        let total = max(vm.engine.duration, 1)
        let displayedPos = isScrubbing ? scrubPosition : vm.engine.position

        return VStack(spacing: 6) {
            HStack {
                Text(formatClock(displayedPos))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Spacer()
                Text(vm.engine.duration > 0 ? formatClock(vm.engine.duration) : "--:--")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.72))
                    .monospacedDigit()
            }

            GeometryReader { barGeo in
                let width = max(barGeo.size.width, 1)
                let progressFrac = min(max(displayedPos / total, 0), 1)
                let cacheFrac = min(max(vm.engine.cacheTime / total, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(height: isScrubbing ? 7 : 4.5)

                    Capsule()
                        .fill(Color.white.opacity(0.42))
                        .frame(width: width * cacheFrac, height: isScrubbing ? 7 : 4.5)

                    Capsule()
                        .fill(Nf.violet)
                        .frame(width: width * progressFrac, height: isScrubbing ? 7 : 4.5)

                    Circle()
                        .fill(.white)
                        .frame(width: isScrubbing ? 18 : 13, height: isScrubbing ? 18 : 13)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: max(0, min(width - 14, width * progressFrac - 7)))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let frac = min(max(val.location.x / width, 0), 1)
                            scrubPosition = Double(frac) * total
                            hideTask?.cancel()
                        }
                        .onEnded { val in
                            let frac = min(max(val.location.x / width, 0), 1)
                            let target = Double(frac) * total
                            vm.engine.seek(to: target)
                            isScrubbing = false
                            scheduleControlsHide()
                        }
                )
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 18)
    }

    private var lockedOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation { isLocked = false }
                    scheduleControlsHide()
                } label: {
                    Label("Разблокировать", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(18)
            }
            Spacer()
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(Nf.amber)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Повторить") {
                    vm.loadCurrentEpisode(resumeFromSaved: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var boostPill: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                Text("2× ускорение")
            }
            .font(.caption.weight(.bold))
            .foregroundColor(Nf.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Nf.mint, in: Capsule())
            .padding(.top, 22)
            Spacer()
        }
    }

    private func seekFlashPill(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.scale.combined(with: .opacity))
    }

    private func sideGestureHUD(_ overlay: GestureOverlay) -> some View {
        let icon: String
        let value: Float
        switch overlay {
        case .brightness(let v):
            icon = "sun.max.fill"
            value = v
        case .volume(let v):
            icon = v < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            value = v
        }
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.white)
                .frame(width: 22)
            ProgressView(value: Double(value))
                .tint(Nf.violet)
                .frame(width: 110)
            Text("\(Int(round(value * 100)))%")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func playerIconButton(_ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func playerChip(title: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            playerChipLabel(title: title, icon: icon, active: active)
        }
    }

    private func playerChipLabel(title: String, icon: String, active: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(active ? Nf.ink : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if active {
                Capsule().fill(Nf.violet)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
    }

    private func flashSeek(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { seekFlashText = text }
        Task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            if seekFlashText == text {
                withAnimation(.easeIn(duration: 0.2)) { seekFlashText = nil }
            }
        }
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if !vm.engine.isPaused && !isScrubbing {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func formatClock(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, r)
        }
        return String(format: "%02d:%02d", m, r)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

// MARK: - System Volume Bridge

private enum VolumeController {
    static weak var slider: UISlider?

    static func currentVolume() -> Float {
        slider?.value ?? AVAudioSession.sharedInstance().outputVolume
    }

    static func setVolume(_ value: Float) {
        slider?.value = value
    }
}

private struct VolumeSliderBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        for sub in view.subviews {
            if let slider = sub as? UISlider {
                VolumeController.slider = slider
            }
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Player Sheets

private struct PlayerTranslationsSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.groupedTranslations, id: \.0) { kind, list in
                    Section(kind.title) {
                        ForEach(list) { tr in
                            let selected = vm.currentTranslation?.pickKey == tr.pickKey
                            let isFav = prefs.isFavouriteStudio(tr.pickKey)
                            HStack(spacing: 12) {
                                Button {
                                    vm.selectTranslation(tr)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(tr.author)
                                                .font(.subheadline.weight(selected ? .bold : .medium))
                                                .foregroundColor(selected ? Nf.violet : Nf.text)
                                            let meta = [tr.qualityLabel, tr.details].filter { !$0.isEmpty }.joined(separator: " · ")
                                            if !meta.isEmpty {
                                                Text(meta)
                                                    .font(.caption)
                                                    .foregroundColor(Nf.textMute)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if selected {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(Nf.violet)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    prefs.toggleFavouriteStudio(key: tr.pickKey, name: tr.author)
                                } label: {
                                    Image(systemName: isFav ? "star.fill" : "star")
                                        .foregroundColor(isFav ? Nf.amber : Nf.textMute)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Озвучка и субтитры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct PlayerEpisodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(vm.request.episodes.enumerated()), id: \.element.id) { idx, ep in
                    let active = idx == vm.currentIndex
                    Button {
                        vm.selectEpisode(at: idx)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.label)
                                    .font(.subheadline.weight(active ? .bold : .medium))
                                    .foregroundColor(active ? Nf.violet : Nf.text)
                                if let title = ep.episodeTitle, !title.isEmpty {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundColor(Nf.textMute)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if active {
                                Image(systemName: "play.fill")
                                    .foregroundColor(Nf.violet)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Серии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct PlayerSettingsSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                if !vm.availableQualities.isEmpty {
                    Section("Качество видео") {
                        ForEach(vm.availableQualities, id: \.height) { stream in
                            Button {
                                vm.selectQuality(stream)
                            } label: {
                                HStack {
                                    Text("\(stream.height)p")
                                        .foregroundColor(Nf.text)
                                    Spacer()
                                    if stream.height == vm.selectedHeight {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Nf.violet)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Воспроизведение") {
                    Picker("Скорость", selection: Binding(
                        get: { vm.speed },
                        set: { vm.setSpeed($0) }
                    )) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                            Text(String(format: "%.2g×", rate)).tag(rate)
                        }
                    }

                    Toggle("Заполнять экран", isOn: Binding(
                        get: { vm.aspectFill },
                        set: { _ in vm.toggleAspectFill() }
                    ))

                    Picker("Таймер сна", selection: Binding(
                        get: { vm.sleepTimer },
                        set: { vm.setSleepTimer($0) }
                    )) {
                        ForEach(SleepTimerOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                }

                if vm.hasSubtitles {
                    Section("Субтитры") {
                        Toggle("Показывать субтитры", isOn: Binding(
                            get: { vm.subtitlesVisible },
                            set: { _ in vm.toggleSubtitles() }
                        ))

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Размер субтитров")
                                Spacer()
                                Text("\(Int(round(prefs.subScale * 100)))%")
                                    .foregroundColor(Nf.textDim)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { prefs.subScale },
                                    set: { vm.setSubtitleScale($0) }
                                ),
                                in: 0.7...1.5,
                                step: 0.05
                            )
                        }
                    }
                }
            }
            .navigationTitle("Настройки плеера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
