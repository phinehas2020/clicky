//
//  OpenAIRealtimeCompanionClient.swift
//  leanring-buddy
//
//  Realtime voice API client for Clicky's push-to-talk companion flow.
//  It streams microphone PCM, sends screenshot context,
//  receives assistant audio, and captures optional cursor-pointing tool calls.
//

import AVFoundation
import Foundation

enum RealtimeCompanionModelProvider: String, CaseIterable, Identifiable {
    case openAIRealtime2 = "gpt-realtime-2"
    case grokVoiceThinkFast = "grok-voice-think-fast-1.0"

    var id: String {
        rawValue
    }

    var pickerLabel: String {
        switch self {
        case .openAIRealtime2:
            return "Realtime 2"
        case .grokVoiceThinkFast:
            return "Grok Voice"
        }
    }

    var voiceEngineDisplayName: String {
        switch self {
        case .openAIRealtime2:
            return "OpenAI Realtime"
        case .grokVoiceThinkFast:
            return "xAI Voice"
        }
    }

    var websocketURL: URL {
        switch self {
        case .openAIRealtime2:
            return URL(string: "wss://api.openai.com/v1/realtime?model=\(rawValue)")!
        case .grokVoiceThinkFast:
            return URL(string: "wss://api.x.ai/v1/realtime?model=\(rawValue)")!
        }
    }

    var generatedVoiceName: String {
        switch self {
        case .openAIRealtime2:
            return "marin"
        case .grokVoiceThinkFast:
            return "eve"
        }
    }

    var supportsScreenshotImages: Bool {
        switch self {
        case .openAIRealtime2:
            return true
        case .grokVoiceThinkFast:
            return false
        }
    }
}

struct OpenAIRealtimePointTarget {
    let x: CGFloat
    let y: CGFloat
    let label: String?
    let screenNumber: Int?
}

struct OpenAIRealtimeClickTarget {
    let x: CGFloat
    let y: CGFloat
    let label: String?
    let screenNumber: Int?
}

struct OpenAIRealtimeCompanionResult {
    let assistantResponseText: String
    let userTranscriptText: String?
    let pointTarget: OpenAIRealtimePointTarget?
    let clickTarget: OpenAIRealtimeClickTarget?
    let responseAudioData: Data
    let duration: TimeInterval
}

struct OpenAIRealtimeCompanionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
final class OpenAIRealtimeCompanionClient {
    private let openAIClientSecretProxyURL: URL
    private let xAIClientSecretProxyURL: URL
    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var activeRealtimeSession: OpenAIRealtimeCompanionSession?

    init(openAIClientSecretProxyURL: String, xAIClientSecretProxyURL: String) {
        self.openAIClientSecretProxyURL = URL(string: openAIClientSecretProxyURL)!
        self.xAIClientSecretProxyURL = URL(string: xAIClientSecretProxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func startSession(
        modelProvider: RealtimeCompanionModelProvider,
        instructions: String
    ) async throws -> OpenAIRealtimeCompanionSession {
        print("🧩 \(modelProvider.voiceEngineDisplayName): starting session via \(clientSecretProxyURL(for: modelProvider).absoluteString)")
        let clientSecret = try await fetchRealtimeClientSecret(for: modelProvider)
        let realtimeSession = OpenAIRealtimeCompanionSession(
            clientSecret: clientSecret,
            modelProvider: modelProvider
        )
        try await realtimeSession.open(instructions: instructions)
        activeRealtimeSession = realtimeSession
        print("🧩 \(modelProvider.voiceEngineDisplayName): session ready")
        return realtimeSession
    }

    func playResponseAudio(_ responseAudioData: Data) throws {
        guard !responseAudioData.isEmpty else { return }

        let wavData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: responseAudioData,
            sampleRate: OpenAIRealtimeCompanionSession.audioSampleRate
        )
        let player = try AVAudioPlayer(data: wavData)
        audioPlayer = player
        player.play()
        print("🔊 Realtime voice: playing \(responseAudioData.count / 1024)KB PCM audio")
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    func stopPlayback() {
        if audioPlayer != nil || activeRealtimeSession != nil {
            print("🛑 Realtime voice: stopping playback/session")
        }
        audioPlayer?.stop()
        audioPlayer = nil
        activeRealtimeSession?.cancel()
        activeRealtimeSession = nil
    }

    private func fetchRealtimeClientSecret(for modelProvider: RealtimeCompanionModelProvider) async throws -> String {
        var request = URLRequest(url: clientSecretProxyURL(for: modelProvider))
        request.httpMethod = "POST"

        let requestStartedAt = Date()
        let (data, response) = try await session.data(for: request)
        let durationMilliseconds = Int(Date().timeIntervalSince(requestStartedAt) * 1000)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            print("❌ \(modelProvider.voiceEngineDisplayName): client secret fetch failed HTTP \(statusCode) in \(durationMilliseconds)ms: \(body)")
            throw OpenAIRealtimeCompanionError(
                message: "Failed to fetch \(modelProvider.voiceEngineDisplayName) client secret (HTTP \(statusCode)): \(body)"
            )
        }

        print("✅ \(modelProvider.voiceEngineDisplayName): client secret fetched HTTP \(httpResponse.statusCode) in \(durationMilliseconds)ms (\(data.count) bytes)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIRealtimeCompanionError(message: "Invalid \(modelProvider.voiceEngineDisplayName) client secret response.")
        }

        if let value = json["value"] as? String {
            return value
        }

        if let clientSecret = json["client_secret"] as? [String: Any],
           let value = clientSecret["value"] as? String {
            return value
        }

        throw OpenAIRealtimeCompanionError(message: "\(modelProvider.voiceEngineDisplayName) client secret response did not include a value.")
    }

    private func clientSecretProxyURL(for modelProvider: RealtimeCompanionModelProvider) -> URL {
        switch modelProvider {
        case .openAIRealtime2:
            return openAIClientSecretProxyURL
        case .grokVoiceThinkFast:
            return xAIClientSecretProxyURL
        }
    }
}

final class OpenAIRealtimeCompanionSession: @unchecked Sendable {
    static let audioSampleRate = 24_000

