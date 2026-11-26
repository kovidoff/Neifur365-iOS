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

    @State private var isBoosting = false
    @State private var seekBurstDelta: Int = 0
    @State private var seekBurstTask: Task<Void, Never>?

    @State private var horizontalScrubTarget: Double?
    @State private var horizontalScrubDelta: Double = 0
    @State private var sideFeedback: PlayerSideFeedback?
    @State private var sideFeedbackTask: Task<Void, Never>?

    @State private var initialScreenBrightness: CGFloat?

    @State private var showTranslationsSheet = false
    @State private var showEpisodesSheet = false
    @State private var showTracksSheet = false
    @State private var showSettingsSheet = false
    @State private var showRemainingTime = false

    private var isOpening: Bool { vm.loadingStream || !vm.engine.isReady }
    private var isWaiting: Bool { isOpening || vm.engine.isBuffering }
    private var playbackError: String? { vm.errorMessage ?? vm.engine.playbackError }

    init(request: PlayerLaunchRequest, app: AppContainer) {
        _vm = StateObject(wrappedValue: PlayerViewModel(request: request, app: app))
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                MpvVideoView(engine: vm.engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // UIKit gesture surface strictly BELOW interactive HUD controls
                if playbackError == nil {
                    PlayerGestureOverlay(
                        isLocked: isLocked,
                        isOpening: isOpening,
                        sideGesturesEnabled: prefs.sideGestures,
                        holdBoostEnabled: prefs.holdBoost,
                        currentPositionProvider: { vm.engine.currentPosition },
                        durationProvider: { vm.engine.currentDuration },
                        onSingleTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                            if showControls { scheduleControlsHide() }
                        },
                        onDoubleTap: { nx in
                            let step = prefs.seekStep
                            if nx < 0.42 {
                                vm.engine.seekRelative(-Double(step))
                                triggerSeekBurst(-step)
                            } else if nx > 0.58 {
                                vm.engine.seekRelative(Double(step))
                                triggerSeekBurst(step)
                            } else {
                                vm.engine.togglePause()
                            }
                            scheduleControlsHide()
                        },
                        onHoldBoostChanged: { active in
                            isBoosting = active
                            vm.engine.setSpeed(active ? 2.0 : vm.speed)
                        },
                        onHorizontalScrubChanged: { target, delta in
                            horizontalScrubTarget = target
                            horizontalScrubDelta = delta
                            hideTask?.cancel()
                        },
                        onHorizontalScrubEnded: { target in
                            vm.engine.seek(to: target)
                            horizontalScrubTarget = nil
                            horizontalScrubDelta = 0
                            scheduleControlsHide()
                        },
                        onSideFeedbackChanged: { fb in
                            sideFeedbackTask?.cancel()
                            if let fb {
                                sideFeedback = fb
                            } else {
                                if prefs.rememberBrightness {
                                    prefs.savedBrightness = Double(UIScreen.main.brightness)
                                }
                                sideFeedbackTask = Task {
                                    try? await Task.sleep(nanoseconds: 550_000_000)
                                    if !Task.isCancelled {
                                        withAnimation(.easeOut(duration: 0.2)) { sideFeedback = nil }
                                    }
                                }
                            }
                        },
                        onPinchAspect: { fill in
                            vm.setAspectFill(fill)
                            vm.showToast(fill ? "Заполнение экрана" : "По размеру кадра")
                        }
                    )
                    .ignoresSafeArea()
                }

                // Visual-only feedback HUD
                if playbackError == nil {
                    feedbackOverlay
                        .allowsHitTesting(false)
                }

                // Controls or Error
                if let playbackError {
                    errorOverlay(playbackError)
                } else {
                    if isWaiting && horizontalScrubTarget == nil {
                        loadingIndicator
                    }

                    if isLocked {
                        if showControls { lockedOverlay }
                    } else {
                        if showControls || isOpening {
                            controlsOverlay(landscape: isLandscape)
                        }

                        if !showControls, let skip = vm.activeSkipSegment, vm.autoNextRemaining == nil {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    skipPill(skip)
                                        .padding(.trailing, 20)
                                        .padding(.bottom, 26)
                                }
                            }
                        }

                        if let rem = vm.autoNextRemaining {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    autoNextCard(remaining: rem)
                                        .padding(.trailing, 20)
                                        .padding(.bottom, showControls ? 118 : 26)
                                }
                            }
                        }
                    }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .modifier(PlayerKeyboardShortcutsModifier(
            onTogglePause: { vm.engine.togglePause() },
            onSeekLeft: {
                vm.engine.seekRelative(-Double(prefs.seekStep))
                triggerSeekBurst(-prefs.seekStep)
            },
            onSeekRight: {
                vm.engine.seekRelative(Double(prefs.seekStep))
                triggerSeekBurst(prefs.seekStep)
            },
            onToggleFill: {
                vm.toggleAspectFill()
                vm.showToast(vm.aspectFill ? "Заполнение экрана" : "По размеру кадра")
            },
            onSkip: {
                vm.skipOpening()
                triggerSeekBurst(85)
            },
            onNext: { vm.playNext() },
            onPrev: { vm.playPrevious() }
        ))
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareVolumeController.installIfNeeded()
            initialScreenBrightness = UIScreen.main.brightness
            if prefs.rememberBrightness && prefs.savedBrightness >= 0 {
                UIScreen.main.brightness = CGFloat(prefs.savedBrightness)
            }
            OrientationManager.shared.enterPlayer(preferLandscape: true)
            vm.start()
            scheduleControlsHide()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if prefs.rememberBrightness {
                prefs.savedBrightness = Double(UIScreen.main.brightness)
            } else if let prev = initialScreenBrightness {
                UIScreen.main.brightness = prev
            }
            hideTask?.cancel()
            seekBurstTask?.cancel()
            sideFeedbackTask?.cancel()
            vm.stop()
            OrientationManager.shared.exitPlayer()
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
        .sheet(isPresented: $showTranslationsSheet, onDismiss: {
            vm.setSheetPaused(false)
            scheduleControlsHide()
        }) {
            PlayerTranslationsSheet(vm: vm)
                .onAppear { vm.setSheetPaused(true) }
        }
        .sheet(isPresented: $showEpisodesSheet, onDismiss: {
            vm.setSheetPaused(false)
            scheduleControlsHide()
        }) {
            PlayerEpisodesSheet(vm: vm)
                .onAppear { vm.setSheetPaused(true) }
        }
        .sheet(isPresented: $showTracksSheet, onDismiss: {
            vm.setSheetPaused(false)
            scheduleControlsHide()
        }) {
            PlayerTracksSheet(vm: vm)
                .onAppear { vm.setSheetPaused(true) }
        }
        .sheet(isPresented: $showSettingsSheet, onDismiss: {
            vm.setSheetPaused(false)
            scheduleControlsHide()
        }) {
            PlayerSettingsSheet(vm: vm)
                .onAppear { vm.setSheetPaused(true) }
        }
    }

    // MARK: - Controls Overlay

    private func controlsOverlay(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            header(landscape: landscape)

            Spacer(minLength: 0)

            if !isWaiting {
                transportControls
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    if let skip = vm.activeSkipSegment, vm.autoNextRemaining == nil {
                        skipPill(skip)
                    }
                }

                PlayerTimelineBar(
                    clock: vm.engine.clock,
                    chapters: vm.chapters,
                    showRemaining: $showRemainingTime,
                    onScrubStart: { hideTask?.cancel() },
                    onSeek: { sec in
                        vm.engine.seek(to: sec)
                        scheduleControlsHide()
                    }
                )

                quickActions
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .padding(.top, 16)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .transition(.opacity)
    }

    private func header(landscape: Bool) -> some View {
        HStack(spacing: 10) {
            playerIconButton("xmark", label: "Закрыть") { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.request.animeTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(landscape ? 1 : 2)
                if !episodeDetails.isEmpty {
                    Text(episodeDetails)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if vm.sleepTimer != .off {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Nf.amber)
                            if vm.sleepTimer == .endOfEpisode {
                                Text("До конца")
                            } else {
                                Text(AppFormatters.formatClock(Double(vm.sleepRemainingSeconds)))
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                }

                AirPlayRoutePicker()
                    .frame(width: 36, height: 36)
                    .modifier(PlayerGlassPillModifier(shape: Circle()))

                playerIconButton("lock.open", label: "Заблокировать экран", size: 36) {
                    withAnimation { isLocked = true }
                    scheduleControlsHide()
                }

                playerIconButton(
                    landscape ? "rectangle.portrait" : "rectangle",
                    label: landscape ? "Вертикально" : "Горизонтально",
                    size: 36
                ) {
                    OrientationManager.shared.setPlayerOrientation(landscape: !landscape)
                    scheduleControlsHide()
                }

                playerIconButton("ellipsis", label: "Настройки плеера", size: 36) {
                    showSettingsSheet = true
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom)
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
            if vm.request.episodes.count > 1 {
                playerIconButton("backward.end.fill", label: "Предыдущая серия", size: 42) {
                    vm.playPrevious()
                }
                .disabled(!vm.hasPrevious)
                .opacity(vm.hasPrevious ? 1 : 0.35)
            }

            playerIconButton("gobackward.\(prefs.seekStep)", label: "Назад на \(prefs.seekStep) сек", size: 48) {
                vm.engine.seekRelative(-Double(prefs.seekStep))
                triggerSeekBurst(-prefs.seekStep)
                scheduleControlsHide()
            }

            playerIconButton(
                vm.engine.isPaused ? "play.fill" : "pause.fill",
                label: vm.engine.isPaused ? "Воспроизвести" : "Пауза",
                size: 64
            ) {
                vm.engine.togglePause()
            }

            playerIconButton("goforward.\(prefs.seekStep)", label: "Вперёд на \(prefs.seekStep) сек", size: 48) {
                vm.engine.seekRelative(Double(prefs.seekStep))
                triggerSeekBurst(prefs.seekStep)
                scheduleControlsHide()
            }

            if vm.request.episodes.count > 1 {
                playerIconButton("forward.end.fill", label: "Следующая серия", size: 42) {
                    vm.playNext()
                }
                .disabled(!vm.hasNext)
                .opacity(vm.hasNext ? 1 : 0.35)
            }
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if vm.engine.currentDuration > 180 || isOpening {
                    Button {
                        vm.skipOpening()
                        triggerSeekBurst(85)
                        scheduleControlsHide()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("+85 с")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundColor(Nf.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Nf.mint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening)
                    .opacity(isOpening ? 0.5 : 1)
                }

                if !vm.translations.isEmpty && !vm.isOfflinePlayback {
                    Button {
                        showTranslationsSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform")
                                .font(.system(size: 12, weight: .semibold))
                            Text(vm.currentTranslation?.author ?? "Озвучка")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                }

                if !vm.availableQualities.isEmpty && !vm.isOfflinePlayback {
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
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.tv")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(vm.selectedHeight)p")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                    }
                }

                if vm.hasSubtitles || !vm.engine.subtitleTracks.isEmpty || vm.engine.audioTracks.count > 1 {
                    Button {
                        showTracksSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: vm.subtitlesVisible ? "captions.bubble.fill" : "captions.bubble")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Дорожки")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
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
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(format: "%.2g×", vm.speed))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundColor(abs(vm.speed - 1.0) > 0.01 ? Nf.violet : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .modifier(PlayerGlassPillModifier(shape: Capsule()))
                }

                if vm.request.episodes.count > 1 {
                    Button {
                        showEpisodesSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Серии")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    vm.toggleAspectFill()
                    scheduleControlsHide()
                } label: {
                    Image(systemName: vm.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .modifier(PlayerGlassPillModifier(shape: Circle()))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func skipPill(_ seg: SkipSegment) -> some View {
        Button {
            vm.skipOpening()
            scheduleControlsHide()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Пропустить \(seg.label.lowercased())")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundColor(Nf.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Nf.mint, in: Capsule())
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func autoNextCard(remaining: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Следующая серия через \(remaining) с")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
                if vm.request.episodes.indices.contains(vm.currentIndex + 1) {
                    Text(vm.request.episodes[vm.currentIndex + 1].label)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.75))
                }
            }

            Button {
                vm.playNext()
            } label: {
                Text("Смотреть")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Nf.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Nf.violet, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                vm.cancelAutoNext()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(PlayerGlassPillModifier(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
    }

    // MARK: - Feedback Overlays

    private var feedbackOverlay: some View {
        ZStack {
            if isBoosting {
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
                    .padding(.top, 24)
                    Spacer()
                }
            }

            if seekBurstDelta != 0 {
                let sign = seekBurstDelta > 0 ? "+" : "−"
                Text("\(sign)\(abs(seekBurstDelta)) с")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            if let target = horizontalScrubTarget {
                VStack(spacing: 4) {
                    Text(AppFormatters.formatClock(target))
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    let sign = horizontalScrubDelta >= 0 ? "+" : "−"
                    Text("\(sign)\(Int(abs(horizontalScrubDelta))) с")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Nf.violet)
                        .monospacedDigit()
                    if let chapter = chapterTitle(at: target) {
                        Text(chapter)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let fb = sideFeedback {
                sideGestureHUD(fb)
            }

            if let notice = vm.markedWatchedNotice ?? vm.toastNotice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Nf.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Nf.mint, in: Capsule())
                        .padding(.bottom, showControls ? 124 : 30)
                }
                .transition(.opacity)
            }
        }
    }

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
        .allowsHitTesting(false)
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
                        .frame(minHeight: 44)
                        .modifier(PlayerGlassPillModifier(shape: Capsule()))
                }
                .buttonStyle(.plain)
                .padding(18)
            }
            Spacer()
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: vm.isSubscriptionRequired ? "crown.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(vm.isSubscriptionRequired ? Nf.violet : Nf.amber)
            Text(vm.isSubscriptionRequired ? "Нужна подписка Anime 365" : message)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if vm.isSubscriptionRequired {
                Text("Anime 365 отдаёт видеопотоки только аккаунтам с активной подпиской.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 10) {
                Button("Закрыть") { dismiss() }
                    .buttonStyle(.bordered)

                if !vm.translations.isEmpty && !vm.isOfflinePlayback {
                    Button("Озвучка") { showTranslationsSheet = true }
                        .buttonStyle(.bordered)
                }

                Button("Повторить") {
                    vm.loadCurrentEpisode(resumeFromSaved: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func sideGestureHUD(_ overlay: PlayerSideFeedback) -> some View {
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
                .font(.system(size: size >= 60 ? 26 : size >= 48 ? 22 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .modifier(PlayerGlassPillModifier(shape: Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func triggerSeekBurst(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.12)) {
            seekBurstDelta += delta
        }
        seekBurstTask?.cancel()
        seekBurstTask = Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            if !Task.isCancelled {
                withAnimation(.easeIn(duration: 0.18)) { seekBurstDelta = 0 }
            }
        }
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if !vm.engine.isPaused && horizontalScrubTarget == nil && !isWaiting &&
                !showSettingsSheet && !showEpisodesSheet && !showTranslationsSheet && !showTracksSheet {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func chapterTitle(at seconds: Double) -> String? {
        guard !vm.chapters.isEmpty else { return nil }
        return vm.chapters.last(where: { $0.start <= seconds })?.title.nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Isolated High-Frequency Timeline Scrubber

private struct PlayerTimelineBar: View {
    @ObservedObject var clock: MpvPlaybackClock
    let chapters: [PlayerChapter]
    @Binding var showRemaining: Bool
    let onScrubStart: () -> Void
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var pendingSeekTarget: Double?
    @State private var pendingSeekExpiresAt: Date = .distantPast

    private var effectiveDuration: Double { max(clock.duration, 1) }

    private var displayedPosition: Double {
        if isScrubbing { return scrubPosition }
        if let pending = pendingSeekTarget, Date() < pendingSeekExpiresAt {
            if abs(clock.position - pending) < 1.2 {
                DispatchQueue.main.async { pendingSeekTarget = nil }
                return clock.position
            }
            return pending
        }
        return min(max(clock.position, 0), effectiveDuration)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(AppFormatters.formatClock(displayedPosition))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()

                if let ch = chapters.last(where: { $0.start <= displayedPosition }), !ch.title.isEmpty {
                    Text("· \(ch.title)")
                        .foregroundStyle(ch.kind.isSkippable ? Nf.mint : .white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    showRemaining.toggle()
                } label: {
                    if clock.duration > 0 {
                        let text = showRemaining
                            ? "−\(AppFormatters.formatClock(max(clock.duration - displayedPosition, 0)))"
                            : AppFormatters.formatClock(clock.duration)
                        Text(text)
                            .foregroundStyle(.white.opacity(0.78))
                            .monospacedDigit()
                    } else {
                        Text("--:--")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.caption.weight(.medium))

            GeometryReader { barGeo in
                let width = max(barGeo.size.width, 1)
                let progressFrac = min(max(displayedPosition / effectiveDuration, 0), 1)
                let cacheFrac = min(max(clock.cacheTime / effectiveDuration, 0), 1)
                let barHeight: CGFloat = isScrubbing ? 8 : 5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: barHeight)

                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: width * cacheFrac, height: barHeight)

                    // Highlight skippable OP/ED/Recap segments
                    ForEach(Array(chapters.enumerated()), id: \.offset) { idx, ch in
                        if ch.kind.isSkippable && clock.duration > 0 {
                            let end = (idx + 1 < chapters.count) ? chapters[idx + 1].start : clock.duration
                            let startX = width * min(max(ch.start / effectiveDuration, 0), 1)
                            let segW = max(2, width * min(max((end - ch.start) / effectiveDuration, 0), 1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Nf.mint.opacity(0.75))
                                .frame(width: segW, height: barHeight)
                                .offset(x: startX)
                        }
                    }

                    Capsule()
                        .fill(Nf.violet)
                        .frame(width: width * progressFrac, height: barHeight)

                    // Chapter tick marks
                    ForEach(chapters.dropFirst()) { ch in
                        if clock.duration > 0 {
                            let x = width * min(max(ch.start / effectiveDuration, 0), 1)
                            Rectangle()
                                .fill(Color.black.opacity(0.65))
                                .frame(width: 2, height: barHeight + 1)
                                .offset(x: x)
                        }
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: isScrubbing ? 18 : 13, height: isScrubbing ? 18 : 13)
                        .shadow(color: .black.opacity(0.45), radius: 3)
                        .offset(x: max(0, min(width - 14, width * progressFrac - 7)))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            guard clock.duration > 0 else { return }
                            if !isScrubbing {
                                isScrubbing = true
                                onScrubStart()
                            }
                            let frac = min(max(val.location.x / width, 0), 1)
                            scrubPosition = Double(frac) * effectiveDuration
                        }
                        .onEnded { val in
                            guard clock.duration > 0 else { return }
                            let frac = min(max(val.location.x / width, 0), 1)
                            let target = Double(frac) * effectiveDuration
                            pendingSeekTarget = target
                            pendingSeekExpiresAt = Date().addingTimeInterval(1.2)
                            isScrubbing = false
                            onSeek(target)
                        }
                )
            }
            .frame(height: 28)
            .disabled(clock.duration <= 0)
        }
    }
}

private struct PlayerGlassPillModifier<ControlShape: Shape>: ViewModifier {
    let shape: ControlShape

    func body(content: Content) -> some View {
        content
            .background {
                if #available(iOS 26.0, *) {
                    shape.fill(.clear).glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.7))
                }
            }
    }
}

private struct PlayerKeyboardShortcutsModifier: ViewModifier {
    let onTogglePause: () -> Void
    let onSeekLeft: () -> Void
    let onSeekRight: () -> Void
    let onToggleFill: () -> Void
    let onSkip: () -> Void
    let onNext: () -> Void
    let onPrev: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .focusable()
                .onKeyPress(.space) { onTogglePause(); return .handled }
                .onKeyPress(.leftArrow) { onSeekLeft(); return .handled }
                .onKeyPress(.rightArrow) { onSeekRight(); return .handled }
                .onKeyPress("f") { onToggleFill(); return .handled }
                .onKeyPress("s") { onSkip(); return .handled }
                .onKeyPress("n") { onNext(); return .handled }
                .onKeyPress("p") { onPrev(); return .handled }
        } else {
            content
        }
    }
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
                            HStack(spacing: 8) {
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
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
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
        .presentationDetents([.medium, .large])
    }
}

private struct PlayerTracksSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                if vm.hasSubtitles || !vm.engine.subtitleTracks.isEmpty {
                    Section("Субтитры") {
                        Toggle("Показывать субтитры", isOn: Binding(
                            get: { vm.subtitlesVisible },
                            set: { _ in vm.toggleSubtitles() }
                        ))

                        ForEach(vm.engine.subtitleTracks) { track in
                            let info = track.info
                            Button {
                                vm.engine.selectSubtitleTrack(id: track.id)
                                vm.subtitlesVisible = true
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(info.kind == .signs ? "\(info.name) · Надписи" : info.name)
                                            .foregroundColor(Nf.text)
                                        if let detail = info.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundColor(Nf.textMute)
                                        }
                                    }
                                    Spacer()
                                    if track.isSelected && vm.subtitlesVisible {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Nf.violet)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
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

                        HStack {
                            Text("Синхронизация")
                            Spacer()
                            HStack(spacing: 8) {
                                Button("−0.5") { vm.adjustSubDelay(by: -0.5) }.buttonStyle(.bordered)
                                Button("−0.1") { vm.adjustSubDelay(by: -0.1) }.buttonStyle(.bordered)
                                Text(String(format: "%+.1f с", vm.subDelay))
                                    .font(.caption.weight(.bold))
                                    .monospacedDigit()
                                    .frame(minWidth: 48)
                                Button("+0.1") { vm.adjustSubDelay(by: 0.1) }.buttonStyle(.bordered)
                                Button("+0.5") { vm.adjustSubDelay(by: 0.5) }.buttonStyle(.bordered)
                            }
                            .font(.caption)
                        }
                        if abs(vm.subDelay) > 0.05 {
                            Button("Сбросить задержку") { vm.resetSubDelay() }
                        }
                    }
                }

                if vm.engine.audioTracks.count > 1 {
                    Section("Аудиодорожка") {
                        ForEach(vm.engine.audioTracks) { track in
                            let info = track.info
                            Button {
                                vm.engine.selectAudioTrack(id: track.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(info.name)
                                            .foregroundColor(Nf.text)
                                        if let detail = info.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundColor(Nf.textMute)
                                        }
                                    }
                                    Spacer()
                                    if track.isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Nf.violet)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Дорожки и субтитры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PlayerEpisodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                        .id(idx)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(vm.currentIndex, anchor: .center)
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
        .presentationDetents([.medium, .large])
    }
}

private struct PlayerSettingsSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                if !vm.availableQualities.isEmpty && !vm.isOfflinePlayback {
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

                Section("Воспроизведение и звук") {
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
                        set: { vm.setAspectFill($0) }
                    ))

                    Toggle("Выравнивание громкости", isOn: Binding(
                        get: { prefs.normalizeAudio },
                        set: { val in
                            prefs.normalizeAudio = val
                            vm.engine.setAudioNormalize(val)
                        }
                    ))

                    Picker("Таймер сна", selection: Binding(
                        get: { vm.sleepTimer },
                        set: { vm.setSleepTimer($0) }
                    )) {
                        ForEach(SleepTimerOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }

                    if vm.sleepTimer.rawValue > 0 {
                        Button("Продлить на +5 минут") {
                            vm.extendSleepTimerBy5Minutes()
                        }
                    }
                }

                Section("Жесты и пропуск") {
                    Toggle("Удержание 2×", isOn: $prefs.holdBoost)
                    Toggle("Свайпы яркости и громкости", isOn: $prefs.sideGestures)
                    Toggle("Автопропуск AniSkip", isOn: $prefs.aniskipEnabled)
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
        .presentationDetents([.medium, .large])
    }
}
