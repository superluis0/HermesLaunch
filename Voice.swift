import SwiftUI
import AVFoundation
import FluidAudio

// MARK: - Voice engine (fully local, on-device)
//
// Push-to-talk dictation (FluidAudio Parakeet ASR) + spoken replies (FluidAudio
// Kokoro TTS), all on the Apple Neural Engine — no cloud, no API key. Models load
// lazily on first use. State is published for UI; @Published mutations are hopped
// to the main thread (matching the codebase's DispatchQueue style rather than
// adopting @MainActor, since the package builds in the Swift 5 language mode).

final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    enum Status: Equatable {
        case idle, loadingModel, ready, recording, transcribing, speaking
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var level: Float = 0          // 0…1 mic level for UI

    private var asr: AsrManager?
    private var tts: KokoroAneManager?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var captured: [Float] = []
    private let captureQueue = DispatchQueue(label: "ai.hermes.voice.capture")
    private var player: AVAudioPlayer?
    private var speakGeneration = 0

    private init() {}

    var isAvailable: Bool { if case .error = status { return false } else { return true } }

    // MARK: State helpers (always on main)

    private func set(_ s: Status) { DispatchQueue.main.async { self.status = s } }
    private func setLevel(_ l: Float) { DispatchQueue.main.async { self.level = l } }

    // MARK: Model loading

    /// Warm the ASR model ahead of first use (optional).
    func preload() { Task { await ensureASR() } }

    @discardableResult
    private func ensureASR() async -> Bool {
        if asr != nil { return true }
        set(.loadingModel)
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)   // English-only, best long-form recall
            asr = AsrManager(config: .default, models: models)
            set(.ready)
            return true
        } catch {
            set(.error("ASR model failed to load: \(error.localizedDescription)"))
            return false
        }
    }

    private func ensureTTS() async -> Bool {
        if tts != nil { return true }
        do {
            let manager = KokoroAneManager()
            try await manager.initialize()
            tts = manager
            return true
        } catch {
            return false   // TTS is optional; dictation still works
        }
    }

    // MARK: Microphone permission

    private func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }

    // MARK: Push-to-talk dictation

    func startDictation() {
        if case .recording = status { return }
        Task {
            guard await requestMic() else { set(.error("Microphone access denied")); return }
            guard await ensureASR() else { return }
            do {
                try beginCapture()
                set(.recording)
            } catch {
                set(.error("Could not start mic: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops recording and returns the transcript via `completion` (on main).
    func stopDictation(_ completion: @escaping (String) -> Void) {
        guard case .recording = status else { return }
        endCapture()
        let samples = captureQueue.sync { let s = captured; captured = []; return s }
        guard !samples.isEmpty, let asr else { set(.ready); return }
        set(.transcribing)
        Task {
            do {
                var decoderState = try TdtDecoderState()
                let result = try await asr.transcribe(samples, decoderState: &decoderState)
                set(.ready)
                let text = result.text
                DispatchQueue.main.async { completion(text) }
            } catch {
                set(.error("Transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    func cancelDictation() {
        if case .recording = status { endCapture(); captureQueue.sync { captured = [] }; set(.ready) }
    }

    private func beginCapture() throws {
        captureQueue.sync { captured.removeAll() }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "voice", code: 1)
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
    }

    private func append(_ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        var peak: Float = 0
        captureQueue.sync {
            captured.reserveCapacity(captured.count + n)
            for i in 0..<n { let v = ch[i]; captured.append(v); peak = max(peak, abs(v)) }
        }
        setLevel(min(1, peak * 1.4))
    }

    private func endCapture() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        converter = nil
        setLevel(0)
    }

    // MARK: Spoken replies (TTS)

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = speakGeneration
        Task {
            guard await ensureTTS(), let tts else { return }
            do {
                let wav = try await tts.synthesize(text: trimmed)
                DispatchQueue.main.async {
                    // Drop the result if speaking was cancelled while we synthesized.
                    guard self.speakGeneration == generation else { return }
                    do {
                        let p = try AVAudioPlayer(data: wav)
                        self.player = p
                        p.play()
                    } catch { /* playback best-effort */ }
                }
            } catch { /* synthesis best-effort */ }
        }
    }

    func stopSpeaking() { speakGeneration += 1; player?.stop(); player = nil }
}
