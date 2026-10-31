import SwiftUI
import PencilKit
import AVKit

// MARK: - Imagens e vídeos do Mac no chat (como o ChatGPT), com lápis para marcar e mandar de volta.

extension JarvisModel {
    /// Bytes de um ficheiro do Mac (cache em memória durante a sessão da app).
    func media(_ path: String) async -> Data? {
        if let d = mediaCache[path] { return d }
        guard let r = await mac?.jarvis(.init(op: "file", text: path), timeout: 30), r.ok, let d = r.file else { return nil }
        mediaCache[path] = d
        return d
    }
}

/// Miniaturas das imagens/vídeos que o agente citou na resposta.
struct MediaStrip: View {
    let paths: [String]
    var onAttach: (Data, String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { ForEach(paths, id: \.self) { MediaThumb(path: $0, onAttach: onAttach) } }
        }
    }
}

struct MediaThumb: View {
    let path: String
    var onAttach: (Data, String) -> Void
    @EnvironmentObject var jarvis: JarvisModel
    @State private var data: Data?
    @State private var failed = false
    @State private var open = false
    private var video: Bool { Jarvis.isVideo(path) }

    var body: some View {
        Button { tick(); if data != nil { open = true } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink.opacity(0.06))
                if let data, !video, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.muted)
                } else if data == nil {
                    ProgressView()
                }
                if video {
                    Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white).shadow(radius: 4)
                }
            }
            .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .task { data = await jarvis.media(path); failed = data == nil }
        .fullScreenCover(isPresented: $open) {
            if let data { MediaViewer(path: path, data: data, onAttach: onAttach) }
        }
    }
}

/// Ecrã inteiro: ver (X para fechar) ou rodear com o lápis e mandar a imagem marcada para a caixa do chat.
struct MediaViewer: View {
    let path: String
    let data: Data
    var onAttach: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var pencil = false
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if Jarvis.isVideo(path) {
                VideoPlayer(player: AVPlayer(url: Self.tempURL(path, data))).ignoresSafeArea(edges: .bottom)
            } else if let img = UIImage(data: data) {
                GeometryReader { g in
                    let fit = Self.fit(img.size, in: g.size)
                    ZStack {
                        Image(uiImage: img).resizable().scaledToFit().frame(width: fit.width, height: fit.height)
                        Canvas(drawing: $drawing, enabled: pencil).frame(width: fit.width, height: fit.height)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .onAppear { canvasSize = fit }
                    .onChange(of: g.size) { _, s in canvasSize = Self.fit(img.size, in: s) }
                }
            }
            VStack {
                HStack(spacing: 12) {
                    circle("xmark") { dismiss() }
                    Spacer()
                    if !Jarvis.isVideo(path) {
                        if !drawing.strokes.isEmpty { circle("arrow.uturn.backward") { drawing.strokes.removeLast() } }
                        circle(pencil ? "pencil.tip.crop.circle.fill" : "pencil.tip", active: pencil) { tick(); pencil.toggle() }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                if !Jarvis.isVideo(path) {
                    Button {
                        tick(.medium)
                        let out = drawing.strokes.isEmpty ? data : (render() ?? data)
                        onAttach(out, (drawing.strokes.isEmpty ? "" : "marcada-") + (path as NSString).lastPathComponent)
                        dismiss()
                    } label: {
                        Label(drawing.strokes.isEmpty ? "Usar no chat" : "Usar com as marcas", systemImage: "arrow.up.circle.fill")
                            .font(Theme.sans(16, .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 20).padding(.vertical, 14).background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.bottom, 24)
                }
            }
        }
        .statusBarHidden()
    }

    private func circle(_ icon: String, active: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: { tick(); a() }) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(active ? Theme.ink : .white)
                .frame(width: 44, height: 44).background(active ? Color.white : Color.white.opacity(0.18), in: Circle())
        }.buttonStyle(.plain)
    }

