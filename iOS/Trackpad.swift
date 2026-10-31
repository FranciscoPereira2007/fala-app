import SwiftUI
import UIKit

/// Toques por cima do ecrã do Mac. Dois modos:
/// - normal: o dedo é o rato. Arrastar = o rato segue o dedo (hover: aparecem os controlos do YouTube, menus, etc.)
///   com zoom 2x à volta do dedo para apontar com precisão; toque = clique esquerdo ali, 2 toques = duplo clique,
///   carregar 0,5 s (vibra) e arrastar = selecionar texto (depois ⌘C na barra do teclado).
/// - trackpad (como o do MacBook): 1 dedo mexe o rato a partir de onde está, toque = clique onde está o rato.
/// Nos dois: beliscar = zoom no iPhone (onde estão os dedos), 2 dedos = scroll no Mac (com zoom: passear pela imagem),
/// 3 dedos para os lados = mudar de ecrã, para cima = Mission Control.
struct TouchSurface: UIViewRepresentable {
    let mac: MacSender
    var monitor: UInt32?
    var trackpad: Bool
    var zoomed: Bool
    var live: LiveScreenClient?                // ecrã ao vivo ligado: rato e teclas vão pela mesma ligação, sem esperar
    var pc = false                             // ecrã do PC: sem vídeo direto, o rato vai pelo PCNode
    var map: (CGPoint) -> CGPoint?            // ponto no iPhone -> 0..1 no ecrã do Mac (nil = fora da imagem)
    var onZoom: (CGFloat, CGPoint, Bool) -> Void // escala desde o início, ponto dos dedos, começou agora
    var onPan: (CGSize) -> Void                // passear pela imagem com zoom (delta)
    var onAim: (Int, CGPoint) -> Void = { _, _ in } // dedo a apontar (modo normal): 0 começa, 1 mexe, 2 levanta, 3 toque

