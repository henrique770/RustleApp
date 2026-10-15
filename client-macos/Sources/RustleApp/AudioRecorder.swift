import AVFoundation

/// Captures the default mic and converts to 16 kHz mono PCM16, the format Wispr Flow
/// feeds its transcription stream (observed: 16e3 sample rate, Int16 packing in index.js).
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()
    private(set) var lastDurationSeconds: Double = 0
    /// Called on the audio thread with the RMS of each input buffer (drives the overlay waveform).
    var onLevel: ((Float) -> Void)?

    func start() throws {
        lock.lock(); pcm.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "RustleApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input device"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
            self?.reportLevel(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns a complete WAV file.
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let samples = pcm; lock.unlock()
        lastDurationSeconds = Double(samples.count) / 2.0 / 16_000.0
        return Self.wav(pcm16: samples, sampleRate: 16_000)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.lock(); pcm.append(bytes); lock.unlock()
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        onLevel((sum / Float(n)).squareRoot())
    }

    static func wav(pcm16: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm16.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}
