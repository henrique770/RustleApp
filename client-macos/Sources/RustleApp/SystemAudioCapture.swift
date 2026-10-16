import AVFoundation
import CoreAudio

/// Records what the Mac is playing (the other people on a call), the way Wispr Flow's Notetaker
/// does on macOS 14.4+: Chromium's "MacCatapSystemAudioLoopbackCapture", i.e. a Core Audio
/// process tap (CATapDescription + AudioHardwareCreateProcessTap) read through a private
/// aggregate device. Needs the "System Audio Recording" permission (kTCCServiceAudioCapture),
/// which macOS asks for the first time the tap starts.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self { case .coreAudio(let step, let status): return "\(step) falhou (\(status))" }
        }
    }

    /// Converted 16 kHz mono PCM16 chunks, delivered on a private queue.
    var onPCM: ((Data) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "rustle.system-audio", qos: .userInitiated)
    private var converter: PCM16Converter?

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "RustleApp Notetaker"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Criar tap de áudio")
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Ler formato do tap")
        guard let tapFormat = AVAudioFormat(streamDescription: &format) else {
            throw CaptureError.coreAudio("Formato do tap", -1)
        }
        converter = PCM16Converter(from: tapFormat)

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RustleApp Notetaker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Criar dispositivo agregado")
        aggregateID = agg

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let converter = self.converter,
                  let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                  let pcm = converter.convert(buffer) else { return }
            self.onPCM?(pcm)
        }, "Criar IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "Iniciar captura")
        Log.info("system audio tap started (\(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch)")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            stop()
            throw CaptureError.coreAudio(step, status)
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw CaptureError.coreAudio("Saída de áudio padrão", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw CaptureError.coreAudio("UID da saída de áudio", status)
        }
        return value as String
    }
}

/// Converts any PCM buffer to 16 kHz mono PCM16, the format rustle-server expects.
final class PCM16Converter {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter?
    /// Voice-processed mic input arrives as 3+ identical channels with no channel layout, which
    /// AVAudioConverter downmixes to silence; for those, channel 0 is copied into a mono buffer first.
    private let mono: AVAudioFormat?

    init(from format: AVAudioFormat) {
        if format.channelCount > 2, format.commonFormat == .pcmFormatFloat32 {
            mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
            converter = mono.flatMap { AVAudioConverter(from: $0, to: Self.target) }
        } else {
            mono = nil
            converter = AVAudioConverter(from: format, to: Self.target)
        }
    }

    var isValid: Bool { converter != nil }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter, buffer.frameLength > 0 else { return nil }
        var source = buffer
        if let mono {
            guard let src = buffer.floatChannelData,
                  let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let dst = m.floatChannelData else { return nil }
            m.frameLength = buffer.frameLength
            // Deinterleaved: channel 0 is contiguous. Interleaved: take every Nth sample.
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<Int(buffer.frameLength) { dst[0][i] = src[0][i * stride] }
            source = m
        }
        let ratio = Self.target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }
}
