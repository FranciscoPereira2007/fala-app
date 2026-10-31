import Foundation
import Network
import CryptoKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

/// Ecrã do Mac ao vivo no iPhone (como o Parsec / opendisplay): SCStream -> H.264 no chip (VideoToolbox) ->
/// uma ligação TCP aberta e cifrada (o envelope da chamada, CallFrame). O iPhone manda o rato/teclas pela mesma ligação.
/// Regra de ouro da fluidez: nunca deixar acumular. Se o anterior ainda está a codificar ou há 3 frames no fio,
/// guarda-se só o mais recente e manda-se esse quando houver vaga.
final class ScreenStream: NSObject, SCStreamOutput, @unchecked Sendable {
    static var live: [ObjectIdentifier: ScreenStream] = [:]
    static let liveLock = NSLock()

    /// Payload de um frame de vídeo: [flags] (+ se bit0: [n] e n × [len u16][parameter set]) + amostra AVCC.
    enum Frame { static let key: UInt8 = 1 }

    let conn: NWConnection
    private let q = DispatchQueue(label: "fala.screen", qos: .userInteractive)
    private let key: SymmetricKey
    private var opener: CallFrame.Opener
    private var seq: UInt64 = 0
    private let width: Int
    private var fixed: CGDirectDisplayID?          // monitor escolhido no iPhone; nil = segue o rato
    private var current: CGDirectDisplayID = 0
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var encoding = false, sending = 0, forceKey = true, ended = false
    private var lastPixel: CVPixelBuffer?, pendingPixel: CVPixelBuffer?
    private var follow: DispatchSourceTimer?
    // Bitrate que se adapta à rede (como o Parsec): rede cheia (3 frames presos no fio) = desce 30%; folga = sobe 15%.
    private var bitrate = 4_000_000, netDrops = 0, lastAdapt = Date()
    private let remote: Bool, relay: Bool
    private static let minBitrate = 1_000_000
    private var maxBitrate: Int { relay ? 3_000_000 : remote ? 5_000_000 : 12_000_000 } // relay: a fila do túnel não se vê, teto mais baixo

    /// Rede de casa = endereço privado (192.168/10/172.16-31) ou o próprio Mac; o resto (Tailscale 100.x, internet) é remoto.
    static func isRemote(_ ep: NWEndpoint) -> Bool {
        guard case .hostPort(let h, _) = ep else { return true }
        let s = "\(h)".split(separator: "%").first.map(String.init) ?? ""
        if s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("127.") || s == "::1" || s.hasPrefix("fe80") { return false }
        if s.hasPrefix("172."), let b = Int(s.split(separator: ".")[1]), (16...31).contains(b) { return false }
        return true
    }

    init(conn: NWConnection, key: SymmetricKey, width: Int, monitor: UInt32?, relay: Bool = false) {
        self.conn = conn; self.key = key
        // Fora de casa (Tailscale/internet): perfil remoto como o Parsec em dados móveis.
        remote = relay || Self.isRemote(conn.endpoint) // pelo relay chega de 127.0.0.1, mas é internet
        self.relay = relay
        self.width = min(max(width, 640), remote ? 1280 : 1920) & ~1
        if remote { bitrate = 2_000_000 }
        fixed = monitor.flatMap { $0 == 0 ? nil : $0 }
        opener = CallFrame.Opener(key: key, dir: CallFrame.up)
    }

