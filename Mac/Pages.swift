import SwiftUI
import AppKit

// Abas do hub no layout do Wispr Flow (ecrãs 10 a 52 de research/wispr-mac/screens).

struct Pair: Identifiable { let k: String, v: String; var id: String { k } }

// MARK: Dicionário
struct DictionaryPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var modal: ModalCenter
    @AppStorage("hub.dictBanner") private var banner = true
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Dicionário") { Button("Adicionar") { add() }.buttonStyle(FlowButton()) }
            FlowTabs(items: [(0, "Todas"), (1, "Pessoal"), (2, "Partilhado com a equipa")], selection: $tab, trailing: AnyView(ListTools()))
            if banner {
                FlowBanner(title: .accent("A Fala escreve como ", "tu", " escreves."), onClose: { withAnimation(Flow.ease) { banner = false } }) {
                    (Text("Corrige uma palavra uma vez ou adiciona-a aqui, para que ") + Text("termos pessoais, jargão da empresa ou nomes invulgares").bold() + Text(" fiquem sempre bem escritos."))
                        .frame(maxWidth: 520, alignment: .leading)
                    HStack(spacing: 8) {
                        Button("Adicionar palavra") { add() }.buttonStyle(FlowButton(kind: .light))
                        ForEach(["Fala", Me.firstName, "Claude", "ChatGPT"].filter { !$0.isEmpty }, id: \.self) { w in
                            Button(w) { store.dictionary[w] = w }.buttonStyle(FlowButton(kind: .light)).opacity(0.75)
                        }
                    }.padding(.top, 8)
                }.transition(.opacity)
            }
            let items = tab == 2 ? [] : store.dictionary.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { Pair(k: $0.key, v: $0.value) }
            if items.isEmpty { EmptyList(icon: "character.book.closed", text: tab == 2 ? "Ainda não tens equipa." : "Ainda não tens palavras. Adiciona a primeira.") }
            else {
                CardList(items: items) { p in
                    HoverRow { h in
                        HStack {
                            if p.k == p.v { Text(p.k) } else { Text(p.k) + Text("  →  ").foregroundColor(Flow.fg3) + Text(p.v) }
                            Spacer()
                            Button { store.dictionary[p.k] = nil } label: { Image(systemName: "trash").foregroundStyle(Flow.fg3) }
                                .buttonStyle(.plain).opacity(h ? 1 : 0).help("Apagar")
                        }
                        .font(.figtree(14)).padding(.horizontal, 14).frame(height: 57)
                    }
                }
            }
        }
    }
    private func add() { modal.show(AddWordModal(store: store, close: modal.close)) }
}

struct ListTools: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass"); Image(systemName: "arrow.up.arrow.down"); Image(systemName: "arrow.triangle.2.circlepath")
        }.font(.system(size: 12)).foregroundStyle(Flow.fg3).padding(.bottom, 10)
    }
}

struct EmptyList: View {
    let icon: String, text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Flow.fg3)
            Text(text).font(.figtree(14)).foregroundStyle(Flow.fg3)
        }
        .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Adicionar ao vocabulário": palavra simples ou erro → correto.
struct AddWordModal: View {
    let store: Store
    let close: () -> Void
    @State private var correct = false
    @State private var team = false
    @State private var word = ""
    @State private var wrong = ""
    @State private var right = ""
    var valid: Bool { correct ? !wrong.isEmpty && !right.isEmpty : !word.isEmpty }
    var body: some View {
        ModalCard(width: correct ? 372 : 372) {
            Text("Adicionar ao vocabulário").font(.figtree(16, weight: 600)).padding(.bottom, 14)
            toggleRow("Corrigir um erro", $correct)
            toggleRow("Partilhar com a equipa", $team, disabled: true)
            Group {
                if correct {
                    HStack(spacing: 8) {
                        FlowField(placeholder: "Erro", text: $wrong)
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
                        FlowField(placeholder: "Escrita correta", text: $right)
                    }.transition(.opacity)
                } else {
                    FlowField(placeholder: "Adiciona uma palavra nova", text: $word).transition(.opacity)
                }
            }.padding(.top, 10)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar", action: close).buttonStyle(FlowButton(kind: .beige))
                Button("Adicionar palavra") {
                    if correct { store.dictionary[wrong] = right } else { store.dictionary[word] = word }
                    close()
                }.buttonStyle(FlowButton()).disabled(!valid).keyboardShortcut(.defaultAction)
            }.padding(.top, 16)
        }
        .animation(Flow.ease, value: correct)
    }
    private func toggleRow(_ t: String, _ b: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack {
            Text(t).font(.figtree(14)).foregroundStyle(disabled ? Flow.fg3 : Flow.fg)
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Flow.fg3)
            Spacer()
            FlowToggle(isOn: b, disabled: disabled)
        }.frame(height: 28)
    }
}

