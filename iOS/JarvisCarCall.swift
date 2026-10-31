import Foundation
import CallKit
import AVFoundation

/// A chamada ao Jarvis como chamada do sistema (CallKit, como o WhatsApp): aparece no ecrã do CarPlay,
/// ouve-se nas colunas do carro e os botões do carro/volante desligam e silenciam. Não precisa de autorização da Apple.
/// O microfone continua a ser o do iPhone quando possível (CallAudio prefere o "built-in mic").
@MainActor final class JarvisCarCall: NSObject, CXProviderDelegate {
    static let shared = JarvisCarCall()
    private let controller = CXCallController()
    private lazy var provider: CXProvider = {
        let c = CXProviderConfiguration()
        c.supportsVideo = false; c.maximumCallsPerCallGroup = 1; c.maximumCallGroups = 1
        c.supportedHandleTypes = [.generic]; c.includesCallsInRecents = false
        let p = CXProvider(configuration: c); p.setDelegate(self, queue: nil); return p
    }()
    private var current: UUID?
    private var activated: CheckedContinuation<Void, Never>?
    var onEnd: (() -> Void)?            // desligou no carro / no ecrã de chamada
    private(set) var lastError: String?
    var onMute: ((Bool) -> Void)?

    /// Abre a chamada no sistema e espera que o iOS ligue o áudio (máx. 2 s). false = sem CallKit (segue sem ele).
    func start(name: String) async -> Bool {
        _ = provider
        let id = UUID()
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Jarvis · \(name)"))
        action.contactIdentifier = "Jarvis · \(name)"
        do { try await controller.request(CXTransaction(action: action)) } catch { lastError = "\(error)"; return false }
        current = id
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            activated = c
            Task { try? await Task.sleep(for: .seconds(2)); self.resumeActivated() }
        }
        return true
    }

    func connected() { if let current { provider.reportOutgoingCall(with: current, connectedAt: Date()) } }

    func end() {
        guard let id = current else { return }
        current = nil
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
    }

    private func resumeActivated() { activated?.resume(); activated = nil }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in self.current = nil; self.onEnd?() } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Categoria certa antes de o iOS ativar a sessão de áudio.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor in if self.current == action.callUUID { self.current = nil; self.onEnd?() } }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        Task { @MainActor in self.onMute?(action.isMuted) }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.resumeActivated(); self.onActivate?() }
    }
    /// O iOS ligou o áudio da chamada (pode chegar depois de o motor arrancar): a chamada reanima o motor.
    var onActivate: (() -> Void)?
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