    func start() {
        Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = self; Self.liveLock.unlock()
        q.async { [self] in show(fixed ?? RemoteScreen.cursorDisplay()) }
        // Sem monitor fixo, a imagem segue o rato de ecrã para ecrã.
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.4, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.fixed == nil else { self.adapt(); return }
            self.adapt()
            let d = RemoteScreen.cursorDisplay()
            if d != self.current { self.show(d) }
        }
        t.resume(); follow = t
        var buf = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] d, _, complete, err in
                guard let self else { return }
                self.q.async {
                    if let d { buf.append(d) }
                    loop: while true {
                        switch self.opener.next(&buf) {
                        case .incomplete: break loop
                        case .bad: self.end(); return
                        case .frame(let k, let p): if k == .ctrl { self.control(p) } else if k == .hangup { self.end(); return }
                        }
                    }
                    if complete || err != nil { self.end(); return }
                    if !self.ended { read() }
                }
            }
        }
        read()
    }

    // MARK: iPhone -> Mac

    private func control(_ p: Data) {
        let j = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any] ?? [:]
        if j["kf"] != nil { forceKey = true; if let px = lastPixel { encode(px) } }
        if let m = (j["mon"] as? NSNumber)?.uint32Value {
            fixed = m == 0 ? nil : m
            show(fixed ?? RemoteScreen.cursorDisplay())
        }
        guard var c = try? JSONDecoder().decode(RemoteInput.Cmd.self, from: p) else { return }
        if c.ax != nil, c.md == nil { c.md = current } // o ponto é do monitor que o iPhone está a ver
        DispatchQueue.main.async { _ = RemoteInput.apply(c) }
    }

    // MARK: captura

    /// Troca a captura para o monitor `id` (no arranque, ao escolher outro, ou quando o rato muda de ecrã).
    private func show(_ id: CGDirectDisplayID) {
        guard !ended else { return }
        current = id
        let old = stream; stream = nil
        Task { [weak self] in
            try? await old?.stopCapture()
            guard let self, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { self?.end(); return }
            let w = min(self.width, d.width * 2) & ~1, h = (w * d.height / d.width) & ~1
            let cfg = SCStreamConfiguration()
            cfg.width = w; cfg.height = h
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120) // pedir 120 dá 60 reais
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // o formato do codificador: sem conversão
            cfg.queueDepth = 5
            cfg.showsCursor = true // ponytail: cursor dentro do vídeo; camada própria se o atraso do cursor incomodar
            let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)
                try await s.startCapture()
            } catch { CallLog.w("ecrã ao vivo: captura falhou \(error)"); self.end(); return }
            self.q.async {
                guard !self.ended, self.current == id else { Task { try? await s.stopCapture() }; return }
                self.stream = s; self.makeEncoder(w, h); self.forceKey = true; self.lastPixel = nil; self.pendingPixel = nil
            }
        }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, s === stream, let px = sb.imageBuffer else { return }
        // Só frames com imagem nova (com o ecrã parado o SCK manda "idle" e não há nada a codificar).
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        lastPixel = px
        encode(px)
    }

    // MARK: codificação

    private func makeEncoder(_ w: Int, _ h: Int) {
        if let e = encoder { VTCompressionSessionInvalidate(e); encoder = nil }
        encoding = false
        var s: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        if VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
                                      imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s) != noErr {
            VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                       imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard let s else { CallLog.w("ecrã ao vivo: sem codificador H.264"); end(); return }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 3600,          // keyframes só a pedido (são picos de bits)
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: remote ? 3 : 60, // fora de casa: recupera de perdas em 3 s
            kVTCompressionPropertyKey_AverageBitRate: bitrate,            // começa a 4 Mbps; adapt() acerta à rede
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s
    }

    private func encode(_ px: CVPixelBuffer) {
        guard !ended, let enc = encoder else { return }
        if sending >= 3 { netDrops += 1 }
        if encoding || sending >= 3 { pendingPixel = px; return } // ocupado: fica só o mais recente
        encoding = true
        let opts = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        forceKey = false
        let t = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        let st = VTCompressionSessionEncodeFrame(enc, imageBuffer: px, presentationTimeStamp: t, duration: .invalid, frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            self.q.async {
                self.encoding = false
                if status == noErr, let sample { self.ship(sample) }
                self.pump()
            }
        }
        if st != noErr { encoding = false }
    }

    /// De segundo a segundo: muitos frames presos = rede lenta (dados móveis) -> menos bits; sem presos -> mais nitidez.
    private func adapt() {
        guard Date().timeIntervalSince(lastAdapt) >= 1, let enc = encoder else { return }
        lastAdapt = Date()
        let old = bitrate
        if netDrops > 3 { bitrate = max(Self.minBitrate, bitrate * 7 / 10) }
        else if netDrops == 0 { bitrate = min(maxBitrate, bitrate * 115 / 100) }
        netDrops = 0
        if bitrate != old { VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) }
    }

    private func pump() {
        if let p = pendingPixel, !encoding, sending < 3 { pendingPixel = nil; encode(p) }
    }

    private func ship(_ sample: CMSampleBuffer) {
        guard let fmt = sample.formatDescription, let bb = sample.dataBuffer else { return }
        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        var out = Data([notSync ? 0 : Frame.key])
        if !notSync {
            var n = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
            out.append(UInt8(n))
            for i in 0..<n {
                var p: UnsafePointer<UInt8>?, size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let p else { return }
                out.append(UInt8(size >> 8)); out.append(UInt8(size & 0xFF)); out.append(p, count: size)
            }
        }
        let len = CMBlockBufferGetDataLength(bb)
        var body = Data(count: len)
        body.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        out.append(body)
        seq += 1; sending += 1
        conn.send(content: CallFrame.seal(.video, out, dir: CallFrame.down, seq: seq, key: key), completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.q.async { self.sending -= 1; if err != nil { self.end() } else { self.pump() } }
        })
    }

    private func end() {
        q.async { [self] in
            guard !ended else { return }
            ended = true
            follow?.cancel(); follow = nil
            let s = stream; stream = nil
            Task { try? await s?.stopCapture() }
            if let e = encoder { VTCompressionSessionInvalidate(e); encoder = nil }
            conn.cancel()
            Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = nil; Self.liveLock.unlock()
        }
    }
}
