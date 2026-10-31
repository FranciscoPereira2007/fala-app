import SwiftUI
import AppKit

/// Só para comparar com o Flow: FALA_SNAPSHOT=/pasta grava PNGs do hub por separador e do pill por estado.
@MainActor enum Snapshot {
    static func runIfAsked(store: Store, mic: Transcriber, receiver: MacReceiver) {
        guard let dir = ProcessInfo.processInfo.environment["FALA_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for t in HubTab.allCases {
                let v = HubView(initial: t).environmentObject(store).environmentObject(mic).environmentObject(receiver)
                save(v, CGSize(width: 1280, height: 803), "\(dir)/fala-\(t.id).png")
            }
            let close = {}
            let modals: [(String, AnyView, CGSize)] = [
                ("modal-addword", AnyView(AddWordModal(store: store, close: close)), .init(width: 460, height: 260)),
                ("modal-snippet", AnyView(AddSnippetModal(store: store, close: close)), .init(width: 600, height: 420)),
                ("modal-transform", AnyView(TransformDetail(t: TransformsStore.defaults[0], sample: nil, close: close)), .init(width: 900, height: 640)),
                ("modal-createtransform", AnyView(CreateTransformModal(close: close)), .init(width: 600, height: 400)),
                ("modal-settings", AnyView(SettingsModal(close: close, tab: .system).environmentObject(receiver)), .init(width: 800, height: 560)),
                ("notifications", AnyView(NotificationsPanel()), .init(width: 360, height: 380)),
                ("help", AnyView(HelpMenu(openSettings: {}).background(Flow.bg)), .init(width: 200, height: 220)),
                ("onboarding", AnyView(MacOnboarding(done: {}).environmentObject(mic).environmentObject(store).environmentObject(receiver)), .init(width: 1280, height: 803)),
            ]
            for (n, v, sz) in modals { save(v.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.3)), sz, "\(dir)/fala-\(n).png") }
            let pd = "\(dir)/pill/fala"
            try? FileManager.default.createDirectory(atPath: pd, withIntermediateDirectories: true)
            let states: [(String, PillState, PillToast?, Bool)] = [
                ("idle", .idle, nil, false), ("hover", .hover, nil, true), ("ptt", .ptt, nil, false), ("handsFree", .handsFree, nil, false),
                ("processing", .processing, nil, false), ("done", .done, nil, false), ("error", .error, nil, false),
                ("toast-cancel", .toast, PillToast(text: "Transcrição cancelada", action: "Desfazer", duration: 4), false),
                ("toast-milestone", .toast, PillToast(text: "1.000 palavras hoje 🎉", action: nil, duration: 2.6, celebrate: true), false)]
            for (n, st, t, tip) in states {
                let m = PillModel(); m.state = st; m.toast = t; m.showTip = tip; m.goalLeft = 120; m.toastStart = Date().addingTimeInterval(-1)
                m.audioScale = st == .ptt || st == .handsFree ? 3 : 1; m.micActive = m.audioScale > 1
                save(FlowBar(ctl: PillController.shared).environmentObject(m).background(Color(hex: 0xe6e4de)), CGSize(width: 440, height: 320), "\(pd)/\(n).png")
            }
            NSApp.terminate(nil)
        }
    }
    static func save(_ v: some View, _ size: CGSize, _ path: String) {
        let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height))
        let w = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host; host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
