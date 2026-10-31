import SwiftUI
import AppKit
import Network

@main struct FalaMacApp: App {
    @StateObject private var store: Store
    @StateObject private var mic: Transcriber
    @StateObject private var receiver: MacReceiver

    // Receptor e atalho arrancam já, mesmo sem janela aberta (app em segundo plano).
    init() {
        // App de barra de menus: o macOS não a pode fechar sozinho por não ter janelas (era o que a desligava).
        ProcessInfo.processInfo.disableAutomaticTermination("Fala ouve o iPhone")
        ProcessInfo.processInfo.disableSuddenTermination()
        let s = Store(), m = Transcriber(), r = MacReceiver()
        _store = StateObject(wrappedValue: s); _mic = StateObject(wrappedValue: m); _receiver = StateObject(wrappedValue: r)
        FalaFonts.register()
        JarvisVoice.shared.kokoro.warmUp() // a voz natural do Jarvis demora 11 a 25 s a carregar: fica pronta antes da 1.ª chamada
        UserDefaults.standard.set("launch \(Date()) ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess())", forKey: "fala.launch")
        MainActor.assumeIsolated {
            r.start(store: s)
            WhisperEngine.shared.warmUp() // o iPhone envia áudio: modelo pronto antes do 1.º ditado
            PillController.shared.install(mic: m, store: s)
            Hotkey.shared.install(mic: m, store: s)
            JarvisNotify.install() // vigia as sessões (eventos para o iPhone)
            Snapshot.runIfAsked(store: s, mic: m, receiver: r)
        }
    }

    var body: some Scene {
        WindowGroup("Fala") {
            RootGate()
                .environmentObject(store).environmentObject(mic).environmentObject(receiver)
                .onAppear {
                    Task { _ = await mic.authorize() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1350, height: 850)
        MenuBarExtra("Fala", systemImage: "waveform") {
            FalaMenu(status: receiver.status)
        }
        // QR sempre à mão: barra de menus, "Ligar o iPhone (QR)".
        Window("Ligar o iPhone", id: "pair-qr") {
            PairQRWindow().environmentObject(receiver)
        }
        .windowResizability(.contentSize)
    }
}

/// Cola texto onde estiver o cursor (Cmd+V simulado). Precisa de Acessibilidade.
enum Paster {
    static func paste(_ text: String, enter: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        let line = "\(Date()) ax=\(AXIsProcessTrusted()) post=\(CGPreflightPostEventAccess()) front=\(front?.localizedName ?? "?") \(front?.bundleIdentifier ?? "") chars=\(text.count)"
        // O ditado fica no clipboard até ao próximo (não se repõe o que lá estava): dá para colar outra vez noutro sítio.
        UserDefaults.standard.set(line, forKey: "fala.debug")
        // Registo de cada colagem (para ver em que app falhou): ~/Library/Logs/Fala/paste.log
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fala/paste.log")
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        else { try? Data((line + "\n").utf8).write(to: log) }
        if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Fonte privada: o Fn (ou outra tecla) ainda em baixo não se mistura com o ⌘V.
        let src = CGEventSource(stateID: .privateState)
        func post(_ code: CGKeyCode, _ down: Bool, cmd: Bool) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = cmd ? .maskCommand : []
            e?.post(tap: .cghidEventTap)
        }
        func key(_ code: CGKeyCode, cmd: Bool = false) { post(code, true, cmd: cmd); post(code, false, cmd: cmd) }
        // ⌘ a sério em baixo/cima à volta do V: Chrome, Electron (ChatGPT) e Windows App leem o estado da tecla, não só a flag.
        post(55, true, cmd: true); key(9, cmd: true); post(55, false, cmd: false)
        if enter { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { key(36) } }
    }
}

/// Esc enquanto a Fala grava = cancela o ditado (como no Wispr Flow) e o Esc NÃO chega à app da frente
/// (antes interrompia o Claude Code no iTerm). Fora da gravação o Esc passa normal.
private var escTap: CFMachPort?
@MainActor private func installEscTap() {
    guard escTap == nil else { return }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    escTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = escTap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return Unmanaged.passUnretained(event) }
        let recording = MainActor.assumeIsolated { PillController.shared.isRecording }
        guard recording else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async { PillController.shared.cancel() }
        return nil // engolido
    }, userInfo: nil)
    guard let escTap else { return } // sem Acessibilidade: fica como antes
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, escTap, 0), .commonModes)
    CGEvent.tapEnable(tap: escTap, enable: true)
}

/// Segurar a tecla Fn = ditar no próprio Mac (como o Flow). Larga = cola. O pill trata do resto.
@MainActor final class Hotkey {
    static let shared = Hotkey()
    private var monitors: [Any] = []
    private var down = false
    func install(mic: Transcriber, store: Store) {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            let fn = e.modifierFlags.contains(.function)
            Task { @MainActor in
                guard let self, fn != self.down else { return }
                self.down = fn
                if fn { PillController.shared.fnDown() } else { PillController.shared.fnUp() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        installEscTap()
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
    }
}

struct FalaMenu: View {
    let status: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(status)
        Button("Ligar o iPhone (QR)…") { NSApp.activate(); openWindow(id: "pair-qr") }
        Divider()
        Button("Sair") {
            // O LaunchAgent reabre a Fala sempre; "Sair" desliga-o até ao próximo login.
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/com.fran.fala.keepalive"]
            try? p.run()
            NSApp.terminate(nil)
        }
    }
}

struct PairQRWindow: View {
    @EnvironmentObject var receiver: MacReceiver
    var body: some View {
        VStack(spacing: 14) {
            Text("Aponta a câmara do iPhone").font(.system(size: 17, weight: .semibold))
            if let qr = PairQR.image(receiver.pairURL) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 260, height: 260)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Fica ligado para sempre, em casa ou noutro país.\nCódigo: \(receiver.token)")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
