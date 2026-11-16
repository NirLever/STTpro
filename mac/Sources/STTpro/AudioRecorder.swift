import AVFoundation
import CoreAudio
import STTproCore

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio input-device enumeration (for the microphone picker).
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> AudioInputDevice? { inputs().first { $0.uid == uid } }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Records the selected microphone to a 16 kHz mono 16-bit WAV (the format the
/// Windows app sends) and reports a live input level for the recording pill.
/// A fresh engine is used per recording, so the macOS mic indicator is only
/// on while you dictate.
@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var sink: Sink?
    private var startedAt: Date?

    /// Peak-ish level 0…1, delivered on the main thread ~20×/s.
    var onLevel: ((Float) -> Void)?

    var isRecording: Bool { engine?.isRunning ?? false }

    /// Owns the file + converter; touched only from the audio tap thread
    /// until the tap is removed.
    private final class Sink: @unchecked Sendable {
        let url: URL
        let file: AVAudioFile
        let converter: AVAudioConverter
        let outFormat: AVAudioFormat
        let inRate: Double
        var lastLevelPost = Date.distantPast
        private let lock = NSLock()
        private var closed = false

        /// Finalizes the WAV header; later tap callbacks are ignored.
        func close() {
            lock.lock(); defer { lock.unlock() }
            closed = true
            if #available(macOS 15.0, *) { file.close() }
        }

        init(url: URL, inFormat: AVAudioFormat) throws {
            self.url = url
            outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "STTpro.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format."])
            }
            conv.downmix = true
            converter = conv
            inRate = inFormat.sampleRate
            file = try AVAudioFile(forWriting: url, settings: outFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }

        func write(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inRate + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { try? file.write(from: out) }
        }

        static func level(_ buffer: AVAudioPCMBuffer) -> Float {
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            return min(1, (sum / Float(n)).squareRoot() * 1.8)
        }
    }

    func prewarm() {}

    func start(deviceUID: String?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, let device = AudioDevices.device(uid: uid), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("Couldn't select microphone \(device.name) (\(status)); using default") }
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "STTpro.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sttpro-\(UUID().uuidString).wav")
        let sink = try Sink(url: url, inFormat: inFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            sink.write(buffer)
            let now = Date()
            guard now.timeIntervalSince(sink.lastLevelPost) > 0.045 else { return }
            sink.lastLevelPost = now
            let level = Sink.level(buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLevel?(level) } }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.engine = engine
        self.sink = sink
        startedAt = Date()
    }

    /// Stops and returns the WAV file and its duration in seconds.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let engine, let sink else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.close()
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        self.engine = nil
        self.sink = nil   // closes the WAV file
        return (sink.url, duration)
    }

    func cancel() {
        guard let result = stop() else { return }
        try? FileManager.default.removeItem(at: result.url)
    }
}
