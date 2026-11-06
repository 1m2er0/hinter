import AVFoundation
import ScreenCaptureKit

/// System audio (= interviewer) and microphone (= candidate) via one ScreenCaptureKit stream; no video, nothing written to disk.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "hh.audio")
    private var onSystem: ((AVAudioPCMBuffer) -> Void)?
    private var onMic: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    func start(onSystem: @escaping (AVAudioPCMBuffer) -> Void, onMic: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.onSystem = onSystem
        self.onMic = onMic
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2 // SCK requires a video config; keep it negligible
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let buf = Self.pcm(sb) else { return }
        switch type {
        case .audio: onSystem?(buf)
        case .microphone: onMic?(buf)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }

    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sb.formatDescription, let asbd = desc.audioStreamBasicDescription else { return nil }
        var a = asbd
        guard let fmt = AVAudioFormat(streamDescription: &a) else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}
