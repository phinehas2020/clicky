//
//  OpenAIRealtimeMicrophoneAudioRouter.swift
//  leanring-buddy
//
//  Buffers microphone audio immediately on push-to-talk so the user can start
//  speaking while the OpenAI Realtime websocket is still connecting.
//

import AVFoundation
import Foundation

final class OpenAIRealtimeMicrophoneAudioRouter: @unchecked Sendable {
    private static let maximumBufferedAudioChunkCount = 900

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.openai-realtime.microphone-audio-router")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(OpenAIRealtimeCompanionSession.audioSampleRate)
    )

    private var activeRealtimeSession: OpenAIRealtimeCompanionSession?
    private var bufferedAudioChunks: [Data] = []
    private var bufferedAudioByteCount = 0
    private var droppedAudioChunkCount = 0

    func beginBuffering() {
        stateQueue.async {
            self.activeRealtimeSession = nil
            self.bufferedAudioChunks.removeAll(keepingCapacity: true)
            self.bufferedAudioByteCount = 0
            self.droppedAudioChunkCount = 0
            print("🎙️ OpenAI Realtime: microphone router buffering started")
        }
    }

    func attachRealtimeSessionAndFlush(_ realtimeSession: OpenAIRealtimeCompanionSession) {
        stateQueue.async {
            self.activeRealtimeSession = realtimeSession

            let chunksToFlush = self.bufferedAudioChunks
            let bytesToFlush = self.bufferedAudioByteCount
            self.bufferedAudioChunks.removeAll(keepingCapacity: true)
            self.bufferedAudioByteCount = 0

            print("🎙️ OpenAI Realtime: flushing buffered mic audio chunks=\(chunksToFlush.count), bytes=\(bytesToFlush), dropped=\(self.droppedAudioChunkCount)")

            for audioChunk in chunksToFlush {
                realtimeSession.appendPCM16AudioData(audioChunk)
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            if let activeRealtimeSession = self.activeRealtimeSession {
                activeRealtimeSession.appendPCM16AudioData(audioPCM16Data)
                return
            }

            if self.bufferedAudioChunks.count >= Self.maximumBufferedAudioChunkCount {
                self.bufferedAudioChunks.removeFirst()
                self.droppedAudioChunkCount += 1
            }

            self.bufferedAudioChunks.append(audioPCM16Data)
            self.bufferedAudioByteCount += audioPCM16Data.count

            if self.bufferedAudioChunks.count == 1 || self.bufferedAudioChunks.count % 50 == 0 {
                print("🎙️ OpenAI Realtime: buffered mic audio chunks=\(self.bufferedAudioChunks.count), bytes=\(self.bufferedAudioByteCount)")
            }
        }
    }

    func reset() {
        stateQueue.async {
            if self.activeRealtimeSession != nil
                || !self.bufferedAudioChunks.isEmpty
                || self.droppedAudioChunkCount > 0 {
                print("🎙️ OpenAI Realtime: microphone router reset, bufferedChunks=\(self.bufferedAudioChunks.count), dropped=\(self.droppedAudioChunkCount)")
            }

            self.activeRealtimeSession = nil
            self.bufferedAudioChunks.removeAll(keepingCapacity: true)
            self.bufferedAudioByteCount = 0
            self.droppedAudioChunkCount = 0
        }
    }
}
