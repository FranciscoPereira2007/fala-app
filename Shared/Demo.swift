import Foundation

/// Modo de demonstração para capturas (App Store e site): `-fala.demo YES` nos argumentos de arranque.
/// Só dados de exemplo, nunca dados reais; fora deste modo nada aqui é usado.
enum Demo {
    static var on: Bool { UserDefaults.standard.bool(forKey: "fala.demo") }
    /// Ecrã a abrir logo (capturas): "chat", "remoto", "contas", "teclado".
    static var open: String { on ? UserDefaults.standard.string(forKey: "fala.demoOpen") ?? "" : "" }

    static let listening = "Olá Marta, a reunião de amanhã fica para as 16h. Levo a proposta revista e os números do trimestre."

    static var entries: [Entry] {
        let now = Date()
        return [
            Entry(text: "Obrigado pela reunião de hoje, ficou tudo claro. Envio a proposta até sexta.", date: now.addingTimeInterval(-600), toMac: true, seconds: 6),
            Entry(text: "Abre o terminal e corre outra vez só os testes do login.", date: now.addingTimeInterval(-3600), toMac: true, seconds: 4),
            Entry(text: "Lembrete: ligar ao contabilista na segunda de manhã.", date: now.addingTimeInterval(-7200), seconds: 3),
            Entry(text: "Já estou a caminho, chego daqui a 10 minutos.", date: now.addingTimeInterval(-86400), toMac: true, seconds: 2),
        ]
    }

    static var sessions: [Jarvis.Session] {
        let now = Date()
        return [
            .init(id: "demo-1", kind: .claude, name: "Site da loja", cwd: "/Users/demo/Developer/loja", status: "busy", updatedAt: now.addingTimeInterval(-40),
                  pid: nil, lastReply: "A rever o checkout: já corrigi o botão de pagar no telemóvel.", canSend: true),
            .init(id: "demo-2", kind: .codex, name: "API de reservas", cwd: "/Users/demo/Developer/reservas", status: "idle", updatedAt: now.addingTimeInterval(-900),
                  pid: nil, lastReply: "Feito. Os 42 testes passam e o deploy está pronto.", canSend: true),
            .init(id: "demo-3", kind: .claude, name: "Relatório mensal", cwd: "/Users/demo/Documents/relatorios", status: "permission", updatedAt: now.addingTimeInterval(-120),
                  pid: nil, lastReply: "Posso apagar os ficheiros temporários da pasta exportar?", canSend: true),
        ]
    }

    static var messages: [Jarvis.Message] {
        let now = Date()
        return [
            .init(id: "m1", role: "user", text: "O botão de pagar fica escondido no iPhone pequeno, consegues ver?", at: now.addingTimeInterval(-300)),
            .init(id: "m2", role: "tool", text: "Read · Checkout.tsx", at: now.addingTimeInterval(-280)),
            .init(id: "m3", role: "agent", text: "Encontrei: o rodapé fixo tapava o botão abaixo de 700 px de altura. Passei-o para dentro da área segura e testei:\n\n| Ecrã | Antes | Agora |\n|---|---|---|\n| iPhone SE | escondido | **visível** |\n| iPhone 17 | visível | visível |\n| iPad | visível | visível |", at: now.addingTimeInterval(-200)),
            .init(id: "m4", role: "user", text: "Perfeito. Faz o mesmo na página do carrinho.", at: now.addingTimeInterval(-60)),
            .init(id: "m5", role: "agent", text: "A rever o checkout: já corrigi o botão de pagar no telemóvel.", at: now.addingTimeInterval(-40)),
        ]
    }
}
