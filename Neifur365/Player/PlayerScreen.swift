import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct PlayerScreen: View {
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

    private var isOpening: Bool { vm.loadingStream || !vm.engine.isReady }
    private var isWaiting: Bool { isOpening || vm.engine.isBuffering }

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

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

                if let err = vm.errorMessage ?? vm.engine.playbackError {
                    errorOverlay(err)
                } else if isLocked {
                    if isWaiting { loadingIndicator }
                    if showControls { lockedOverlay }
                } else {
                    if isWaiting { loadingIndicator }
                    if showControls || isOpening {
                        controlsOverlay(landscape: geo.size.width > geo.size.height)
                    }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            vm.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
            vm.stop()
        }
        .onChange(of: isWaiting) { waiting in
            if !waiting { scheduleControlsHide() }
        }
        .onChange(of: vm.engine.isPaused) { paused in
            if paused {
                hideTask?.cancel()
                showControls = true
            } else {
                scheduleControlsHide()
            }
        }
        .sheet(isPresented: $showTranslationsSheet, onDismiss: scheduleControlsHide) {
            PlayerTranslationsSheet(vm: vm)
        }
        .sheet(isPresented: $showEpisodesSheet, onDismiss: scheduleControlsHide) {
            PlayerEpisodesSheet(vm: vm)
        }
        .sheet(isPresented: $showSettingsSheet, onDismiss: scheduleControlsHide) {
            PlayerSettingsSheet(vm: vm) {
                isLocked = true
                showControls = true
                scheduleControlsHide()
            }
        }
    }

    // MARK: - Gestures

    private func gestureLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                guard !isLocked, !isOpening else { return }
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
                        guard !isLocked && !isOpening && prefs.holdBoost else { return }
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

    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(isOpening ? "Открываем серию…" : "Буферизация…")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func controlsOverlay(landscape: Bool) -> some View {
        ZStack {
            VStack(spacing: 0) {
                header(landscape: landscape)
                Spacer(minLength: 0)
                if !isOpening {
                    VStack(spacing: 4) {
                        timelineBar
                        quickActions
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                            .allowsHitTesting(false)
                    }
                }
            }

            if !isWaiting {
                transportControls
            }
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private func header(landscape: Bool) -> some View {
        HStack(spacing: 10) {
            playerIconButton("xmark", label: "Закрыть") { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.request.animeTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(landscape ? 1 : 2)
                Text(episodeDetails)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)

            playerIconButton(
                landscape ? "rectangle.portrait" : "rectangle",
                label: landscape ? "Вертикальный экран" : "Горизонтальный экран"
            ) {
                requestOrientation(landscape ? .portrait : .landscape)
            }

            if !isOpening {
                playerIconButton("ellipsis", label: "Настройки плеера") {
                    showSettingsSheet = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private var episodeDetails: String {
        let quality = isOpening || vm.selectedHeight <= 0 ? nil : "\(vm.selectedHeight)p"
        let source = vm.isOfflinePlayback ? "Офлайн" : vm.currentTranslation?.author
        return [vm.currentEpisode?.label, source, quality].compactMap { $0 }.joined(separator: " · ")
    }

    private var transportControls: some View {
        HStack(spacing: 24) {
            playerIconButton("gobackward.\(prefs.seekStep)", label: "Назад на \(prefs.seekStep) секунд", size: 48) {
                vm.engine.seekRelative(-Double(prefs.seekStep))
                flashSeek("−\(prefs.seekStep) с")
                scheduleControlsHide()
            }
            playerIconButton(
                vm.engine.isPaused ? "play.fill" : "pause.fill",
                label: vm.engine.isPaused ? "Воспроизвести" : "Пауза",
                size: 62
            ) {
                vm.engine.togglePause()
            }
            playerIconButton("goforward.\(prefs.seekStep)", label: "Вперёд на \(prefs.seekStep) секунд", size: 48) {
                vm.engine.seekRelative(Double(prefs.seekStep))
                flashSeek("+\(prefs.seekStep) с")
                scheduleControlsHide()
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            Button {
                vm.skipOpening()
                flashSeek("+85 с")
                scheduleControlsHide()
            } label: {
                Text("+85 с")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .modifier(PlayerControlBackground(shape: Capsule()))
            }
            .accessibilityLabel("Пропустить 85 секунд")

            Spacer(minLength: 0)

            if !vm.translations.isEmpty {
                playerIconButton("waveform", label: "Озвучки и субтитры") {
                    showTranslationsSheet = true
                }
            }
            if vm.hasSubtitles {
                playerIconButton(
                    vm.subtitlesVisible ? "captions.bubble.fill" : "captions.bubble",
                    label: vm.subtitlesVisible ? "Скрыть субтитры" : "Показать субтитры"
                ) {
                    vm.toggleSubtitles()
                    scheduleControlsHide()
                }
            }
            if vm.request.episodes.count > 1 {
                playerIconButton("list.bullet", label: "Список серий") { showEpisodesSheet = true }
            }
            if vm.hasNext {
                playerIconButton("forward.end.fill", label: "Следующая серия") { vm.playNext() }
            }
        }
        .foregroundStyle(.white)
    }

    private var timelineBar: some View {
        let duration = max(vm.engine.duration, 1)
        let position = min(max(isScrubbing ? scrubPosition : vm.engine.position, 0), duration)

        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { position },
                    set: { value in
                        if isScrubbing {
                            scrubPosition = value
                        } else {
                            vm.engine.seek(to: value)
                        }
                    }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = position
                        isScrubbing = true
                        hideTask?.cancel()
                    } else if isScrubbing {
                        vm.engine.seek(to: scrubPosition)
                        isScrubbing = false
                        scheduleControlsHide()
                    }
                }
            )
            .tint(.white)
            .disabled(vm.engine.duration <= 0)
            .accessibilityLabel("Позиция воспроизведения")
            .accessibilityValue(Text(verbatim: formatClock(position)))

            HStack {
                Text(verbatim: formatClock(position))
                Spacer()
                Text(verbatim: vm.engine.duration > 0 ? formatClock(vm.engine.duration) : "--:--")
            }
            .foregroundStyle(.white.opacity(0.85))
            .font(.caption.monospacedDigit())
            .accessibilityHidden(true)
        }
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

    private func playerIconButton(
        _ icon: String,
        label: String,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size >= 60 ? 26 : size >= 48 ? 22 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .modifier(PlayerControlBackground(shape: Circle()))
        }
        .accessibilityLabel(Text(label))
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
            if !vm.engine.isPaused && !isScrubbing && !isWaiting &&
                !showSettingsSheet && !showEpisodesSheet && !showTranslationsSheet {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func formatClock(_ sec: Double) -> String {
        let s = sec.isFinite ? max(0, Int(sec)) : 0
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, r)
        }
        return String(format: "%02d:%02d", m, r)
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

private struct PlayerControlBackground<ControlShape: Shape>: ViewModifier {
    let shape: ControlShape

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
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
    let onLock: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Воспроизведение") {
                    if vm.availableQualities.count > 1 {
                        Picker("Качество", selection: Binding(
                            get: { vm.selectedHeight },
                            set: { height in
                                if let stream = vm.availableQualities.first(where: { $0.height == height }) {
                                    vm.selectQuality(stream)
                                }
                            }
                        )) {
                            ForEach(vm.availableQualities, id: \.height) { stream in
                                Text(verbatim: stream.height > 0 ? "\(stream.height)p" : "Авто")
                                    .tag(stream.height)
                            }
                        }
                    }
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

                    Button {
                        onLock()
                        dismiss()
                    } label: {
                        Label("Заблокировать управление", systemImage: "lock")
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
