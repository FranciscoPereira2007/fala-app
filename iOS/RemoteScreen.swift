import SwiftUI

/// O ecrã do Mac (ou do PC, `pc`) no iPhone, de qualquer sítio. Gestos: ver TouchSurface (o dedo é o rato; beliscar = zoom no iPhone).
struct RemoteScreenView: View {
    var pc = false
    @EnvironmentObject var mac: MacSender
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var keyboard = false
    @State private var fps = 0.0
    @State private var have: String?
    @StateObject private var live = LiveScreen() // vídeo contínuo (rede local / Tailscale); sem ele, imagens soltas
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var panStart = CGSize.zero
    @State private var pinchStart = CGPoint.zero
    @State private var pan = CGSize.zero
    @AppStorage("remote.monitor") private var monitorID = 0 // 0 = segue o rato (o monitor onde ele está)
    @State private var monitors: [(id: UInt32, name: String)] = []
    // Lido do UserDefaults e não do @AppStorage: o ciclo das imagens (.task) guarda uma cópia antiga da vista.
    private var monitor: UInt32? { let id = UserDefaults.standard.integer(forKey: "remote.monitor"); return id == 0 ? nil : UInt32(id) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            GeometryReader { g in
                if let src = live.on ? live.size : image?.size {
                    let fit = { let k = min(g.size.width / src.width, g.size.height / src.height); return CGSize(width: src.width * k, height: src.height * k) }() // o ecrã do computador todo à vista, sem cortar (pedido do Fran); zoom para aproximar
                    Group {
                        if live.on { LiveVideoView(live: live) } else if let image { Image(uiImage: image).resizable() }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                    .scaleEffect(zoom).offset(pan)
                    // Todos os toques passam por aqui (UIKit: multitoque a sério). Mesmo espaço da imagem.
                    TouchSurface(mac: mac, monitor: monitor, trackpad: false, zoomed: zoom > 1, live: live.on ? live.client : nil, pc: pc,
                                 map: { s in toMac(s, fit, g.size) },
                                 onZoom: { k, s, began in zoomAt(s, k, began, g.size) },
                                 onPan: { d in pan = clamp(CGSize(width: pan.width + d.width, height: pan.height + d.height), g.size) },
                                 onAim: { phase, s in aim(phase, s, g.size) })

                } else if live.on {
                    LiveVideoView(live: live).frame(width: 1, height: 1) // à espera do 1.º frame: a camada tem de existir
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(error ?? (pc ? "A ligar ao ecrã do PC…" : "A ligar ao ecrã do Mac…")).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.clipped().ignoresSafeArea(.container, edges: [.top, .horizontal]) // ecrã todo em cima e dos lados; em baixo para antes da barra do teclado (nunca tapa o texto)
            HStack {
                Button { tick(); dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.white).frame(width: 44, height: 44).background(.white.opacity(0.18), in: Circle()) }
                Spacer()
                VStack(spacing: 4) {
                    if monitors.count > 1 {
                        Menu {
                            Button { tick(); pick(0) } label: { if monitor == nil { Label("Onde está o rato", systemImage: "checkmark") } else { Text("Onde está o rato") } }
                            ForEach(monitors, id: \.id) { m in
                                Button { tick(); pick(m.id) } label: { if m.id == monitor { Label(m.name, systemImage: "checkmark") } else { Text(m.name) } }
                            }
                        } label: {
                            HStack(spacing: 6) { Image(systemName: "display.2"); Text(monitor == nil ? "Onde está o rato" : monitors.first { $0.id == monitor }?.name ?? "Ecrã"); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                                .font(Theme.sans(14)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 36).background(.white.opacity(0.18), in: Capsule())
                        }
                    }
                    if holding, !zoomLocked {
                        Button { tick(); lockZoom() } label: {
                            Label("Fixar zoom", systemImage: "lock.fill").font(Theme.sans(14, .semibold)).foregroundStyle(.black)
                                .padding(.horizontal, 14).frame(height: 34).background(.white, in: Capsule())
                        }.transition(.scale.combined(with: .opacity))
                    } else if zoom > 1 {
                        Button { tick(); zoomLocked = false; autoZoom = false; holding = false; withAnimation(.snappy) { zoom = 1; pan = .zero } } label: {
                            Text(zoomLocked ? String(format: "Zoom fixo %.1fx · soltar", zoom) : String(format: "%.1fx · repor", zoom)).font(Theme.sans(13)).foregroundStyle(.black).padding(.horizontal, 12).frame(height: 30).background(.white, in: Capsule())
                        }
                    }
                    Text(Demo.on ? "41 img/s · ao vivo pela internet" : String(format: live.on ? (live.relayed ? "%.0f img/s · ao vivo pela internet" : "%.0f img/s · ao vivo") : "%.1f img/s", live.on ? live.fps : fps)).font(Theme.sans(12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button { tick(); keyboard = true } label: { Image(systemName: "keyboard").foregroundStyle(.white).frame(width: 44, height: 44).background(.white.opacity(0.18), in: Circle()) }
            }.padding(.horizontal, 16).padding(.top, 6)
        }
        .statusBarHidden()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboard { RemoteKeyboardView(compact: true, pc: pc) { keyboard = false } }
        }
        .onAppear {
            FalaOrientation.set(.allButUpsideDown)
            do { // o ecrã do Mac é largo: abre logo na horizontal para ocupar o ecrã todo (pedido do Fran)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    // A cena da app (não a do CarPlay) e o ecrã que está por cima (o fullScreenCover), senão o iOS ignora o pedido.
                    guard let sc = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }) else { return }
                    FalaOrientation.mask = .allButUpsideDown // outra vista pode ter reposto o vertical entretanto
                    var top = sc.windows.first(where: \.isKeyWindow)?.rootViewController
                    var chain: [UIViewController] = top.map { [$0] } ?? []
                    while let p = top?.presentedViewController { top = p; chain.append(p) }
                    chain.forEach { $0.setNeedsUpdateOfSupportedInterfaceOrientations() } // toda a cadeia: o iOS pergunta a quem apresenta
                    sc.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { print("[Fala] rodar:", $0) }
                }
            }
        }
        .onDisappear { FalaOrientation.set(.portrait); live.close() }
        .task {
            if pc { return } // ponytail: PC = só o monitor principal; lista de monitores quando houver mais de um
            monitors = await mac.monitors()
            // Monitor guardado que já não existe (desligado): volta a seguir o rato.
            if monitorID != 0, !monitors.isEmpty, !monitors.contains(where: { Int($0.id) == monitorID }) { monitorID = 0 }
        }
        .task {
            // 1.º vídeo ao vivo; se não der (fora de casa sem Tailscale), imagens soltas. Volta a tentar o vídeo de 5 em 5 s.
            if Demo.on { image = UIImage(named: "DemoDesktop.jpg"); fps = 41; return } // capturas: ecrã de exemplo
            var frames = 0, t0 = Date(), nextLive = Date()
            while !Task.isCancelled {
                if live.on { try? await Task.sleep(for: .milliseconds(500)); continue }
                if Date() >= nextLive {
                    nextLive = Date().addingTimeInterval(5)
                    let b = UIScreen.main.bounds
                    await live.connect(mac: mac, width: min(Int(max(b.width, b.height) * UIScreen.main.scale), 1920), monitor: monitor, pc: pc)
                    if live.on { continue }
                }
                let r = await refresh()
                if r != nil { frames += 1 } // conta respostas (imagem nova ou "não mudou")
                if r != true { try? await Task.sleep(for: .milliseconds(60)) }
                let dt = Date().timeIntervalSince(t0)
                if dt >= 1 { fps = Double(frames) / dt; frames = 0; t0 = Date() }
            }
        }
    }

    /// Ponto no iPhone -> 0..1 no ecrã do Mac, desfazendo o zoom e o deslocamento. nil = fora da imagem.
    private func toMac(_ s: CGPoint, _ fit: CGSize, _ box: CGSize) -> CGPoint? {
        let c = CGPoint(x: box.width / 2, y: box.height / 2)
        let p = CGPoint(x: c.x + (s.x - c.x - pan.width) / zoom, y: c.y + (s.y - c.y - pan.height) / zoom)
        let x = (p.x - (box.width - fit.width) / 2) / fit.width, y = (p.y - (box.height - fit.height) / 2) / fit.height
        return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
    }

    /// Apontar com o dedo: aproxima 1,5x e a lupa segue o dedo (o ponto debaixo do dedo é o mesmo que sem zoom,
    /// por isso chegas a qualquer canto). Ao levantar o zoom fica 3 s (cada toque renova) para clicares,
    /// e aparece "Fixar zoom" no topo: toca e fica fixo até "soltar". Não há gesto a arrastar para fixar (puxava a lupa).
    @State private var autoZoom = false
    @State private var zoomLocked = false
    @State private var holding = false            // dedo levantado, zoom ainda à espera do toque
    @State private var autoZoomOut: Task<Void, Never>?
    private func follow(_ s: CGPoint, _ box: CGSize) -> CGSize {
        clamp(CGSize(width: (box.width / 2 - s.x) * (zoom - 1), height: (box.height / 2 - s.y) * (zoom - 1)), box)
    }
    private func aim(_ phase: Int, _ s: CGPoint, _ box: CGSize) {
        autoZoomOut?.cancel()
        switch phase {
        case 0:
            guard !zoomLocked, zoom == 1 || autoZoom else { return }
            autoZoom = true; holding = false
            withAnimation(.easeOut(duration: 0.18)) { zoom = 1.5; pan = follow(s, box) } // 1,5x: o Fran achou 2x demais
        case 1:
            guard autoZoom, !zoomLocked else { return }
            pan = follow(s, box)
        case 3:
            if autoZoom, holding { holdZoom() }
        default:
            guard autoZoom, !zoomLocked else { return }
            holdZoom()
        }
    }
    /// Mantém o zoom 3 s (renova a cada toque) e depois volta ao ecrã todo.
    private func holdZoom() {
        autoZoomOut?.cancel()
        holding = true
        autoZoomOut = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !zoomLocked else { return }
            autoZoom = false; holding = false; withAnimation(.easeInOut(duration: 0.25)) { zoom = 1; pan = .zero }
        }
    }
    private func lockZoom() { tick(.medium); autoZoomOut?.cancel(); zoomLocked = true; autoZoom = false; holding = false }

