import AVFoundation
import STTproCore

/// Records 16 kHz mono 16-bit PCM WAV (same format the Windows app sends) to a
/// temp file. The microphone is only open while recording, so the macOS
/// orange mic indicator shows only while you hold the hotkey.
@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var prepared: AVAudioRecorder?

    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    var isRecording: Bool { recorder?.isRecording ?? false }

    private func makeRecorder() throws -> AVAudioRecorder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttpro-\(UUID().uuidString).wav")
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.prepareToRecord()
        return r
    }

    /// Creates the next recorder ahead of time to cut start-up latency.
    func prewarm() {
        guard prepared == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        prepared = try? makeRecorder()
    }

    func start() throws {
        let r = try prepared ?? makeRecorder()
        prepared = nil
        guard r.record() else {
            r.deleteRecording()
            throw NSError(domain: "STTpro.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the microphone."])
        }
        recorder = r
    }

    /// Stops and returns the WAV file and its duration in seconds.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let r = recorder else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        prewarm()
        return (r.url, duration)
    }

    func cancel() {
        guard let r = recorder else { return }
        r.stop()
        r.deleteRecording()
        recorder = nil
    }
}
