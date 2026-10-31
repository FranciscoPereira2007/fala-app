import CarPlay

/// Fala no CarPlay (entitlement "Voice Based Conversation" aprovado pela Apple):
/// lista de sessões -> toca numa -> falas, o pedido segue para a sessão e a resposta é lida em voz alta.
/// Sem ecrã do Mac no carro (era rejeição certa): só voz e listas, como pedem as regras do CarPlay.
@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var ic: CPInterfaceController?
    private let jarvis = JarvisModel()
    private let mac = KeyboardSession.shared.mac ?? { let m = MacSender(); m.startBrowsing(); return m }()
    private let mic = Transcriber()
    private let voice = DotVoice()
    private var loop: Task<Void, Never>?
    private let list = CPListTemplate(title: "Sessões", sections: [])

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect ic: CPInterfaceController) {
        Task { @MainActor in
            self.ic = ic
            ic.setRootTemplate(list, animated: false, completion: nil)
            jarvis.mac = mac
            await reload()
        }
    }

    nonisolated func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController ic: CPInterfaceController) {
        Task { @MainActor in stopTalking(); self.ic = nil }
    }

    private func reload() async {
        await jarvis.refresh()
        let items = jarvis.sessions.prefix(12).map { s -> CPListItem in
            let i = CPListItem(text: jarvis.title(s), detailText: s.needsYou ? "À espera de ti" : (s.busy ? "A trabalhar" : nil))
            i.handler = { [weak self] _, done in Task { @MainActor in self?.talk(to: s); done() } }
            return i
        }
        let refresh = CPListItem(text: "Atualizar", detailText: nil)
        refresh.handler = { [weak self] _, done in Task { @MainActor in await self?.reload(); done() } }
        list.updateSections([CPListSection(items: items.isEmpty ? [CPListItem(text: jarvis.error ?? "Sem sessões abertas", detailText: nil)] : items),
                             CPListSection(items: [refresh])])
    }

    // MARK: conversa por voz

    private func talk(to s: Jarvis.Session) {
        let states = [("ouvir", "A ouvir…", "mic.fill"), ("pensar", "A trabalhar…", "ellipsis"), ("falar", "A responder…", "speaker.wave.2.fill")]
            .map { CPVoiceControlState(identifier: $0.0, titleVariants: [$0.1], image: UIImage(systemName: $0.2), repeats: true) }
        let t = CPVoiceControlTemplate(voiceControlStates: states)
        ic?.pushTemplate(t, animated: true, completion: nil)
        mic.callMode = true
        loop = Task {
            guard await mic.authorize() else { await voice.say("Ativa o microfone da Fala no iPhone."); return }
            voice.route(speaker: false) // no carro o som vai para as colunas do carro
            await voice.say("Estás na \(jarvis.title(s)). Diz.")
            while !Task.isCancelled {
                t.activateVoiceControlState(withIdentifier: "ouvir")
                let said = await listen()
                guard !Task.isCancelled else { break }
                if said.isEmpty { continue }
                t.activateVoiceControlState(withIdentifier: "pensar")
                await voice.say("Ok.")
                let reply = await jarvis.ask(s.id, said)
                guard !Task.isCancelled else { break }
                t.activateVoiceControlState(withIdentifier: "falar")
                await voice.say(SpokenSummary.make(reply, maxSentences: 3, maxWords: 60))
            }
        }
        // Voltar no ecrã do carro = acabar a conversa.
        ic?.delegate = self
    }

    /// Como no modo voz do iPhone: fala e 1,5 s sem palavras novas (máx. 25 s).
    private func listen() async -> String {
        mic.keepAudio = false; mic.start()
        var last = "", still = Date(); let began = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            if mic.text != last { last = mic.text; still = Date() }
            if !last.isEmpty, Date().timeIntervalSince(still) > 1.5 { break }
            if Date().timeIntervalSince(began) > 25 { break }
        }
        return await mic.stop().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopTalking() {
        loop?.cancel(); loop = nil; voice.stop(); mic.callMode = false
        Task { _ = await mic.stop() }
    }
}

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    nonisolated func templateDidDisappear(_ t: CPTemplate, animated: Bool) {
        Task { @MainActor in if t is CPVoiceControlTemplate { stopTalking() } }
    }
}