// MARK: Snippets
struct SnippetsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var modal: ModalCenter
    @AppStorage("hub.snipBanner") private var banner = true
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Snippets") { Button("Adicionar") { add() }.buttonStyle(FlowButton()) }
            FlowTabs(items: [(0, "Todos"), (1, "Pessoal"), (2, "Partilhado com a equipa")], selection: $tab, trailing: AnyView(ListTools()))
            if banner {
                FlowBanner(title: .accent("O que ", "tu", " não devias ter de reescrever."), tint: [Color(hex: 0x3a4a6a), Color(hex: 0x7a5a3a), Color(hex: 0x2c2c3c)], onClose: { withAnimation(Flow.ease) { banner = false } }) {
                    Text("Guarda texto que escreves muitas vezes, um email, uma apresentação ou um prompt, e diz uma palavra para o pôr lá num instante.")
                    VStack(alignment: .leading, spacing: 8) {
                        ex("o meu email", "o.teu.nome@email.com")
                        ex("prompt reescrever", "Reescreve isto de forma mais concisa...")
                        ex("email de apresentação", "Olá, gostava de marcar uma conversa...")
                    }.padding(.vertical, 4)
                    Button("Adicionar snippet") { add() }.buttonStyle(FlowButton(kind: .light))
                }.transition(.opacity)
            }
            let items = tab == 2 ? [] : store.snippets.sorted { $0.key < $1.key }.map { Pair(k: $0.key, v: $0.value) }
            if items.isEmpty { EmptyList(icon: "scissors", text: "Ainda não tens snippets.") }
            else {
                CardList(items: items) { p in
                    HoverRow { h in
                        HStack {
                            (Text(p.k) + Text(" → ").foregroundColor(Flow.fg3) + Text(p.v)).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Button { store.snippets[p.k] = nil } label: { Image(systemName: "trash").foregroundStyle(Flow.fg3) }.buttonStyle(.plain).opacity(h ? 1 : 0)
                        }
                        .font(.figtree(14)).padding(.horizontal, 14).frame(height: 44)
                    }
                }
            }
        }
    }
    private func ex(_ a: String, _ b: String) -> some View {
        HStack(spacing: 10) { Chip(text: "“\(a)”", italic: true); Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)); Chip(text: b) }
    }
    private func add() { modal.show(AddSnippetModal(store: store, close: modal.close)) }
}

struct AddSnippetModal: View {
    let store: Store
    let close: () -> Void
    @State private var team = false
    @State private var trigger = ""
    @State private var body_ = ""
    var body: some View {
        ModalCard(width: 520) {
            Text("Adicionar snippet").font(.figtree(16, weight: 600)).padding(.bottom, 14)
            HStack {
                Text("Partilhar com a equipa").font(.figtree(14)).foregroundStyle(Flow.fg3)
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Flow.fg3)
                Spacer(); FlowToggle(isOn: $team, disabled: true)
            }.frame(height: 28)
            FlowField(placeholder: "Snippet", text: $trigger).padding(.top, 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "bold"); Image(systemName: "italic"); Image(systemName: "list.bullet"); Image(systemName: "list.number"); Image(systemName: "link")
                }.font(.system(size: 12)).foregroundStyle(Flow.fg3).padding(10)
                Rectangle().fill(Flow.border).frame(height: 1)
                TextEditor(text: $body_).font(.figtree(14)).scrollContentBackground(.hidden).padding(8).frame(height: 140)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Flow.border))
            .padding(.top, 10)
            HStack {
                Text("\(body_.count)/4000").font(.figtree(12)).foregroundStyle(Flow.fg3)
                Spacer()
                Button("Cancelar", action: close).buttonStyle(FlowButton(kind: .beige))
                Button("Adicionar snippet") { store.snippets[trigger] = body_; close() }
                    .buttonStyle(FlowButton()).disabled(trigger.isEmpty || body_.isEmpty || body_.count > 4000)
            }.padding(.top, 16)
        }
    }
}

