//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.nnmvdkvn6v.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: "claude-sonnet-4-6")
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    private lazy var openAIRealtimeCompanionClient: OpenAIRealtimeCompanionClient = {
        return OpenAIRealtimeCompanionClient(
            openAIClientSecretProxyURL: "\(Self.workerBaseURL)/realtime-client-secret",
            xAIClientSecretProxyURL: "\(Self.workerBaseURL)/xai-realtime-client-secret"
        )
    }()

    private let realtimeAudioEngine = AVAudioEngine()
    private let realtimeMicrophoneAudioRouter = OpenAIRealtimeMicrophoneAudioRouter()
    private var currentRealtimeSession: OpenAIRealtimeCompanionSession?
    private var isRealtimePushToTalkSessionActive = false
    private var hasPendingRealtimeFinishAfterSessionStart = false

    var voiceProviderDisplayName: String {
        selectedModel.voiceEngineDisplayName
    }

    /// Conversation history so the realtime model remembers prior exchanges across
    /// fresh push-to-talk sessions. Each entry is the user's voice input and the response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The realtime model used for voice, reasoning, screen understanding, and speech output.
    @Published var selectedModel: RealtimeCompanionModelProvider = {
        let savedModelID = UserDefaults.standard.string(forKey: "selectedRealtimeCompanionModel")
        return savedModelID.flatMap(RealtimeCompanionModelProvider.init(rawValue:)) ?? .openAIRealtime2
    }()

    func setSelectedModel(_ model: RealtimeCompanionModelProvider) {
        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedRealtimeCompanionModel")
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the legacy onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        stopRealtimeAudioCapture(resetAudioRouter: true)
        currentRealtimeSession?.cancel()
        currentRealtimeSession = nil
        isRealtimePushToTalkSessionActive = false
        hasPendingRealtimeFinishAfterSessionStart = false
        openAIRealtimeCompanionClient.stopPlayback()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !isRealtimePushToTalkSessionActive else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }
            print("🎛️ Clicky Realtime: hotkey pressed, permissions accessibility=\(hasAccessibilityPermission), screen=\(hasScreenRecordingPermission), mic=\(hasMicrophonePermission), screenContent=\(hasScreenContentPermission)")

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            openAIRealtimeCompanionClient.stopPlayback()
            currentRealtimeSession?.cancel()
            currentRealtimeSession = nil
            hasPendingRealtimeFinishAfterSessionStart = false
            stopRealtimeAudioCapture(resetAudioRouter: true)
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await self.startRealtimePushToTalk()
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            print("🎛️ Clicky Realtime: hotkey released")
            finishRealtimePushToTalk()
        case .none:
            break
        }
    }

    private func startRealtimePushToTalk() async {
        guard currentRealtimeSession == nil else { return }

        let startTime = Date()
        isRealtimePushToTalkSessionActive = true
        hasPendingRealtimeFinishAfterSessionStart = false
        voiceState = .processing
        print("🎙️ Clicky Realtime: starting push-to-talk")

        do {
            realtimeMicrophoneAudioRouter.beginBuffering()
            try startRealtimeAudioCapture()

            let realtimeSession = try await openAIRealtimeCompanionClient.startSession(
                modelProvider: selectedModel,
                instructions: makeRealtimeCompanionInstructions()
            )
            guard !Task.isCancelled && (isRealtimePushToTalkSessionActive || hasPendingRealtimeFinishAfterSessionStart) else {
                realtimeSession.cancel()
                currentRealtimeSession = nil
                voiceState = .idle
                return
            }
            currentRealtimeSession = realtimeSession
            realtimeMicrophoneAudioRouter.attachRealtimeSessionAndFlush(realtimeSession)

            if hasPendingRealtimeFinishAfterSessionStart {
                print("🎙️ Clicky Realtime: session ready after key release, committing buffered turn")
                finishRealtimePushToTalk()
                return
            }

            voiceState = .listening
            let durationMilliseconds = Int(Date().timeIntervalSince(startTime) * 1000)
            print("🎙️ Clicky Realtime: push-to-talk session started in \(durationMilliseconds)ms")
        } catch is CancellationError {
            isRealtimePushToTalkSessionActive = false
            hasPendingRealtimeFinishAfterSessionStart = false
            currentRealtimeSession = nil
            stopRealtimeAudioCapture(resetAudioRouter: true)
            voiceState = .idle
            print("🛑 Clicky Realtime: start cancelled")
        } catch {
            isRealtimePushToTalkSessionActive = false
            hasPendingRealtimeFinishAfterSessionStart = false
            currentRealtimeSession = nil
            stopRealtimeAudioCapture(resetAudioRouter: true)
            voiceState = .idle
            ClickyAnalytics.trackResponseError(error: error.localizedDescription)
            print("⚠️ \(selectedModel.voiceEngineDisplayName) start error: \(error)")
            speakCompanionErrorFallback()
        }
    }

    private func finishRealtimePushToTalk() {
        guard isRealtimePushToTalkSessionActive else {
            print("🎛️ Clicky Realtime: finish requested without active session")
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        stopRealtimeAudioCapture()
        print("🎙️ Clicky Realtime: stopped mic capture, preparing response")

        guard let realtimeSession = currentRealtimeSession else {
            hasPendingRealtimeFinishAfterSessionStart = true
            voiceState = .processing
            print("🎙️ Clicky Realtime: release happened before session was ready; will commit after startup")
            return
        }

        isRealtimePushToTalkSessionActive = false
        hasPendingRealtimeFinishAfterSessionStart = false

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let captureStartedAt = Date()
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                let captureDurationMilliseconds = Int(Date().timeIntervalSince(captureStartedAt) * 1000)
                let screenSummary = screenCaptures.enumerated().map { index, capture in
                    let cursorMarker = capture.isCursorScreen ? " cursor" : ""
                    return "screen\(index + 1)=\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels)\(cursorMarker)"
                }.joined(separator: ", ")
                print("🖼️ Clicky Realtime: captured \(screenCaptures.count) screen(s) in \(captureDurationMilliseconds)ms: \(screenSummary)")

                guard !Task.isCancelled else { return }

                let responseStartedAt = Date()
                let realtimeResult = try await realtimeSession.finishAndGenerateResponse(
                    screenCaptures: screenCaptures
                )
                let responseDurationMilliseconds = Int(Date().timeIntervalSince(responseStartedAt) * 1000)
                print("✅ Clicky Realtime: response received in \(responseDurationMilliseconds)ms, textChars=\(realtimeResult.assistantResponseText.count), audioBytes=\(realtimeResult.responseAudioData.count), transcript=\(realtimeResult.userTranscriptText != nil), pointTarget=\(realtimeResult.pointTarget != nil), clickTarget=\(realtimeResult.clickTarget != nil)")

                guard !Task.isCancelled else { return }

                currentRealtimeSession = nil

                let rawAssistantText = realtimeResult.assistantResponseText
                let spokenText = cleanRealtimeAssistantText(rawAssistantText)
                let userTranscriptText = realtimeResult.userTranscriptText ?? "realtime voice input"
                lastTranscript = userTranscriptText
                print("🗣️ Clicky Realtime: final transcript=\"\(Self.truncatedForLog(userTranscriptText))\"")
                print("💬 Clicky Realtime: assistant text=\"\(Self.truncatedForLog(spokenText))\"")
                ClickyAnalytics.trackUserMessageSent(transcript: userTranscriptText)

                handleRealtimeScreenActionsIfNeeded(
                    pointTarget: realtimeResult.pointTarget,
                    clickTarget: realtimeResult.clickTarget,
                    rawAssistantText: rawAssistantText,
                    screenCaptures: screenCaptures
                )

                conversationHistory.append((
                    userTranscript: userTranscriptText,
                    assistantResponse: spokenText
                ))

                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if !realtimeResult.responseAudioData.isEmpty {
                    do {
                        try openAIRealtimeCompanionClient.playResponseAudio(realtimeResult.responseAudioData)
                        voiceState = .responding
                        print("🔊 Clicky Realtime: audio playback started")
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ \(selectedModel.voiceEngineDisplayName) audio playback error: \(error)")
                        speakCompanionErrorFallback()
                    }
                } else if !spokenText.isEmpty {
                    print("⚠️ Clicky Realtime: response had text but no audio")
                    speakCompanionErrorFallback()
                } else {
                    print("⚠️ Clicky Realtime: response completed with no text or audio")
                }
                realtimeMicrophoneAudioRouter.reset()
            } catch is CancellationError {
                // User spoke again — response was interrupted.
                print("🛑 Clicky Realtime: response task cancelled")
                realtimeMicrophoneAudioRouter.reset()
            } catch {
                currentRealtimeSession = nil
                hasPendingRealtimeFinishAfterSessionStart = false
                realtimeMicrophoneAudioRouter.reset()
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ \(selectedModel.voiceEngineDisplayName) response error: \(error)")
                speakCompanionErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func startRealtimeAudioCapture() throws {
        guard !realtimeAudioEngine.isRunning else {
            print("🎙️ Clicky Realtime: audio engine already running")
            return
        }

        let inputNode = realtimeAudioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.realtimeMicrophoneAudioRouter.appendAudioBuffer(buffer)
            self?.updateRealtimeAudioPowerLevel(from: buffer)
        }

        realtimeAudioEngine.prepare()
        try realtimeAudioEngine.start()
        print("🎙️ Clicky Realtime: audio engine started, input sampleRate=\(Int(inputFormat.sampleRate)), channels=\(inputFormat.channelCount)")
    }

    private func stopRealtimeAudioCapture(resetAudioRouter: Bool = false) {
        if realtimeAudioEngine.isRunning {
            realtimeAudioEngine.stop()
            print("🎙️ Clicky Realtime: audio engine stopped")
        }
        realtimeAudioEngine.inputNode.removeTap(onBus: 0)
        if resetAudioRouter {
            realtimeMicrophoneAudioRouter.reset()
        }
        currentAudioPowerLevel = 0
    }

    private nonisolated func updateRealtimeAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData?[0] else { return }
        let frameLength = Int(audioBuffer.frameLength)
        guard frameLength > 0 else { return }

        var sumOfSquares: Float = 0
        for frameIndex in 0..<frameLength {
            let sample = channelData[frameIndex]
            sumOfSquares += sample * sample
        }

        let rms = sqrt(sumOfSquares / Float(frameLength))
        let normalizedPowerLevel = CGFloat(min(max(rms * 8.0, 0), 1))

        Task { @MainActor in
            self.currentAudioPowerLevel = normalizedPowerLevel
        }
    }

    private func makeRealtimeCompanionInstructions() -> String {
        guard !conversationHistory.isEmpty else {
            return Self.companionVoiceResponseSystemPrompt
        }

        let formattedHistory = conversationHistory
            .suffix(10)
            .map { exchange in
                "user: \(exchange.userTranscript)\nassistant: \(exchange.assistantResponse)"
            }
            .joined(separator: "\n\n")

        return """
        \(Self.companionVoiceResponseSystemPrompt)

        conversation history:
        \(formattedHistory)
        """
    }

    private func cleanRealtimeAssistantText(_ assistantText: String) -> String {
        let parseResult = Self.parsePointingCoordinates(from: assistantText)
        return parseResult.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ScreenCoordinateMapping {
        let globalLocation: CGPoint
        let displayFrame: CGRect
        let screenshotCoordinate: CGPoint
        let snappedElementCandidate: CompanionScreenElementCandidate?
        var snappedElementLabel: String? {
            snappedElementCandidate?.label
        }
    }

    private func handleRealtimeScreenActionsIfNeeded(
        pointTarget: OpenAIRealtimePointTarget?,
        clickTarget: OpenAIRealtimeClickTarget?,
        rawAssistantText: String,
        screenCaptures: [CompanionScreenCapture]
    ) {
        if let pointTarget {
            handlePointingCoordinate(
                pointCoordinate: CGPoint(x: pointTarget.x, y: pointTarget.y),
                elementLabel: pointTarget.label,
                screenNumber: pointTarget.screenNumber,
                screenCaptures: screenCaptures
            )
        }

        let parseResult = Self.parsePointingCoordinates(from: rawAssistantText)
        if pointTarget == nil, let pointCoordinate = parseResult.coordinate {
            handlePointingCoordinate(
                pointCoordinate: pointCoordinate,
                elementLabel: parseResult.elementLabel,
                screenNumber: parseResult.screenNumber,
                screenCaptures: screenCaptures
            )
        }

        if let clickTarget {
            handleClickCoordinate(
                clickCoordinate: CGPoint(x: clickTarget.x, y: clickTarget.y),
                elementLabel: clickTarget.label,
                screenNumber: clickTarget.screenNumber,
                screenCaptures: screenCaptures
            )
        }
    }

    private func handlePointingCoordinate(
        pointCoordinate: CGPoint,
        elementLabel: String?,
        screenNumber: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) {
        guard let mapping = mapScreenshotCoordinateToScreen(
            screenshotCoordinate: pointCoordinate,
            elementLabel: elementLabel,
            screenNumber: screenNumber,
            screenCaptures: screenCaptures,
            actionName: "Element pointing"
        ) else {
            return
        }

        detectedElementScreenLocation = mapping.globalLocation
        detectedElementDisplayFrame = mapping.displayFrame
        detectedElementBubbleText = elementLabel
        ClickyAnalytics.trackElementPointed(elementLabel: elementLabel)
        let snapDescription = mapping.snappedElementLabel.map { ", snapped=\"\($0)\"" } ?? ""
        print("🎯 Element pointing: requested=(\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) resolved=(\(Int(mapping.screenshotCoordinate.x)), \(Int(mapping.screenshotCoordinate.y))) global=(\(Int(mapping.globalLocation.x)), \(Int(mapping.globalLocation.y))) display=\(Int(mapping.displayFrame.width))x\(Int(mapping.displayFrame.height))\(snapDescription) → \"\(elementLabel ?? "element")\"")
    }

    private func handleClickCoordinate(
        clickCoordinate: CGPoint,
        elementLabel: String?,
        screenNumber: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) {
        guard hasAccessibilityPermission else {
            print("🖱️ Element click blocked: accessibility permission is not granted")
            return
        }

        guard let mapping = mapScreenshotCoordinateToScreen(
            screenshotCoordinate: clickCoordinate,
            elementLabel: elementLabel,
            screenNumber: screenNumber,
            screenCaptures: screenCaptures,
            actionName: "Element click"
        ) else {
            return
        }

        detectedElementScreenLocation = mapping.globalLocation
        detectedElementDisplayFrame = mapping.displayFrame
        detectedElementBubbleText = "clicking \(elementLabel ?? "there")"
        ClickyAnalytics.trackElementClicked(elementLabel: elementLabel)
        let snapDescription = mapping.snappedElementLabel.map { ", snapped=\"\($0)\"" } ?? ""
        print("🖱️ Element click: requested=(\(Int(clickCoordinate.x)), \(Int(clickCoordinate.y))) resolved=(\(Int(mapping.screenshotCoordinate.x)), \(Int(mapping.screenshotCoordinate.y))) global=(\(Int(mapping.globalLocation.x)), \(Int(mapping.globalLocation.y))) display=\(Int(mapping.displayFrame.width))x\(Int(mapping.displayFrame.height))\(snapDescription) → \"\(elementLabel ?? "element")\"")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            if self.performAccessibilityPressIfPossible(
                on: mapping.snappedElementCandidate,
                requestedElementLabel: elementLabel
            ) {
                return
            }

            self.performLeftMouseClick(at: mapping.globalLocation, elementLabel: elementLabel)
        }
    }

    private func mapScreenshotCoordinateToScreen(
        screenshotCoordinate: CGPoint,
        elementLabel: String?,
        screenNumber: Int?,
        screenCaptures: [CompanionScreenCapture],
        actionName: String
    ) -> ScreenCoordinateMapping? {
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        guard let targetScreenCapture else {
            print("🎯 \(actionName): \(elementLabel ?? "no element")")
            return nil
        }
        print("🎯 \(actionName): screen candidates=\(targetScreenCapture.elementCandidates.count), requestedLabel=\"\(elementLabel ?? "none")\"")

        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        let snappedCandidate = bestElementCandidate(
            matching: elementLabel,
            near: screenshotCoordinate,
            in: targetScreenCapture
        )
        let resolvedScreenshotCoordinate = snappedCandidate.map {
            CGPoint(
                x: CGFloat($0.centerXInScreenshotPixels),
                y: CGFloat($0.centerYInScreenshotPixels)
            )
        } ?? screenshotCoordinate

        let clampedX = max(0, min(resolvedScreenshotCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(resolvedScreenshotCoordinate.y, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        return ScreenCoordinateMapping(
            globalLocation: globalLocation,
            displayFrame: displayFrame,
            screenshotCoordinate: CGPoint(x: clampedX, y: clampedY),
            snappedElementCandidate: snappedCandidate
        )
    }

    private func performAccessibilityPressIfPossible(
        on candidate: CompanionScreenElementCandidate?,
        requestedElementLabel: String?
    ) -> Bool {
        guard let candidate,
              let accessibilityElement = candidate.accessibilityElement else {
            return false
        }

        let actionResult = AXUIElementPerformAction(
            accessibilityElement,
            kAXPressAction as CFString
        )
        if actionResult == .success {
            print("🖱️ Element click pressed AX control \"\(candidate.label)\" for \"\(requestedElementLabel ?? "element")\"")
            return true
        }

        print("🖱️ Element click AX press failed for \"\(candidate.label)\" with \(actionResult.rawValue); falling back to mouse event")
        return false
    }

    private func bestElementCandidate(
        matching elementLabel: String?,
        near screenshotCoordinate: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CompanionScreenElementCandidate? {
        guard let elementLabel,
              !elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !screenCapture.elementCandidates.isEmpty else {
            return nil
        }

        let queryTokens = normalizedElementTokens(from: elementLabel)
        guard !queryTokens.isEmpty else { return nil }

        let scoredCandidates = screenCapture.elementCandidates.compactMap { candidate -> (candidate: CompanionScreenElementCandidate, score: Double)? in
            let candidateTokens = normalizedElementTokens(from: "\(candidate.label) \(candidate.role)")
            let overlapCount = queryTokens.intersection(candidateTokens).count
            let candidateText = normalizedElementText("\(candidate.label) \(candidate.role)")
            let queryText = normalizedElementText(elementLabel)
            let textContainsMatch = candidateText.contains(queryText) || queryText.contains(candidateText)
            let playPauseSynonymMatch = queryTokens.contains("play")
                && (candidateTokens.contains("pause") || candidateText.contains("play pause"))

            guard overlapCount > 0 || textContainsMatch || playPauseSynonymMatch else {
                return nil
            }

            let deltaX = Double(candidate.centerXInScreenshotPixels) - Double(screenshotCoordinate.x)
            let deltaY = Double(candidate.centerYInScreenshotPixels) - Double(screenshotCoordinate.y)
            let distance = hypot(deltaX, deltaY)
            let distancePenalty = min(distance / 500.0, 2.0)
            let textScore = Double(overlapCount)
                + (textContainsMatch ? 2.0 : 0.0)
                + (playPauseSynonymMatch ? 1.5 : 0.0)
            return (candidate, textScore - distancePenalty)
        }

        return scoredCandidates
            .filter { $0.score > -0.25 }
            .max { $0.score < $1.score }?
            .candidate
    }

    private func normalizedElementText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "ax", with: " ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedElementTokens(from text: String) -> Set<String> {
        let ignoredTokens: Set<String> = ["button", "control", "item", "field", "ax"]
        return Set(
            normalizedElementText(text)
                .split(separator: " ")
                .map(String.init)
                .filter { !ignoredTokens.contains($0) }
        )
    }

    private func performLeftMouseClick(at screenLocation: CGPoint, elementLabel: String?) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let mouseDownEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: screenLocation,
            mouseButton: .left
        ),
        let mouseUpEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: screenLocation,
            mouseButton: .left
        ) else {
            print("🖱️ Element click failed: could not create mouse events for \"\(elementLabel ?? "element")\"")
            return
        }

        mouseDownEvent.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            mouseUpEvent.post(tap: .cghidEventTap)
            print("🖱️ Element click posted → \"\(elementLabel ?? "element")\"")
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, use the point_at_screen_element tool if it is available. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    if the screen context includes known clickable/accessibility element centers, prefer those exact centers whenever the label matches the thing the user asked for. those centers are usually more accurate than estimating from the screenshot.

    tool arguments: x,y are integer pixel coordinates in the screenshot's coordinate space, label is a short 1-3 word description of the element (like "search bar" or "save button"), and screen is the screen number from the image label. if no tool is available, append a coordinate tag at the very end of your response after your spoken text instead: [POINT:x,y:label] or [POINT:x,y:label:screen2]. this fallback tag must not be spoken as natural language.

    element clicking:
    if the user explicitly asks you to click something, use the click_screen_element tool instead of only pointing. only click the requested element. don't click send, post, delete, purchase, checkout, submit, install, share, or other destructive/external-action buttons unless the user clearly asked for that exact action. if clicking would be risky, point at the element and explain what they should confirm first.

    if pointing wouldn't help, do not call the tool. if no tool is available, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCompanionErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCompanionErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for model audio to finish playing.
            while elevenLabsTTSClient.isPlaying || openAIRealtimeCompanionClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a short fallback using macOS system TTS when the model/audio
    /// pipeline fails before generated audio can play.
    private func speakCompanionErrorFallback() {
        let utterance = "I hit a setup error starting realtime. Check the Clicky logs for the exact message."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    private static func truncatedForLog(_ text: String, limit: Int = 180) -> String {
        let singleLineText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLineText.count > limit else {
            return singleLineText
        }

        return String(singleLineText.prefix(limit)) + "..."
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    /// Uses the cursor screen geometry to run a local pointing demo during
    /// onboarding without depending on a model request.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let pointCoordinate = CGPoint(
                    x: CGFloat(cursorScreenCapture.screenshotWidthInPixels) * 0.52,
                    y: CGFloat(cursorScreenCapture.screenshotHeightInPixels) * 0.46
                )

                handlePointingCoordinate(
                    pointCoordinate: pointCoordinate,
                    elementLabel: "right here",
                    screenNumber: nil,
                    screenCaptures: screenCaptures
                )
                detectedElementBubbleText = "i can point too"
                print("🎯 Onboarding demo: local point at screenshot=(\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
