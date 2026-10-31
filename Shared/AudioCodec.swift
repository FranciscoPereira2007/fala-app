import Foundation
import AVFoundation

/// Áudio comprimido para redes móveis: AAC 16 kHz mono (~24 kbit/s, ~10x menos do que PCM).
/// Ficheiro .m4a em memória: o iPhone codifica, o Mac descodifica com o AVFoundation.
enum AudioCodec {
    static func encodeAAC(_ samples: [Float]) -> Data? {
        guard !samples.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 24000]
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try f.write(from: buf)
        } catch { return nil } // o ficheiro fecha ao sair do do-bloco
        return try? Data(contentsOf: url)
    }

    static func decode(_ data: Data) -> [Float]? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let f = try? AVAudioFile(forReading: url),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: inBuf)) != nil else { return nil }
        if f.processingFormat.sampleRate == 16000, f.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
        }
        guard let conv = AVAudioConverter(from: f.processingFormat, to: out),
              let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / f.processingFormat.sampleRate) + 1024) else { return nil }
        var fed = false
        conv.convert(to: o, error: nil) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true; st.pointee = .haveData; return inBuf
        }
        return Array(UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
    }
}