    /// Zoom no iPhone (1x a 5x) com o ponto debaixo dos dedos parado no sítio.
    private func zoomAt(_ s: CGPoint, _ k: CGFloat, _ began: Bool, _ box: CGSize) {
        if began { zoomBase = zoom; panStart = pan; pinchStart = s }
        let z1 = min(max(zoomBase * k, 1), 5)
        let c = CGPoint(x: box.width / 2, y: box.height / 2), s0 = pinchStart
        let r = z1 / zoomBase
        zoom = z1
        if z1 <= 1.02 { zoomLocked = false }
        // O ponto que estava debaixo dos dedos acompanha os dedos: beliscar aproxima e arrastar com 2 dedos passeia (como nas Fotos).
        pan = z1 <= 1.02 ? .zero : clamp(CGSize(width: s.x - c.x - (s0.x - c.x - panStart.width) * r, height: s.y - c.y - (s0.y - c.y - panStart.height) * r), box)
    }

    /// Não deixa a imagem com zoom fugir do ecrã.
    private func clamp(_ p: CGSize, _ box: CGSize) -> CGSize {
        // Com zoom deixa passar 70 pt das bordas: o que está debaixo dos botões do topo ou da barra de baixo vem para a vista.
        let slack: CGFloat = zoom > 1 ? 70 : 0
        let mx = box.width * (zoom - 1) / 2 + slack, my = box.height * (zoom - 1) / 2 + slack
        return CGSize(width: min(max(p.width, -mx), mx), height: min(max(p.height, -my), my))
    }