    /// Imagem original com as marcas por cima, à resolução da imagem.
    private func render() -> Data? {
        guard let img = UIImage(data: data), canvasSize.width > 0 else { return nil }
        let k = img.size.width / canvasSize.width
        let marks = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: k * UIScreen.main.scale)
        let out = UIGraphicsImageRenderer(size: img.size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
            marks.draw(in: CGRect(origin: .zero, size: img.size))
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    static func fit(_ s: CGSize, in b: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0 else { return b }
        let k = min(b.width / s.width, b.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }

    static func tempURL(_ path: String, _ d: Data) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent((path as NSString).lastPathComponent)
        if !FileManager.default.fileExists(atPath: u.path) { try? d.write(to: u) }
        return u
    }
}

/// PencilKit transparente: lápis vermelho grosso para rodear.
private struct Canvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var enabled: Bool
    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear; v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.tool = PKInkingTool(.marker, color: .systemRed, width: 12)
        v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        v.isUserInteractionEnabled = enabled
        if v.drawing != drawing { v.drawing = drawing }
    }
    func makeCoordinator() -> C { C(self) }
    final class C: NSObject, PKCanvasViewDelegate {
        let p: Canvas
        init(_ p: Canvas) { self.p = p }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) { p.drawing = v.drawing }
    }
}

/// Anexo à espera na caixa (como o ChatGPT): miniatura com X antes de enviar.
struct AttachPreview: View {
    let data: Data
    let name: String
    var remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.system(size: 22))
                        Text(name).font(Theme.sans(10)).lineLimit(2).multilineTextAlignment(.center)
                    }.padding(6).foregroundStyle(Theme.ink.opacity(0.7))
                }
            }
            .frame(width: 72, height: 72)
            .background(Theme.appBG)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { tick(); remove() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Theme.ink, in: Circle())
            }
            .buttonStyle(.plain).offset(x: 6, y: -6)
        }
        .padding(.top, 6)
    }
}

// MARK: - Câmara ao vivo dentro do chat (como no ChatGPT): cartão redondo que cresce do "+", com voltar, disparar e virar.

final class LiveCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let q = DispatchQueue(label: "fala.camera")
    @Published var front = false
    @Published var denied = false
    private var done: ((UIImage) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { self.denied = !ok }
            guard ok else { return }
            self.q.async { self.configure(); if !self.session.isRunning { self.session.startRunning() } }
        }
    }
    func stop() { q.async { self.session.stopRunning() } }
    func flip() { front.toggle(); q.async { self.configure() } }

    private func configure() {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        session.inputs.forEach(session.removeInput)
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
        session.addInput(input)
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
    }

    func shoot(_ done: @escaping (UIImage) -> Void) {
        self.done = done
        q.async { self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self) }
    }
    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto p: AVCapturePhoto, error: Error?) {
        guard let d = p.fileDataRepresentation(), let img = UIImage(data: d) else { return }
        DispatchQueue.main.async { self.done?(img); self.done = nil }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> V { let v = V(); v.preview.session = session; v.preview.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ v: V, context: Context) {}
}

struct LiveCameraCard: View {
    var close: () -> Void
    var done: (UIImage) -> Void
    @StateObject private var cam = LiveCamera()
    @State private var flash = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Color.black
                if cam.denied {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.system(size: 30))
                        Text("Dá acesso à câmara nas Definições").font(Theme.sans(15))
                        Button("Abrir Definições") { tick(); if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                            .font(Theme.sans(15, .semibold))
                    }.foregroundStyle(.white).frame(maxHeight: .infinity)
                } else {
                    CameraPreview(session: cam.session)
                }
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
                HStack {
                    round("chevron.left", "Voltar") { close() }
                    Spacer()
                    Button {
                        tick(.medium)
                        withAnimation(.easeOut(duration: 0.08)) { flash = true }
                        withAnimation(.easeIn(duration: 0.3).delay(0.08)) { flash = false }
                        cam.shoot { img in tick(.light); done(img) }
                    } label: {
                        Circle().fill(.white).frame(width: 62, height: 62)
                            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 4).padding(-7))
                    }.buttonStyle(.plain).accessibilityLabel("Tirar fotografia").disabled(cam.denied)
                    Spacer()
                    round("arrow.triangle.2.circlepath", "Virar a câmara") { withAnimation(.spring(duration: 0.3)) { cam.flip() } }
                }
                .padding(.horizontal, 22).padding(.bottom, 22)
            }
            .frame(height: g.size.height * 0.68)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { tick(); action() } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial.opacity(0.9), in: Circle()).environment(\.colorScheme, .dark)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