    private let clientSecret: String
    private let modelProvider: RealtimeCompanionModelProvider
    private let urlSession = URLSession(configuration: .default)
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.openai-realtime.send")
    private let stateQueue = DispatchQueue(label: "com.learningbuddy.openai-realtime.state")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(audioSampleRate))
    private let sessionLogID = String(UUID().uuidString.prefix(8))

    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionReadyContinuation: CheckedContinuation<Void, Error>?
    private var responseContinuation: CheckedContinuation<OpenAIRealtimeCompanionResult, Error>?
    private var hasResolvedSessionReadyContinuation = false
    private var hasResolvedResponseContinuation = false
    private var responseStartedAt: Date?
    private var accumulatedAssistantText = ""
    private var accumulatedUserTranscriptText = ""
    private var accumulatedResponseAudioData = Data()
    private var pendingPointTarget: OpenAIRealtimePointTarget?
    private var pendingClickTarget: OpenAIRealtimeClickTarget?
    private var sentAudioChunkCount = 0
    private var sentAudioByteCount = 0
    private var receivedAudioDeltaCount = 0
    private var receivedTextDeltaCount = 0

    init(clientSecret: String, modelProvider: RealtimeCompanionModelProvider) {
        self.clientSecret = clientSecret
        self.modelProvider = modelProvider
    }