// MARK: Style
struct StylePage: View {
    @EnvironmentObject var store: Store
    @State private var tab = "personal"
    @AppStorage("fala.cleanup") private var cleanup = "Leve"
    private let tabs = [("personal", "Mensagens pessoais"), ("work", "Mensagens de trabalho"), ("email", "Email"), ("other", "Outros"), ("cleanup", "Limpeza automática")]
    private let styles = [("Formal.", "Maiúsculas + pontuação", "Olá, estás livre para almoçar amanhã? Pode ser às 12, se der para ti.", 0xf0d7ff, "Formal"),
                          ("Casual", "Maiúsculas + menos pontuação", "Olá estás livre para almoçar amanhã? Pode ser às 12 se der para ti", 0xffbcf2, "Casual"),
                          ("muito casual", "Sem maiúsculas + menos pontuação", "olá estás livre para almoçar amanhã? pode ser às 12 se der para ti", 0x7f1c34, "muito casual")]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Style")
            FlowTabs(items: tabs, selection: $tab, badges: ["cleanup": "Beta"])
            if tab == "cleanup" { cleanupView } else { styleView }
        }
        .animation(Flow.ease, value: tab)
    }

    private var key: String { "fala.style.\(tab)" }
    private var selected: String { UserDefaults.standard.string(forKey: key) ?? store.style }

    private var styleView: some View {
        VStack(alignment: .leading, spacing: 20) {
            FlowBanner(title: Text(bannerTitle)) {
                HStack(alignment: .top) {
                    Text("A formatação de estilo funciona em português e inglês.").frame(maxWidth: 320, alignment: .leading)
                    Spacer()
                    HStack(spacing: -8) {
                        ForEach(appIcons, id: \.self) { i in
                            Image(systemName: i).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34).background(Color.white.opacity(0.18), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(styles, id: \.0) { s in
                    let on = selected == s.4
                    Button {
                        UserDefaults.standard.set(s.4, forKey: key); store.style = s.4
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.0).font(.figtree(14, weight: 550)); Text(s.1).font(.figtree(14, weight: 550))
                            Spacer(minLength: 50)
                            Text(s.2).font(.figtree(14)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(hex: 0xfaf5ff), in: RoundedRectangle(cornerRadius: 8))
                            HStack { Spacer(); Text("J").font(.figtree(15, weight: 600)).foregroundStyle(s.3 == 0x7f1c34 ? .white : .white)
                                .frame(width: 36, height: 36).background(Color(hex: UInt32(s.3)), in: Circle()) }.padding(.top, 6)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 244, alignment: .topLeading)
                        .background(Flow.bg, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color(hex: 0xa26ec1) : Flow.border, lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var bannerTitle: String {
        switch tab { case "work": "Este estilo aplica-se em mensagens de trabalho"; case "email": "Este estilo aplica-se em email"; case "other": "Este estilo aplica-se em todas as outras apps"; default: "Este estilo aplica-se em mensagens pessoais" }
    }
    private var appIcons: [String] {
        switch tab { case "work": ["number", "bubble.left.and.bubble.right", "plus"]; case "email": ["envelope", "paperplane", "plus"]; case "other": ["doc.text", "note.text", "plus"]; default: ["message", "paperplane", "gamecontroller", "camera", "plus"] }
    }

    private var cleanupView: some View {
        VStack(alignment: .leading, spacing: 20) {
            FlowBanner(title: Text("A limpeza automática aplica-se a todos os teus ditados")) {
                Text("Escolhe o nível de limpeza aplicado automaticamente, em todas as apps.")
                Text("O teu ditado original nunca se perde. Vai aos três pontos de um ditado recente no Início e clica em \"Desfazer edição IA\".")
            }
            HStack(alignment: .top, spacing: 12) {
                level("Nenhuma", "Transcreve exatamente o que disseste, incluindo erros", "olá joão, ainda está de pé o café? acho que tipo devíamos sair mais cedo para chegar a tempo, hum, pode haver trânsito. o que achas?")
                level("Leve", "Limpa hesitações e gramática", "Olá João, ainda está de pé o café? Acho que devíamos sair mais cedo para chegar a tempo. Pode haver trânsito. O que achas?")
                level("Média", "Edita para ficar claro e conciso", "Olá João, o café mantém-se? Devíamos sair mais cedo, pode haver trânsito. O que achas?")
            }
        }
    }
    private func level(_ t: String, _ d: String, _ ex: String) -> some View {
        Button { cleanup = t } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(t).font(.garamond(26))
                Text(d).font(.figtree(13)).foregroundStyle(Flow.fg3)
                Spacer(minLength: 60)
                Text(ex).font(.figtree(12)).italic().padding(10).background(Color(hex: 0xfaf5ff), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(Flow.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(cleanup == t ? Flow.fg : Flow.border, lineWidth: cleanup == t ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).animation(Flow.ease, value: cleanup)
    }
}

// MARK: Transforms
struct TransformDef: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subtitle: String
    var prompt: String
    var key: Int
}

@MainActor final class TransformsStore: ObservableObject {
    static let shared = TransformsStore()
    static let defaults = [
        TransformDef(name: "Polish", subtitle: "Melhora a clareza e a concisão", prompt: "Corrige gramática e pontuação, remove hesitações e repetições, mantém o tom.", key: 1),
        TransformDef(name: "Prompt Engineer", subtitle: "Constrói prompts ótimos", prompt: "Reescreve como um prompt claro e estruturado para um assistente de IA.", key: 2)]
    @Published var items: [TransformDef] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: "fala.transforms") }
    }
    init() {
        items = (UserDefaults.standard.data(forKey: "fala.transforms")).flatMap { try? JSONDecoder().decode([TransformDef].self, from: $0) } ?? Self.defaults
    }
}

struct TransformsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var modal: ModalCenter
    @StateObject private var tf = TransformsStore.shared
    @AppStorage("fala.tf.optin") private var optIn = true
    @AppStorage("fala.tf.auto") private var auto = false
    @AppStorage("fala.tf.autoName") private var autoName = "Polish"
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Transforms", badge: "Beta") {
                HStack(spacing: 8) {
                    Text("Ativar").font(.figtree(14)); Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Flow.fg3)
                    FlowToggle(isOn: $optIn)
                    HStack(spacing: 4) { Keycap(text: "⌥ Opt"); Keycap(text: "o"); Text("para ver alterações").font(.figtree(13)) }
                        .padding(.horizontal, 8).frame(height: 30).overlay(Capsule().strokeBorder(Flow.border))
                }
            }
            FlowBanner(title: Text("A Transform funciona onde escreves"), tint: [Color(hex: 0x4a3a5a), Color(hex: 0x3a3a3a), Color(hex: 0x6b4a2a)]) {
                Text("Aplica uma Transform para reescrever, limpar ou reorganizar texto depois de ditares. Corre no teu Mac, grátis.").frame(maxWidth: 380, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Experimentar") { open(tf.items[0]) }.buttonStyle(FlowButton(kind: .light, small: true))
                    Button("Como funciona") {}.buttonStyle(FlowButton(kind: .ghost, small: true)).foregroundStyle(.white).colorScheme(.dark)
                }.padding(.top, 8)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aplicar automaticamente depois do ditado").font(.figtree(14, weight: 550))
                    Text("Corre uma Transform em tudo o que ditas, automaticamente.").font(.figtree(12)).foregroundStyle(Flow.fg3)
                }
                Spacer()
                Picker("", selection: $autoName) { ForEach(tf.items) { Text($0.name).tag($0.name) } }.labelsHidden().frame(width: 160)
                FlowToggle(isOn: $auto)
            }
            HStack {
                Text("As minhas Transforms").font(.garamond(26))
                Spacer()
                Button { tf.items = TransformsStore.defaults } label: { Label("Repor predefinições", systemImage: "arrow.counterclockwise") }.buttonStyle(FlowButton(kind: .ghost, small: true))
                Button("Criar nova") { create() }.buttonStyle(FlowButton(small: true))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(tf.items) { t in card(keys: ["⌥ Opt", "\(t.key)"], t.name, t.subtitle) { open(t) } }
                card(keys: ["+"], "Cria a tua", "Escreve o teu próprio prompt") { create() }
            }
        }
    }
    private func card(keys: [String], _ t: String, _ d: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) { ForEach(keys, id: \.self) { Keycap(text: $0) } }.padding(.bottom, 14)
                Text(t).font(.figtree(14, weight: 550))
                Text(d).font(.figtree(13)).foregroundStyle(Flow.fg3)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(Flow.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Flow.border))
            .contentShape(Rectangle())
        }.buttonStyle(LiftStyle())
    }
    private func open(_ t: TransformDef) { modal.show(TransformDetail(t: t, sample: store.entries.first?.text, close: modal.close)) }
    private func create() { modal.show(CreateTransformModal(close: modal.close)) }
}