    func makeCoordinator() -> Pad { Pad(mac) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .clear; v.isMultipleTouchEnabled = true
        let p = context.coordinator
        let move = UIPanGestureRecognizer(target: p, action: #selector(Pad.move)); move.maximumNumberOfTouches = 1
        let two = UIPanGestureRecognizer(target: p, action: #selector(Pad.two)); two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2
        let swipe = UIPanGestureRecognizer(target: p, action: #selector(Pad.swipe)); swipe.minimumNumberOfTouches = 3
        let pinch = UIPinchGestureRecognizer(target: p, action: #selector(Pad.pinch))
        let drag = UILongPressGestureRecognizer(target: p, action: #selector(Pad.drag)); drag.minimumPressDuration = 0.5
        let tap2 = UITapGestureRecognizer(target: p, action: #selector(Pad.doubleTap)); tap2.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: p, action: #selector(Pad.tap)); tap.require(toFail: tap2)
        move.require(toFail: drag) // ponytail: o arrastar só começa se o dedo ficar parado 0,35 s
        p.pinchGR = pinch; p.dragGR = drag
        for g in [move, two, swipe, pinch, drag, tap2, tap] as [UIGestureRecognizer] { g.delegate = p; v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        let p = context.coordinator
        p.monitor = monitor; p.trackpad = trackpad; p.zoomed = zoomed; p.map = map; p.onZoom = onZoom; p.onPan = onPan; p.live = live; p.onAim = onAim; p.pc = pc
    }

    final class Pad: NSObject, UIGestureRecognizerDelegate {
        let mac: MacSender
        var monitor: UInt32?, trackpad = false, zoomed = false
        var map: (CGPoint) -> CGPoint? = { _ in nil }
        var onZoom: (CGFloat, CGPoint, Bool) -> Void = { _, _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        weak var pinchGR: UIPinchGestureRecognizer?
        weak var dragGR: UILongPressGestureRecognizer?
        var onAim: (Int, CGPoint) -> Void = { _, _ in }
        var live: LiveScreenClient?
        var pc = false
        private func deliver(_ j: [String: Any]) async { if let live { live.send(j) } else if pc { await PCNode.input(j) } else { await mac.pointer(j) } }
        init(_ mac: MacSender) { self.mac = mac }

        // Só um pedido de cada vez; o que chega entretanto junta-se (sem fila a crescer).
        private var dx = 0.0, dy = 0.0, sx = 0.0, sy = 0.0, at: CGPoint?, busy = false
        private let speed = 2.2 // ponytail: pontos do iPhone -> pontos do Mac no trackpad; afinar ao gosto

        private func flush() {
            guard !busy, dx != 0 || dy != 0 || Int(sx) != 0 || Int(sy) != 0 || at != nil else { return }
            var j: [String: Any] = [:]
            if dx != 0 || dy != 0 { j["dx"] = dx * speed; j["dy"] = dy * speed }
            if let at { j["ax"] = at.x; j["ay"] = at.y }
            if Int(sx) != 0 || Int(sy) != 0 { j["sx"] = Int(sx); j["sy"] = Int(sy) }
            if let monitor { j["md"] = monitor }
            dx = 0; dy = 0; sx = 0; sy = 0; at = nil; busy = true
            Task { @MainActor in await deliver(j); busy = false; flush() }
        }
        private func send(_ j: [String: Any], haptic: Bool = true) {
            var j = j; if let monitor, j["k"] == nil { j["md"] = monitor }
            if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            Task { @MainActor in await deliver(j) }
        }
        /// Clique: no modo normal onde tocaste, no trackpad onde está o rato.
        private func click(_ g: UIGestureRecognizer, _ j: [String: Any]) {
            if !trackpad { onAim(3, g.location(in: g.view)) } // toque com a lupa ainda aberta: renova o tempo
            var j = j
            if !trackpad { guard let m = map(g.location(in: g.view)) else { return }; j["ax"] = m.x; j["ay"] = m.y }
            send(j)
        }

        private var moveStart = (at: Date(), p: CGPoint.zero)
        @objc func move(_ g: UIPanGestureRecognizer) {
            if !trackpad, g.state == .began { moveStart = (Date(), g.location(in: g.view)); onAim(0, g.location(in: g.view)) }
            if !trackpad, g.state == .changed { onAim(1, g.location(in: g.view)) }
            if !trackpad, g.state == .ended || g.state == .cancelled {
                onAim(2, g.location(in: g.view))
                // Toque que escorregou um pouco (o iOS chama-lhe arrastar): conta como clique, senão "às vezes não clica".
                let p = g.location(in: g.view)
                if g.state == .ended, Date().timeIntervalSince(moveStart.at) < 0.3, hypot(p.x - moveStart.p.x, p.y - moveStart.p.y) < 25 {
                    click(g, ["c": 1]); return
                }
            }
            if trackpad { let t = g.translation(in: g.view); g.setTranslation(.zero, in: g.view); dx += t.x; dy += t.y }
            else if let m = map(g.location(in: g.view)) { at = m } // o rato segue o dedo
            flush()
        }
        @objc func two(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view); g.setTranslation(.zero, in: g.view)
            let pinching = pinchGR?.state == .began || pinchGR?.state == .changed // a beliscar, o próprio beliscar passeia
            if zoomed { if !pinching { onPan(CGSize(width: t.x, height: t.y)) }; return } // com zoom: 2 dedos arrastam a imagem
            guard !pinching else { return }                                         // a beliscar não faz scroll no Mac
            sx += t.x * 2; sy += t.y * 2; flush()                        // scroll natural, como no Mac
        }
        private var last = CGPoint.zero
        @objc func drag(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            switch g.state {
            case .began:
                last = p
                if !trackpad { UIImpactFeedbackGenerator(style: .heavy).impactOccurred(); onAim(0, p) } // a selecionar: vibra e a lupa acompanha
                var j: [String: Any] = ["b": "down"]
                if !trackpad { guard let m = map(p) else { return }; j["ax"] = m.x; j["ay"] = m.y }
                send(j)
            case .changed:
                if trackpad { dx += p.x - last.x; dy += p.y - last.y; last = p } else { onAim(1, p); if let m = map(p) { at = m } }
                flush()
            case .ended, .cancelled:
                if !trackpad { onAim(2, p) }
                send(["b": "up"], haptic: false)
            default: break
            }
        }
        @objc func tap(_ g: UITapGestureRecognizer) { click(g, ["c": 1]) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { click(g, ["c": 2]) }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .began || g.state == .changed else { return }
            onZoom(g.scale, g.location(in: g.view), g.state == .began) // zoom no iPhone, não no Mac
        }

        private func key(_ k: String, _ m: [String]) { send(["k": k, "m": m]) }
        private var swiped = false
        @objc func swipe(_ g: UIPanGestureRecognizer) {
            if g.state == .began { swiped = false }
            guard g.state == .changed, !swiped else { return }
            let t = g.translation(in: g.view)
            if abs(t.x) > 35, abs(t.x) > abs(t.y) { swiped = true; key(t.x < 0 ? "right" : "left", ["ctrl"]) } // como no Mac: puxar para a esquerda = ecrã da direita
            else if t.y < -35 { swiped = true; key("up", ["ctrl"]) } // Mission Control
            else if t.y > 35 { swiped = true; key("down", ["ctrl"]) } // janelas da app
        }

        // Beliscar e arrastar com 2 dedos ao mesmo tempo (zoom + passear).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (o is UIPinchGestureRecognizer && g is UIPanGestureRecognizer)
        }
    }
}

import AVFoundation

/// Ecrã ao vivo no iPhone: o vídeo H.264 do Mac vai direto para uma AVSampleBufferDisplayLayer (descodificação no chip).
@MainActor final class LiveScreen: ObservableObject {
    @Published private(set) var on = false
    @Published private(set) var size: CGSize?
    @Published private(set) var fps = 0.0
    @Published private(set) var relayed = false // ao vivo pelo relay (fora de casa)
    private(set) var client: LiveScreenClient?
    fileprivate weak var layer: AVSampleBufferDisplayLayer?
    private var frames = 0, t0 = Date()

    func connect(mac: MacSender, width: Int, monitor: UInt32?, pc: Bool = false) async {
        guard !on else { return }
        let c = LiveScreenClient()
        c.onSample = { [weak self] sb, sz in
            DispatchQueue.main.async {
                guard let self, let layer = self.layer else { return }
                let r = layer.sampleBufferRenderer
                if r.status == .failed { r.flush(); c.send(["kf": 1]) } // ex.: voltou de segundo plano
                r.enqueue(sb)
                if self.size != sz { self.size = sz }
                self.frames += 1
                let dt = Date().timeIntervalSince(self.t0)
                if dt >= 1 { self.fps = Double(self.frames) / dt; self.frames = 0; self.t0 = Date() }
            }
        }
        c.onEnd = { [weak self] in DispatchQueue.main.async { self?.on = false; self?.client = nil } }
        let token = MacSender.token
        relayed = false
        if await c.connect(endpoints: pc ? PCNode.screenEndpoints : mac.callEndpoints, token: token, width: width, monitor: monitor) {
        } else if let ep = await RelayTunnel.endpoint(room: pc ? PCNode.room : LinkCrypto.room(token)), // fora de casa: pelo relay
                  await c.connect(endpoints: [ep], token: token, width: width, monitor: monitor, relay: true, timeout: 10) {
            relayed = true
        } else { return }
        client = c; on = true
    }

    func close() { client?.close(); client = nil; on = false }
}

struct LiveVideoView: UIViewRepresentable {
    let live: LiveScreen
    final class V: UIView { override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self } }
    func makeUIView(context: Context) -> V {
        let v = V(); v.isUserInteractionEnabled = false
        let l = v.layer as! AVSampleBufferDisplayLayer
        l.videoGravity = .resize // o tamanho certo (aspect fit) é dado pelo SwiftUI
        live.layer = l
        live.client?.send(["kf": 1]) // camada nova não tem o keyframe: sem isto fica preta até ao próximo
        return v
    }
    func updateUIView(_ v: V, context: Context) { live.layer = v.layer as? AVSampleBufferDisplayLayer }
}