    func open(instructions: String) async throws {
        print("🔌 \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: opening websocket \(modelProvider.websocketURL.absoluteString)")
        var request = URLRequest(url: modelProvider.websocketURL)
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: request)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.sessionReadyContinuation = continuation
                print("📤 \(self.modelProvider.voiceEngineDisplayName)[\(self.sessionLogID)]: sending session.update, instructions=\(instructions.count) chars")
                self.sendSessionUpdate(instructions: instructions)
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        appendPCM16AudioData(audioPCM16Data)
    }

    func appendPCM16AudioData(_ audioPCM16Data: Data) {
        guard !audioPCM16Data.isEmpty else { return }

        let base64Audio = audioPCM16Data.base64EncodedString()
        stateQueue.async {
            self.sentAudioChunkCount += 1
            self.sentAudioByteCount += audioPCM16Data.count
            if self.sentAudioChunkCount == 1 || self.sentAudioChunkCount % 50 == 0 {
                print("🎙️ \(self.modelProvider.voiceEngineDisplayName)[\(self.sessionLogID)]: sent mic audio chunks=\(self.sentAudioChunkCount), bytes=\(self.sentAudioByteCount)")
            }
        }

        sendJSONMessage([
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ])
    }

    func finishAndGenerateResponse(screenCaptures: [CompanionScreenCapture]) async throws -> OpenAIRealtimeCompanionResult {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.responseContinuation = continuation
                self.hasResolvedResponseContinuation = false
                self.responseStartedAt = Date()
                self.accumulatedAssistantText = ""
                self.accumulatedUserTranscriptText = ""
                self.accumulatedResponseAudioData = Data()
                self.pendingPointTarget = nil
                self.pendingClickTarget = nil

                print("📤 \(self.modelProvider.voiceEngineDisplayName)[\(self.sessionLogID)]: committing audio chunks=\(self.sentAudioChunkCount), bytes=\(self.sentAudioByteCount); attaching \(screenCaptures.count) screen(s)")
                self.sendJSONMessage(["type": "input_audio_buffer.commit"])
                self.sendScreenshotContext(screenCaptures: screenCaptures)
                print("📤 \(self.modelProvider.voiceEngineDisplayName)[\(self.sessionLogID)]: creating audio response")
                self.sendJSONMessage(self.makeResponseCreatePayload())
            }
        }
    }

    func cancel() {
        print("🛑 \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: cancelling session")
        stateQueue.async {
            self.resolveSessionReadyContinuationIfNeeded(
                with: OpenAIRealtimeCompanionError(message: "\(self.modelProvider.voiceEngineDisplayName) session was cancelled.")
            )
            self.resolveResponseContinuationIfNeeded(
                with: OpenAIRealtimeCompanionError(message: "\(self.modelProvider.voiceEngineDisplayName) response was cancelled.")
            )
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func sendSessionUpdate(instructions: String) {
        let session: [String: Any]

        switch modelProvider {
        case .openAIRealtime2:
            session = [
                "type": "realtime",
                "model": modelProvider.rawValue,
                "instructions": instructions,
                "output_modalities": ["audio"],
                "reasoning": [
                    "effort": "low"
                ],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Self.audioSampleRate
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ],
                        "turn_detection": NSNull()
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Self.audioSampleRate
                        ],
                        "voice": modelProvider.generatedVoiceName
                    ]
                ],
                "tools": Self.screenActionTools,
                "tool_choice": "auto"
            ]
        case .grokVoiceThinkFast:
            session = [
                "instructions": instructions,
                "voice": modelProvider.generatedVoiceName,
                "turn_detection": NSNull(),
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Self.audioSampleRate
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Self.audioSampleRate
                        ]
                    ]
                ],
                "tools": Self.screenActionTools,
                "tool_choice": "auto"
            ]
        }

        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": session
        ]

        sendJSONMessage(sessionUpdate)
    }

    private func makeResponseCreatePayload() -> [String: Any] {
        switch modelProvider {
        case .openAIRealtime2:
            return [
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"]
                ]
            ]
        case .grokVoiceThinkFast:
            return [
                "type": "response.create"
            ]
        }
    }

    private static let screenActionTools: [[String: Any]] = [
        [
            "type": "function",
            "name": "point_at_screen_element",
            "description": "Move Clicky's blue cursor to a useful screen element. Coordinates are in the screenshot pixel space with top-left origin.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "The x coordinate in screenshot pixels."
                    ],
                    "y": [
                        "type": "number",
                        "description": "The y coordinate in screenshot pixels."
                    ],
                    "label": [
                        "type": "string",
                        "description": "A short one to three word label for the target."
                    ],
                    "screen": [
                        "type": "integer",
                        "description": "The one-based screen number from the screenshot label."
                    ]
                ],
                "required": ["x", "y", "label"]
            ]
        ],
        [
            "type": "function",
            "name": "click_screen_element",
            "description": "Perform a single left click on a screen element only when the user explicitly asks Clicky to click it. Never use this for send, delete, purchase, destructive, or externally visible actions unless the user clearly and specifically asked for that exact action.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "The x coordinate in screenshot pixels."
                    ],
                    "y": [
                        "type": "number",
                        "description": "The y coordinate in screenshot pixels."
                    ],
                    "label": [
                        "type": "string",
                        "description": "A short one to three word label for the target."
                    ],
                    "screen": [
                        "type": "integer",
                        "description": "The one-based screen number from the screenshot label."
                    ]
                ],
                "required": ["x", "y", "label"]
            ]
        ]
    ]

    private func sendScreenshotContext(screenCaptures: [CompanionScreenCapture]) {
        let screenSummary = screenCaptures.enumerated().map { index, capture in
            let cursorMarker = capture.isCursorScreen ? " cursor" : ""
            return "screen\(index + 1)=\(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels)\(cursorMarker)"
        }.joined(separator: ", ")
        print("🖼️ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: screenshot context \(screenSummary)")

        let screenContextIntro = modelProvider.supportsScreenshotImages
            ? "Here are the user's current screens. Use these image dimensions as the coordinate space for point_at_screen_element and click_screen_element. Origin is top-left, x increases right, y increases down."
            : "Here is the user's current text screen context. Use the listed image dimensions and known clickable/accessibility element centers as the coordinate space for point_at_screen_element and click_screen_element. Origin is top-left, x increases right, y increases down."

        var contentBlocks: [[String: Any]] = [
            [
                "type": "input_text",
                "text": screenContextIntro
            ]
        ]

        for capture in screenCaptures {
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            contentBlocks.append([
                "type": "input_text",
                "text": capture.label + dimensionInfo
            ])
            if !capture.elementCandidates.isEmpty {
                let candidateSummary = capture.elementCandidates
                    .prefix(40)
                    .map { candidate in
                        "\(candidate.label) [\(candidate.role)] center=(\(candidate.centerXInScreenshotPixels),\(candidate.centerYInScreenshotPixels))"
                    }
                    .joined(separator: "; ")
                contentBlocks.append([
                    "type": "input_text",
                    "text": "Known clickable/accessibility element centers for this screen. Prefer these exact centers for matching controls: \(candidateSummary)"
                ])
            }
            if modelProvider.supportsScreenshotImages {
                contentBlocks.append([
                    "type": "input_image",
                    "image_url": "data:image/jpeg;base64,\(capture.imageData.base64EncodedString())"
                ])
            }
        }

        sendJSONMessage([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": contentBlocks
            ]
        ])
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleWebSocketMessage(message)
                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?

        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            data = nil
        }

        guard let data,
              let eventPayload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = eventPayload["type"] as? String else {
            return
        }

        stateQueue.async {
            self.handleEventPayload(eventPayload, eventType: eventType)
        }
    }

    private func handleEventPayload(_ eventPayload: [String: Any], eventType: String) {
        switch eventType {
        case "session.updated":
            print("✅ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: session.updated")
            resolveSessionReadyContinuationIfNeeded()
        case "response.output_audio.delta", "response.audio.delta":
            appendAudioDelta(from: eventPayload)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta", "response.text.delta":
            appendTextDelta(from: eventPayload)
        case "response.output_audio_transcript.done", "response.output_text.done":
            replaceTextIfDoneEventIncludesFinalText(eventPayload)
        case "conversation.item.input_audio_transcription.completed":
            updateUserTranscript(from: eventPayload)
        case "response.function_call_arguments.done":
            captureScreenActionToolCall(from: eventPayload)
        case "response.done":
            finishResponse(from: eventPayload)
        case "error":
            print("❌ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: error event \(Self.safeJSONString(eventPayload))")
            failSession(with: errorFromEvent(eventPayload))
        default:
            break
        }
    }

    private func appendAudioDelta(from eventPayload: [String: Any]) {
        guard let base64Audio = eventPayload["delta"] as? String,
              let audioData = Data(base64Encoded: base64Audio) else {
            return
        }

        accumulatedResponseAudioData.append(audioData)
        receivedAudioDeltaCount += 1
        if receivedAudioDeltaCount == 1 || receivedAudioDeltaCount % 25 == 0 {
            print("🔊 \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: received audio deltas=\(receivedAudioDeltaCount), bytes=\(accumulatedResponseAudioData.count)")
        }
    }

    private func appendTextDelta(from eventPayload: [String: Any]) {
        guard let textDelta = eventPayload["delta"] as? String else {
            return
        }

        accumulatedAssistantText += textDelta
        receivedTextDeltaCount += 1
        if receivedTextDeltaCount == 1 || receivedTextDeltaCount % 20 == 0 {
            print("💬 \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: received text deltas=\(receivedTextDeltaCount), chars=\(accumulatedAssistantText.count)")
        }
    }

    private func replaceTextIfDoneEventIncludesFinalText(_ eventPayload: [String: Any]) {
        if let finalTranscript = eventPayload["transcript"] as? String,
           !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accumulatedAssistantText = finalTranscript
            return
        }

        if let finalText = eventPayload["text"] as? String,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accumulatedAssistantText = finalText
        }
    }

    private func updateUserTranscript(from eventPayload: [String: Any]) {
        if let transcript = eventPayload["transcript"] as? String {
            accumulatedUserTranscriptText = transcript
            print("🗣️ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: input transcript=\"\(Self.truncatedForLog(transcript))\"")
        }
    }

    private func captureScreenActionToolCall(from eventPayload: [String: Any]) {
        guard let toolName = eventPayload["name"] as? String,
              let arguments = eventPayload["arguments"] as? String,
              let screenTarget = Self.extractScreenTarget(fromArguments: arguments) else {
            return
        }

        switch toolName {
        case "point_at_screen_element":
            pendingPointTarget = OpenAIRealtimePointTarget(
                x: screenTarget.x,
                y: screenTarget.y,
                label: screenTarget.label,
                screenNumber: screenTarget.screenNumber
            )
            print("🎯 \(modelProvider.voiceEngineDisplayName): function call point_at_screen_element x=\(Int(screenTarget.x)), y=\(Int(screenTarget.y)), label=\(screenTarget.label ?? "unknown"), screen=\(screenTarget.screenNumber.map(String.init) ?? "cursor")")
        case "click_screen_element":
            pendingClickTarget = OpenAIRealtimeClickTarget(
                x: screenTarget.x,
                y: screenTarget.y,
                label: screenTarget.label,
                screenNumber: screenTarget.screenNumber
            )
            print("🖱️ \(modelProvider.voiceEngineDisplayName): function call click_screen_element x=\(Int(screenTarget.x)), y=\(Int(screenTarget.y)), label=\(screenTarget.label ?? "unknown"), screen=\(screenTarget.screenNumber.map(String.init) ?? "cursor")")
        default:
            break
        }
    }

    private func finishResponse(from eventPayload: [String: Any]) {
        if let response = eventPayload["response"] as? [String: Any] {
            let responseStatus = response["status"] as? String ?? "unknown"
            let finalTextFromResponse = Self.extractAssistantText(fromResponse: response)
            if !finalTextFromResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accumulatedAssistantText = finalTextFromResponse
            }

            if pendingPointTarget == nil {
                pendingPointTarget = Self.extractPointTarget(fromResponse: response)
            }
            if pendingClickTarget == nil {
                pendingClickTarget = Self.extractClickTarget(fromResponse: response)
            }

            print("✅ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: response.done status=\(responseStatus), textChars=\(accumulatedAssistantText.count), audioBytes=\(accumulatedResponseAudioData.count), pointTarget=\(pendingPointTarget != nil), clickTarget=\(pendingClickTarget != nil)")

            if responseStatus == "cancelled",
               accumulatedAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               accumulatedResponseAudioData.isEmpty,
               pendingPointTarget == nil,
               pendingClickTarget == nil {
                print("↪️ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: ignoring empty cancelled response.done while waiting for real response")
                return
            }
        }

        let duration = Date().timeIntervalSince(responseStartedAt ?? Date())
        let result = OpenAIRealtimeCompanionResult(
            assistantResponseText: accumulatedAssistantText,
            userTranscriptText: accumulatedUserTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : accumulatedUserTranscriptText,
            pointTarget: pendingPointTarget,
            clickTarget: pendingClickTarget,
            responseAudioData: accumulatedResponseAudioData,
            duration: duration
        )

        resolveResponseContinuationIfNeeded(with: result)
    }

    private func failSession(with error: Error) {
        print("❌ \(modelProvider.voiceEngineDisplayName)[\(sessionLogID)]: session failed: \(error.localizedDescription)")
        stateQueue.async {
            self.resolveSessionReadyContinuationIfNeeded(with: error)
            self.resolveResponseContinuationIfNeeded(with: error)
        }
    }

    private func resolveSessionReadyContinuationIfNeeded(with error: Error? = nil) {
        guard !hasResolvedSessionReadyContinuation,
              let sessionReadyContinuation else {
            return
        }

        hasResolvedSessionReadyContinuation = true
        self.sessionReadyContinuation = nil

        if let error {
            sessionReadyContinuation.resume(throwing: error)
        } else {
            sessionReadyContinuation.resume()
        }
    }

    private func resolveResponseContinuationIfNeeded(with result: OpenAIRealtimeCompanionResult) {
        guard !hasResolvedResponseContinuation,
              let responseContinuation else {
            return
        }

        hasResolvedResponseContinuation = true
        self.responseContinuation = nil
        responseContinuation.resume(returning: result)
    }

    private func resolveResponseContinuationIfNeeded(with error: Error) {
        guard !hasResolvedResponseContinuation,
              let responseContinuation else {
            return
        }

        hasResolvedResponseContinuation = true
        self.responseContinuation = nil
        responseContinuation.resume(throwing: error)
    }

    private func errorFromEvent(_ eventPayload: [String: Any]) -> Error {
        if let error = eventPayload["error"] as? [String: Any] {
            let message = error["message"] as? String
                ?? error["code"] as? String
                ?? "\(modelProvider.voiceEngineDisplayName) API returned an error."
            return OpenAIRealtimeCompanionError(message: message)
        }

        return OpenAIRealtimeCompanionError(message: "\(modelProvider.voiceEngineDisplayName) API returned an error.")
    }

    private static func extractAssistantText(fromResponse response: [String: Any]) -> String {
        guard let outputItems = response["output"] as? [[String: Any]] else {
            return ""
        }

        var textParts: [String] = []

        for outputItem in outputItems {
            guard let contentItems = outputItem["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in contentItems {
                if let transcript = contentItem["transcript"] as? String {
                    textParts.append(transcript)
                } else if let text = contentItem["text"] as? String {
                    textParts.append(text)
                }
            }
        }

        return textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractPointTarget(fromResponse response: [String: Any]) -> OpenAIRealtimePointTarget? {
        guard let screenTarget = extractScreenTarget(fromResponse: response, toolName: "point_at_screen_element") else {
            return nil
        }

        let pointTarget = OpenAIRealtimePointTarget(
            x: screenTarget.x,
            y: screenTarget.y,
            label: screenTarget.label,
            screenNumber: screenTarget.screenNumber
        )
        print("🎯 Realtime voice: function call point_at_screen_element x=\(Int(pointTarget.x)), y=\(Int(pointTarget.y)), label=\(pointTarget.label ?? "unknown"), screen=\(pointTarget.screenNumber.map(String.init) ?? "cursor")")
        return pointTarget
    }

    private static func extractClickTarget(fromResponse response: [String: Any]) -> OpenAIRealtimeClickTarget? {
        guard let screenTarget = extractScreenTarget(fromResponse: response, toolName: "click_screen_element") else {
            return nil
        }

        let clickTarget = OpenAIRealtimeClickTarget(
            x: screenTarget.x,
            y: screenTarget.y,
            label: screenTarget.label,
            screenNumber: screenTarget.screenNumber
        )
        print("🖱️ Realtime voice: function call click_screen_element x=\(Int(clickTarget.x)), y=\(Int(clickTarget.y)), label=\(clickTarget.label ?? "unknown"), screen=\(clickTarget.screenNumber.map(String.init) ?? "cursor")")
        return clickTarget
    }

    private struct ExtractedScreenTarget {
        let x: CGFloat
        let y: CGFloat
        let label: String?
        let screenNumber: Int?
    }

    private static func extractScreenTarget(
        fromResponse response: [String: Any],
        toolName: String
    ) -> ExtractedScreenTarget? {
        guard let outputItems = response["output"] as? [[String: Any]] else {
            return nil
        }

        for outputItem in outputItems {
            let outputType = outputItem["type"] as? String
            let outputName = outputItem["name"] as? String

            guard outputType == "function_call",
                  outputName == toolName,
                  let arguments = outputItem["arguments"] as? String,
                  let screenTarget = extractScreenTarget(fromArguments: arguments) else {
                continue
            }

            return screenTarget
        }

        return nil
    }

    private static func extractScreenTarget(fromArguments arguments: String) -> ExtractedScreenTarget? {
        guard let argumentData = arguments.data(using: .utf8),
              let argumentJSON = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
              let x = numberValue(named: "x", in: argumentJSON),
              let y = numberValue(named: "y", in: argumentJSON) else {
            return nil
        }

        return ExtractedScreenTarget(
            x: CGFloat(x),
            y: CGFloat(y),
            label: argumentJSON["label"] as? String,
            screenNumber: integerValue(named: "screen", in: argumentJSON)
        )
    }

    private static func numberValue(named key: String, in json: [String: Any]) -> Double? {
        if let value = json[key] as? Double {
            return value
        }

        if let value = json[key] as? Int {
            return Double(value)
        }

        if let value = json[key] as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private static func integerValue(named key: String, in json: [String: Any]) -> Int? {
        if let value = json[key] as? Int {
            return value
        }

        if let value = json[key] as? NSNumber {
            return value.intValue
        }

        return nil
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

    private static func safeJSONString(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: payload)
        }

        return truncatedForLog(text, limit: 700)
    }
}