struct LiftStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1).animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Detalhe de 2 colunas (como o "Polish" do Flow): exemplo à esquerda, regras à direita.
struct TransformDetail: View {
    @State var t: TransformDef
    let sample: String?
    let close: () -> Void
    @State private var rules = [("Mais conciso", true), ("Reformular para clareza", true), ("Reordenar para ler melhor", true), ("Dar estrutura", true), ("Manter o teu tom", true)]
    @State private var output = ""
    @State private var busy = false
    var input: String { sample ?? "olha então sobre os slides que eu juntei não sei se encaixam na tua parte parece-me um bocado longo se calhar tirávamos as tendências de mercado" }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(t.name).font(.garamond(34))
                HStack(spacing: 4) { Keycap(text: "⌥ Opt"); Keycap(text: "\(t.key)"); Text("para usar").font(.figtree(13)) }
                    .padding(6).background(Flow.bg3, in: RoundedRectangle(cornerRadius: 8))
                Text(t.subtitle + ".").font(.figtree(14))
                Rectangle().fill(Flow.border).frame(height: 1)
                Text(output.isEmpty ? "Exemplo de texto" : "Depois da Transform").font(.figtree(14, weight: 600))
                ScrollView { Text(output.isEmpty ? input : output).font(.figtree(14)).foregroundStyle(output.isEmpty ? Flow.fg3 : Flow.fg).lineSpacing(5).textSelection(.enabled) }
                Button(busy ? "A transformar…" : "Ver alterações") {
                    busy = true
                    let instr = t.prompt + " " + rules.filter(\.1).map(\.0).joined(separator: ". ")
                    Task { output = await LocalAI.run(instr, on: input); busy = false }
                }.buttonStyle(FlowButton(kind: busy ? .beige : .black)).frame(maxWidth: .infinity).disabled(busy)
            }
            .padding(20).frame(width: 300).frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Flow.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Spacer(); Text("Gravação automática").font(.figtree(12)).foregroundStyle(Flow.fg3); Button("Fechar", action: close).buttonStyle(FlowButton(kind: .ghost, small: true)) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Escolhe um atalho").font(.figtree(14, weight: 550))
                    HStack { Keycap(text: "⌥ Opt"); Keycap(text: "\(t.key)"); Spacer(); Image(systemName: "pencil").foregroundStyle(Flow.fg3) }
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }.padding(14).background(Flow.bg3, in: RoundedRectangle(cornerRadius: 10))
                Text("Regras para \(t.name)").font(.figtree(14, weight: 550))
                SettingGroup {
                    ForEach(rules.indices, id: \.self) { i in
                        SettingRow(title: rules[i].0) { FlowToggle(isOn: $rules[i].1) }
                        if i < rules.count - 1 { RowDivider() }
                    }
                }
                Text("Personaliza o prompt").font(.figtree(14, weight: 550))
                TextEditor(text: $t.prompt).font(.figtree(13)).scrollContentBackground(.hidden).padding(8).frame(height: 70)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Flow.border))
                    .onChange(of: t.prompt) { _, _ in save() }
            }
            .padding(20)
        }
        .foregroundStyle(Flow.fg).environment(\.colorScheme, .light)
        .frame(width: 860, height: 600)
        .background(Flow.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 25, y: 20)
    }
    private func save() {
        let s = TransformsStore.shared
        if let i = s.items.firstIndex(where: { $0.id == t.id }) { s.items[i] = t }
    }
}

