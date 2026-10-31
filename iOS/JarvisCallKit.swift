import Foundation
import CallKit
import PushKit

/// "O agente liga-me" com a app fechada: PushKit (VoIP push) + CallKit (ecrã de chamada do sistema).
/// DESLIGADO até existir a chave APNs (.p8) e a capacidade Push Notifications no App ID (ver research/jarvis/PLAN.md).
/// Para ligar: `JarvisFlags.callKit = true` + entitlement aps-environment + UIBackgroundModes voip.
enum JarvisFlags { static let callKit = false }

final class JarvisCallKit: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
    static let shared = JarvisCallKit()
    private var registry: PKPushRegistry?
    private lazy var provider: CXProvider = {
        let c = CXProviderConfiguration()
        c.supportsVideo = false; c.maximumCallsPerCallGroup = 1; c.supportedHandleTypes = [.generic]
        let p = CXProvider(configuration: c); p.setDelegate(self, queue: nil); return p
    }()
    /// Token VoIP a enviar ao Mac (op "register"), que o usa para mandar o push via APNs.
    private(set) var voipToken: String?
    var onAnswer: ((String) -> Void)?   // sessionID -> abre a CallView

    func start() {
        guard JarvisFlags.callKit, registry == nil else { return }
        let r = PKPushRegistry(queue: .main); r.delegate = self; r.desiredPushTypes = [.voIP]; registry = r
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate creds: PKPushCredentials, for type: PKPushType) {
        voipToken = creds.token.map { String(format: "%02x", $0) }.joined()
    }

    /// iOS exige reportar uma chamada ao CallKit em CADA VoIP push, senão mata a app.
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        let d = payload.dictionaryPayload
        let name = d["name"] as? String ?? "Agente", sid = d["session"] as? String ?? ""
        let u = CXCallUpdate(); u.remoteHandle = CXHandle(type: .generic, value: sid); u.localizedCallerName = name; u.hasVideo = false
        let id = UUID(); pending[id] = sid
        provider.reportNewIncomingCall(with: id, update: u) { _ in completion() }
    }

    private var pending: [UUID: String] = [:]
    func providerDidReset(_ provider: CXProvider) { pending = [:] }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let sid = pending[action.callUUID] { onAnswer?(sid) }
        action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { pending[action.callUUID] = nil; action.fulfill() }
}