    private func pick(_ id: UInt32) {
        tick(); monitorID = Int(id); have = nil // imagem nova já, mesmo que igual
        live.client?.send(["mon": id])
    }

    /// true = imagem nova, false = não mudou, nil = falhou.
    @discardableResult
    private func refresh() async -> Bool? {
        if pc {
            guard let d = await PCNode.screenshot() else { error = "O PC não respondeu"; return nil }
            guard let img = await Task.detached(operation: { UIImage(data: d)?.preparingForDisplay() }).value else { return nil }
            image = img; error = nil; return true
        }
        let b = UIScreen.main.bounds, w = Int(max(b.width, b.height) * UIScreen.main.scale)
        guard let d = await mac.screen(width: min(w, 1600), have: image == nil ? nil : have, monitor: monitor) else {
            error = mac.lastError ?? "O Mac não respondeu"; return nil
        }
        if d.isEmpty { return false } // não mudou
        // Descodifica fora do ecrã principal (antes travava o desenho).
        guard let img = await Task.detached(operation: { UIImage(data: d)?.preparingForDisplay() }).value else { return nil }
        image = img; have = Link.digest(d); error = nil
        return true
    }
}

/// O app é só vertical; o ecrã remoto liga a rotação enquanto está aberto.
enum FalaOrientation {
    static var mask: UIInterfaceOrientationMask = .portrait
    static func set(_ m: UIInterfaceOrientationMask) {
        mask = m
        guard UIDevice.current.userInterfaceIdiom != .pad else { return } // iPad: roda sempre
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if m == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }
    /// Põe na vertical sem desligar a rotação (tocar na faixa do teclado remoto).
    static func portrait() {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}

final class FalaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : FalaOrientation.mask // iPad roda sempre (multitarefa)
    }
}