struct CreateTransformModal: View {
    let close: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    var body: some View {
        ModalCard(width: 520) {
            Text("Cria a tua Transform").font(.garamond(28)).padding(.bottom, 14)
            Text("Dá um nome à tua Transform").font(.figtree(14, weight: 550)).padding(.bottom, 6)
            FlowField(placeholder: "Modo chefe", text: $name)
            Text("Personaliza o prompt").font(.figtree(14, weight: 550)).padding(.top, 14).padding(.bottom, 6)
            TextEditor(text: $prompt).font(.figtree(14)).scrollContentBackground(.hidden).padding(8).frame(height: 120)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(alignment: .topLeading) {
                    if prompt.isEmpty { Text("Como queres que esta Transform mude o teu texto?").font(.figtree(14)).foregroundStyle(Flow.fg3).padding(13).allowsHitTesting(false) }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Flow.border))
            HStack {
                Spacer()
                Button("Cancelar", action: close).buttonStyle(FlowButton(kind: .beige))
                Button("Criar") {
                    let s = TransformsStore.shared
                    s.items.append(TransformDef(name: name, subtitle: "Transform tua", prompt: prompt, key: (s.items.map(\.key).max() ?? 0) + 1))
                    close()
                }.buttonStyle(FlowButton()).disabled(name.isEmpty || prompt.isEmpty)
            }.padding(.top, 16)
        }
    }
}

