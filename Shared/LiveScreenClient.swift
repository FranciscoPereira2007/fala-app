import Foundation
import Network
import CryptoKit
import CoreMedia

/// Lado iPhone do ecrã ao vivo (ver ScreenStream no Mac): uma ligação aberta, frames H.264 a chegar,
/// rato e teclas a sair pela mesma ligação sem esperar resposta.
final class LiveScreenClient: @unchecked Sendable {
    /// Amostra pronta a mostrar (AVSampleBufferDisplayLayer) e o tamanho do vídeo.
    var onSample: ((CMSampleBuffer, CGSize) -> Void)?
    var onEnd: (() -> Void)?

    private let q = DispatchQueue(label: "fala.live", qos: .userInteractive)
    private var conn: NWConnection?
    private var key: SymmetricKey?
    private var opener: CallFrame.Opener?
    private var seq: UInt64 = 0
    private var format: CMVideoFormatDescription?
    private var ended = false

    /// Liga ao primeiro endereço direto que responder (rede local / Tailscale). false = usar as imagens soltas.
    /// `relay` = o endereço é o túnel do relay (internet): o outro lado usa o perfil remoto (menos bits).
    func connect(endpoints: [NWEndpoint], token: String, width: Int, monitor: UInt32?, relay: Bool = false, timeout: Double = 4) async -> Bool {
        var j: [String: Any] = ["w": width]
        if relay { j["r"] = 1 }
        if let monitor { j["mon"] = monitor }
        let body = Data("V".utf8) + ((try? JSONSerialization.data(withJSONObject: j)) ?? Data())
        for ep in endpoints {
            let id = LinkCrypto.newID()
            let hello = LinkCrypto.seal(body, id: id, token: token)
            if case .success(let (c, nonce, carry)) = await CallClient.handshake(ep, hello: hello, id: id, token: token, expect: 0x56, timeout: timeout, queue: q) {
                let k = CallFrame.key(token: token, requestID: id, nonce: nonce)
                q.sync { key = k; opener = CallFrame.Opener(key: k, dir: CallFrame.down); conn = c; ended = false }
                c.stateUpdateHandler = { [weak self] st in if case .failed = st { self?.end() } }
                read(c, carry: carry)
                return true
            }
        }
        return false
    }

    /// Rato / teclas (RemoteInput.Cmd em JSON), {"kf":1} = pedir keyframe, {"mon": id} = trocar de monitor (0 = segue o rato).
    func send(_ j: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        q.async { [self] in
            guard let c = conn, let key, !ended else { return }
            seq += 1
            c.send(content: CallFrame.seal(.ctrl, d, dir: CallFrame.up, seq: seq, key: key), completion: .contentProcessed { _ in })
        }
    }

    func close() {
        q.async { [self] in
            guard let c = conn, let key, !ended else { return }
            seq += 1
            c.send(content: CallFrame.seal(.hangup, Data(), dir: CallFrame.up, seq: seq, key: key), completion: .contentProcessed { _ in })
            q.asyncAfter(deadline: .now() + 0.2) { self.end() }
        }
    }

    private func read(_ c: NWConnection, carry: Data) {
        var buf = carry
        func drain() {
            while let o = opener {
                var op = o
                let r = op.next(&buf); opener = op
                switch r {
                case .incomplete: return
                case .bad: end(); return
                case .frame(let k, let d): if k == .video { video(d) } else if k == .hangup { end(); return }
                }
            }
        }
        func next() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, complete, err in
                guard let self, !self.ended else { return }
                if let d { buf.append(d); drain() }
                if complete || err != nil { self.end(); return }
                next()
            }
        }
        q.async { drain(); next() }
    }

    /// Frame: [flags] (+ keyframe: [n] e n × [len u16][SPS/PPS]) + amostra AVCC (NALUs com 4 bytes de tamanho).
    private func video(_ d: Data) {
        var i = d.startIndex
        guard i < d.endIndex else { return }
        let flags = d[i]; i += 1
        if flags & 1 != 0 {
            guard i < d.endIndex else { return }
            let n = Int(d[i]); i += 1
            var sets: [Data] = []
            for _ in 0..<n {
                guard i + 2 <= d.endIndex else { return }
                let len = Int(d[i]) << 8 | Int(d[i + 1]); i += 2
                guard i + len <= d.endIndex else { return }
                sets.append(Data(d[i..<i + len])); i += len
            }
            format = Self.format(sets)
        }
        guard let fmt = format else { send(["kf": 1]); return } // entrou a meio: pede um keyframe
        let body = Data(d[i...])
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: body.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr, let bb else { return }
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: body.count) }
        var sb: CMSampleBuffer?
        var size = body.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let dim = CMVideoFormatDescriptionGetDimensions(fmt)
        onSample?(sb, CGSize(width: Int(dim.width), height: Int(dim.height)))
    }

    static func format(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        let ptrs = sets.map { s -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count); s.copyBytes(to: p, count: s.count); return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        var f: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
            parameterSetPointers: ptrs.map { UnsafePointer($0) }, parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4, formatDescriptionOut: &f)
        return st == noErr ? f : nil
    }

    private func end() {
        q.async { [self] in
            guard !ended else { return }
            ended = true; conn?.cancel(); conn = nil; format = nil
            onEnd?()
        }
    }
}
