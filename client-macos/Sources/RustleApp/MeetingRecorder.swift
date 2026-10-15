import AVFoundation
import Foundation

/// Notetaker capture: the microphone ("Você") and the system audio ("Outros") are recorded as two
/// separate streams, as in Wispr Flow (one getUserMedia mic graph + one getDisplayMedia loopback
/// graph), so every line of the transcript knows who said it without diarization.
///
/// Each stream is cut into chunks at natural pauses (6–25 s) and sent to rustle-server's
/// /v1/transcribe one at a time; segments come back with timestamps relative to the meeting start.
/// Wispr streams audio over gRPC instead; chunking keeps this version simple and local.
@MainActor
final class MeetingRecorder {
    var onSegments: (([Meeting.Segment]) -> Void)?
    /// Mic and system levels (0…1 RMS) for the live waveform.
    var onLevels: ((Float, Float) -> Void)?

    private(set) var isRecording = false
    private(set) var systemAudioError: String?

    private let client: NotetakerClient
    private let micEngine = AVAudioEngine()
    private var system: AnyObject?
    private let buffers = Buffers()
    private var timer: Timer?
    private var queue: Task<Void, Never>?
    private var language = "pt"
    private var micLevel: Float = 0
    private var sysLevel: Float = 0

    nonisolated static let rate = 16_000.0
    nonisolated static let minChunk = 6.0
    nonisolated static let maxChunk = 25.0
    nonisolated static let pauseWindow = 0.7

    /// Buffered PCM16 per speaker, filled from audio threads and drained on the main actor.
    private final class Buffers: @unchecked Sendable {
        struct Stream {
            let speaker: Meeting.Speaker
            let silence: Float
            var pcm = Data()
            var consumedSamples = 0
        }
        struct Chunk { let pcm: Data; let offset: Double; let speaker: Meeting.Speaker; let silence: Float }

        private let lock = NSLock()
        private var mic = Stream(speaker: .you, silence: 0.010)
        private var sys = Stream(speaker: .them, silence: 0.004)

        func reset() {
            lock.lock(); defer { lock.unlock() }
            mic = Stream(speaker: .you, silence: 0.010)
            sys = Stream(speaker: .them, silence: 0.004)
        }

        func append(_ pcm: Data, mic toMic: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toMic { mic.pcm.append(pcm) } else { sys.pcm.append(pcm) }
        }

        /// Cuts a chunk at a pause (or at the max length); `final` takes whatever is left.
        func take(mic fromMic: Bool, final: Bool) -> Chunk? {
            lock.lock(); defer { lock.unlock() }
            var stream = fromMic ? mic : sys
            let seconds = Double(stream.pcm.count) / 2 / MeetingRecorder.rate
            let tail = stream.pcm.suffix(Int(MeetingRecorder.pauseWindow * MeetingRecorder.rate) * 2)
            let atPause = MeetingRecorder.rms(Data(tail)) < stream.silence
            let ready = final ? seconds > 0.5
                : seconds >= MeetingRecorder.maxChunk || (seconds >= MeetingRecorder.minChunk && atPause)
            guard ready else { return nil }
            let chunk = Chunk(pcm: stream.pcm, offset: Double(stream.consumedSamples) / MeetingRecorder.rate,
                              speaker: stream.speaker, silence: stream.silence)
            stream.consumedSamples += stream.pcm.count / 2
            stream.pcm.removeAll(keepingCapacity: true)
            if fromMic { mic = stream } else { sys = stream }
            return chunk
        }
    }

    init(client: NotetakerClient) { self.client = client }

    func start(language: String) throws {
        guard !isRecording else { return }
        self.language = language
        buffers.reset()

        let input = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "RustleApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nenhum microfone disponível"])
        }
        let micConverter = PCM16Converter(from: format)
        input.removeTap(onBus: 0)
        let buffers = buffers
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let pcm = micConverter.convert(buffer) else { return }
            buffers.append(pcm, mic: true)
            self?.report(level: Self.rms(pcm), mic: true)
        }
        micEngine.prepare()
        try micEngine.start()

        systemAudioError = nil
        if #available(macOS 14.2, *) {
            let capture = SystemAudioCapture()
            capture.onPCM = { [weak self] pcm in
                buffers.append(pcm, mic: false)
                self?.report(level: Self.rms(pcm), mic: false)
            }
            do {
                try capture.start()
                system = capture
            } catch {
                systemAudioError = error.localizedDescription
                Log.info("system audio unavailable: \(error.localizedDescription)")
            }
        } else {
            systemAudioError = "Requer macOS 14.2 ou mais recente"
        }

        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Log.info("meeting recording started (system audio: \(systemAudioError ?? "ok"))")
    }

    /// Stops capture, transcribes what is left and waits until every chunk is done.
    func stop() async {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        if #available(macOS 14.2, *) { (system as? SystemAudioCapture)?.stop() }
        system = nil
        flush(mic: true, final: true)
        flush(mic: false, final: true)
        await queue?.value
        Log.info("meeting recording stopped")
    }

    // MARK: - Buffering (audio threads)

    nonisolated private func report(level: Float, mic toMic: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if toMic { self.micLevel = level } else { self.sysLevel = level }
            self.onLevels?(self.micLevel, self.sysLevel)
        }
    }

    // MARK: - Chunking

    private func tick() {
        flush(mic: true, final: false)
        flush(mic: false, final: false)
    }

    /// Queues the next chunk of one stream for transcription.
    private func flush(mic: Bool, final: Bool) {
        guard let chunk = buffers.take(mic: mic, final: final) else { return }
        // Skip silent chunks: nobody spoke on this side.
        guard Self.rms(chunk.pcm) >= chunk.silence * 0.6 else { return }
        enqueue(chunk.pcm, offset: chunk.offset, speaker: chunk.speaker)
    }

    private func enqueue(_ pcm: Data, offset: Double, speaker: Meeting.Speaker) {
        let previous = queue
        let client = client
        let language = language
        queue = Task { [weak self] in
            await previous?.value
            let wav = AudioRecorder.wav(pcm16: pcm, sampleRate: Int(Self.rate))
            do {
                let parts = try await client.transcribe(wav: wav, language: language)
                let segments = parts.map {
                    Meeting.Segment(speaker: speaker, start: offset + $0.start, end: offset + $0.end, text: $0.text)
                }
                if !segments.isEmpty { self?.onSegments?(segments) }
            } catch {
                Log.info("meeting chunk failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func rms(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples { let f = Float(s) / 32768; sum += f * f }
        }
        return (sum / Float(count)).squareRoot()
    }
}