// MARK: Insights
struct InsightsPage: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Insights") { ShareBadge() }
            FlowTabs(items: [(0, "A tua utilização"), (1, "A tua voz")], selection: $tab)
            if tab == 0 { usage } else { voice }
        }
    }
    private var usage: some View {
        let mac = store.entries.filter { !$0.toMac }.reduce(0) { $0 + $1.words }
        let phone = store.totalWords - mac
        return VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                card {
                    big("\(store.wpm)", "PALAVRAS POR MINUTO")
                    Gauge(value: min(1, Double(store.wpm) / 220)).frame(width: 120, height: 66).frame(maxWidth: .infinity).padding(.top, 6)
                }
                card {
                    big("\(store.dictionary.count + store.snippets.count)", "CORREÇÕES DA FALA")
                    Rectangle().fill(Flow.border).frame(height: 1).padding(.vertical, 8)
                    Text("\(store.dictionary.count) palavras no dicionário").font(.figtree(13))
                    Text("\(store.snippets.count) snippets").font(.figtree(13))
                }
                card {
                    big(store.totalWords.formatted(), "TOTAL DE PALAVRAS DITADAS")
                    Rectangle().fill(Flow.border).frame(height: 1).padding(.vertical, 8)
                    HStack {
                        VStack(alignment: .leading) { Label("Mac", systemImage: "desktopcomputer").font(.figtree(13)); Text("\(mac) palavras").font(.figtree(13)) }
                        Spacer()
                        VStack(alignment: .leading) { Label("iPhone", systemImage: "iphone").font(.figtree(13)); Text("\(phone) palavras").font(.figtree(13)) }
                    }
                }.frame(minWidth: 300)
            }
            HStack(alignment: .top, spacing: 16) {
                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Utilização").font(.figtree(22, weight: 550)); Spacer()
                        Text("DISPOSITIVOS | 2").font(.figtree(11, weight: 600)).kerning(0.8)
                    }.padding(.bottom, 10)
                    let total = max(1, store.totalWords)
                    bar("desktopcomputer", Double(mac) / Double(total), "\(store.entries.filter { !$0.toMac }.count) DITADOS NO MAC")
                    bar("iphone", Double(phone) / Double(total), "\(store.entries.filter(\.toMac).count) DITADOS DO IPHONE")
                    bar("scissors", 0, "\(store.snippets.count) SNIPPETS")
                    bar("character.book.closed", 0, "\(store.dictionary.count) PALAVRAS")
                }
                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(store.streak) \(store.streak == 1 ? "dia seguido" : "dias seguidos")").font(.figtree(22, weight: 550)); Spacer()
                        Text("MAIOR SEQUÊNCIA | \(longest) DIAS").font(.figtree(11, weight: 600)).kerning(0.8)
                    }.padding(.bottom, 10)
                    Heatmap(counts: dayCounts)
                }
            }
        }
    }
    private var dayCounts: [Date: Int] {
        Dictionary(grouping: store.entries) { Calendar.current.startOfDay(for: $0.date) }.mapValues { $0.reduce(0) { $0 + $1.words } }
    }
    private var longest: Int {
        let cal = Calendar.current
        let days = Set(dayCounts.keys).sorted()
        var best = 0, run = 0, prev: Date?
        for d in days { run = (prev.map { cal.dateComponents([.day], from: $0, to: d).day == 1 } ?? false) ? run + 1 : 1; best = max(best, run); prev = d }
        return best
    }
    private var voice: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("O teu perfil de voz").font(.garamond(52))
            Text("Os teus ditados são privados e ficam guardados só neste Mac. Quando tiveres 2000 palavras, a Fala mostra-te como falas: palavras favoritas, ritmo e tom.").font(.figtree(15)).foregroundStyle(Flow.fg3).frame(maxWidth: 520, alignment: .leading)
            ProgressView(value: min(1, Double(store.totalWords) / 2000)).tint(Color(hex: 0xa26ec1)).frame(maxWidth: 420)
            Text("\(min(store.totalWords, 2000)) de 2000 palavras").font(.figtree(13)).foregroundStyle(Flow.fg3)
        }.padding(.top, 20)
    }
    private func card(@ViewBuilder _ c: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2, content: c).padding(14).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 10))
    }
    private func big(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.figtree(24, weight: 550)).contentTransition(.numericText())
            Text(l).font(.figtree(10, weight: 600)).kerning(0.8).foregroundStyle(Flow.fg3)
        }
    }
    private func bar(_ icon: String, _ f: Double, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
            Text("\(Int(f * 100))%").font(.figtree(10, weight: 600)).foregroundStyle(.white)
                .frame(width: max(28, 160 * f), height: 20).background(Color(hex: f > 0.5 ? 0x2f5f5c : 0x68bdb0), in: RoundedRectangle(cornerRadius: 3))
            Text(LocalizedStringKey(label)).font(.figtree(10, weight: 600)).kerning(0.6)
        }.frame(height: 30)
    }
}

struct ShareBadge: View {
    @State private var rot = 0.0
    var body: some View {
        ZStack {
            ForEach(Array("PARTILHAR • PARTILHAR • ".enumerated()), id: \.offset) { i, c in
                Text(String(c)).font(.figtree(7, weight: 600)).offset(y: -20).rotationEffect(.degrees(Double(i) * 15))
            }.rotationEffect(.degrees(rot))
            Image(systemName: "square.and.arrow.up").font(.system(size: 13))
        }
        .frame(width: 48, height: 48).background(Flow.bg3, in: Circle())
        .onAppear { withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) { rot = 360 } }
    }
}

/// Gauge semicircular verde-petróleo do WPM.
struct Gauge: View {
    var value: Double
    @State private var shown = 0.0
    var body: some View {
        ZStack {
            Arc(to: 1).stroke(Flow.border, style: .init(lineWidth: 10, lineCap: .round))
            Arc(to: shown).stroke(Color(hex: 0x2f5f5c), style: .init(lineWidth: 10, lineCap: .round))
            VStack(spacing: 0) { Text("Top").font(.figtree(11)); Text("\(Int(max(1, (1 - value) * 100)))%").font(.figtree(15, weight: 550)) }.offset(y: 10)
        }
        .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.9)) { shown = value } }
    }
}
struct Arc: Shape {
    var to: Double
    var animatableData: Double { get { to } set { to = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: .init(x: r.midX, y: r.maxY), radius: r.width / 2 - 5, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * to), clockwise: false)
        return p
    }
}

/// Heatmap tipo GitHub: 16 semanas, quadrados 14px radius 3, legenda Mais/Menos.
struct Heatmap: View {
    let counts: [Date: Int]
    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(7 * 15 + cal.component(.weekday, from: today) - 1), to: today)!
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"], id: \.self) { Text($0).font(.figtree(9)).foregroundStyle(Flow.fg3).frame(height: 14) }
                }
                ForEach(0..<16, id: \.self) { w in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            RoundedRectangle(cornerRadius: 3).fill(color(counts[day] ?? 0, future: day > today)).frame(width: 14, height: 14)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Mais").font(.figtree(10)).foregroundStyle(Flow.fg3)
                ForEach([0x2f5f5c, 0x369489, 0x68bdb0, 0xc6e8e2] as [UInt32], id: \.self) { RoundedRectangle(cornerRadius: 3).fill(Color(hex: $0)).frame(width: 12, height: 12) }
                Text("Menos").font(.figtree(10)).foregroundStyle(Flow.fg3)
            }.padding(.top, 8)
        }
    }
    private func color(_ n: Int, future: Bool) -> Color {
        if future { return Flow.border.opacity(0.4) }
        switch n { case 0: return Color(hex: 0xdcd9d0); case ..<50: return Color(hex: 0xc6e8e2); case ..<200: return Color(hex: 0x68bdb0); case ..<500: return Color(hex: 0x369489); default: return Color(hex: 0x2f5f5c) }
    }
}

// MARK: Notetaker
struct NotetakerPage: View {
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @State private var summary = ""
    @State private var busy = false
    @State private var tab = 0
    @AppStorage("fala.notes") private var notesData = Data()
    private var notes: [Pair] { ((try? JSONDecoder().decode([String: String].self, from: notesData)) ?? [:]).sorted { $0.key > $1.key }.map { Pair(k: $0.key, v: $0.value) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Notetaker") {
                Image(systemName: "gearshape").foregroundStyle(Flow.fg3)
                Button { toggle() } label: {
                    Label(mic.isRecording ? "Parar e resumir" : "Iniciar Notetaker", systemImage: mic.isRecording ? "stop.circle" : "record.circle")
                }.buttonStyle(NotetakerButton(recording: mic.isRecording))
            }
            VStack(alignment: .leading, spacing: 12) {
                if mic.isRecording || !mic.text.isEmpty || busy || !summary.isEmpty {
                    HStack { Text("Nova nota").font(.garamond(28)).foregroundStyle(Flow.fg3); Text("Hoje").font(.figtree(12, weight: 550)).padding(.horizontal, 8).padding(.vertical, 3).background(.white, in: Capsule()) }
                    if mic.isRecording { HStack(spacing: 6) { Circle().fill(Color(hex: 0x10b981)).frame(width: 7); Text("A ouvir…").font(.figtree(13)).foregroundStyle(Flow.fg3) } }
                    Text(mic.text.isEmpty ? " " : mic.text).font(.figtree(14)).frame(maxWidth: .infinity, alignment: .leading)
                    if busy { ProgressView().controlSize(.small) }
                    if !summary.isEmpty { Text(summary).font(.figtree(14)).textSelection(.enabled).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 8)) }
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Flow.bg2).frame(width: 260, height: 18)
                    RoundedRectangle(cornerRadius: 6).fill(Flow.bg2).frame(width: 340, height: 10)
                    RoundedRectangle(cornerRadius: 6).fill(Flow.bg2).frame(width: 110, height: 22).padding(.top, 8)
                }
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 12))
            .animation(Flow.ease, value: mic.isRecording)
            VStack(spacing: 10) {
                Text("HOJE").font(.figtree(11, weight: 600)).kerning(0.8).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(Flow.fg3)
                Text("Sem reuniões").font(.figtree(16, weight: 550))
                Text("Grava uma conversa ou uma ideia longa. No fim, a Fala resume no teu Mac.").font(.figtree(14)).foregroundStyle(Flow.fg3)
            }
            .padding(18).frame(maxWidth: .infinity).background(Flow.bg3, in: RoundedRectangle(cornerRadius: 12))
            FlowTabs(items: [(0, "Notas anteriores"), (1, "Partilhadas comigo")], selection: $tab, trailing: AnyView(Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Flow.fg3).padding(.bottom, 10)))
            if notes.isEmpty || tab == 1 { EmptyList(icon: "doc.text", text: "As tuas reuniões vão aparecer aqui") }
            else {
                CardList(items: notes) { n in
                    HoverRow { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.k).font(.figtree(13, weight: 550)).foregroundStyle(Flow.fg3)
                            Text(n.v).font(.figtree(14)).lineLimit(3).textSelection(.enabled)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let e = mic.error { Text(e).font(.figtree(13)).foregroundStyle(.red) }
        }
    }
    private func toggle() {
        Task {
            if mic.isRecording {
                let t = await mic.stop()
                guard !t.isEmpty else { return }
                store.add(t, seconds: mic.seconds)
                busy = true; summary = await LocalAI.run("Resume em 3 a 5 pontos e lista as tarefas no fim.", on: t); busy = false
                var d = (try? JSONDecoder().decode([String: String].self, from: notesData)) ?? [:]
                d[Date().formatted(.dateTime.day().month().year().hour().minute().locale(Locale(identifier: "pt_PT")))] = summary.isEmpty ? t : summary
                notesData = (try? JSONEncoder().encode(d)) ?? Data()
            } else { summary = ""; mic.start() }
        }
    }
}

struct NotetakerButton: ButtonStyle {
    var recording: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.figtree(13, weight: 550)).foregroundStyle(Flow.fg)
            .padding(.horizontal, 10).frame(height: 28)
            .background(recording ? Color(hex: 0xfde2e2) : Color(hex: 0xfdf0dc), in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

// MARK: Scratchpad
struct ScratchpadPage: View {
    @EnvironmentObject var store: Store
    @AppStorage("fala.scratch.bar") private var inBar = false
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Scratchpad", badge: "Beta") {
                Text("Adicionar ao pill").font(.figtree(14)); FlowToggle(isOn: $inBar)
            }
            FlowBanner(title: Text("Para ideias rápidas a que queres voltar"), tint: [Color(hex: 0x7a5a3a), Color(hex: 0x4a3a2a), Color(hex: 0x9a7a4a)]) {
                Text("Uma lista de tarefas, uma mensagem para polir antes de enviar, um despejo de ideias. O Scratchpad é o teu espaço seguro para guardar, criar e explorar.").frame(maxWidth: 520, alignment: .leading)
                Button("Começar nota nova") { editing = true }.buttonStyle(FlowButton(kind: .light, small: true)).padding(.top, 6)
            }
            HStack { Text("Recentes").font(.figtree(14, weight: 550)); Spacer(); ListTools() }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sem título").font(.figtree(14, weight: 550))
                TextEditor(text: $store.scratchpad).font(.figtree(14)).scrollContentBackground(.hidden).frame(minHeight: editing ? 320 : 90)
            }
            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Flow.border))
            .animation(Flow.ease, value: editing)
        }
    }
}
