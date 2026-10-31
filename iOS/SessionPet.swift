import SwiftUI

/// O pet de cada sessão (arte local em Shared/Pets.bundle/<id>.png:
/// linha 0 idle, 1 waiting, 2 running; 6 frames de 96x104). A trabalhar: mexe-se. Parada: cara de quem espera por ti.
struct SessionPet: View {
    var id: String
    var busy: Bool
    var active = true
    var needsYou = false
    @AppStorage(Mascot.preference) private var selection = ""
    /// Pet fixo por sessão, sem repetir enquanto houver livres. ponytail: 12 pets; a 13.ª sessão recicla o mais antigo.
    private static let order = [8, 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11]
    @MainActor static func slot(_ id: String) -> Int {
        var map = UserDefaults.standard.dictionary(forKey: "pet.slots") as? [String: Int] ?? [:]
        if let n = map[id] { return n }
        let used = Set(map.values)
        let n = order.first { !used.contains($0) } ?? order[map.count % 12]
        if map.count >= 12 { map = [:] }
        map[id] = n; UserDefaults.standard.set(map, forKey: "pet.slots"); return n
    }
    var body: some View {
        if let pet = Mascot.resolve(selection, session: id) {
            ZStack {
                if needsYou { Circle().fill(Theme.orange.opacity(0.2)).frame(width: 46, height: 46) }
                MascotPreview(id: pet.id, row: !active ? 0 : busy ? 2 : 1, animated: active)
                    .frame(width: 44, height: 48).opacity(active ? 1 : 0.5)
                if needsYou {
                    Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(Theme.orange, in: Circle()).offset(x: 17, y: -19)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pet.name + ": " + (!active ? "A descansar" : needsYou ? "Precisa de ti" : busy ? "A trabalhar" : "À espera de ti"))
        } else {
            CodePet(seed: Self.slot(id), busy: busy, active: active, needsYou: needsYou)
        }
    }
}

/// 12 pets desenhados em código (família do Jarvis): bolinha macia em tons pastel, olhos brilhantes, bochechas.
/// A trabalhar: saltita com squash e olhos a varrer, concentrado. À espera: balança devagar, pisca e olha para
/// cima com um sorriso ("então?"). Precisa de ti: acena com halo laranja. Antiga: a dormir.
struct CodePet: View {
    var seed: Int, busy: Bool, active: Bool, needsYou = false
    static let palette: [(Color, Color)] = [ // (cima, baixo)
        (.init(red: 0.55, green: 0.72, blue: 1), .init(red: 0.3, green: 0.5, blue: 1)),     // azul Jarvis
        (.init(red: 1, green: 0.78, blue: 0.55), .init(red: 1, green: 0.58, blue: 0.3)),    // raposa
        (.init(red: 0.82, green: 0.72, blue: 1), .init(red: 0.62, green: 0.5, blue: 0.98)), // lilás
        (.init(red: 0.6, green: 0.92, blue: 0.82), .init(red: 0.3, green: 0.78, blue: 0.66)), // menta
        (.init(red: 1, green: 0.75, blue: 0.85), .init(red: 1, green: 0.55, blue: 0.72)),   // rosa
        (.init(red: 1, green: 0.9, blue: 0.55), .init(red: 1, green: 0.76, blue: 0.3)),     // amarelo
        (.init(red: 0.7, green: 0.9, blue: 0.6), .init(red: 0.45, green: 0.78, blue: 0.4)), // sapo
        (.init(red: 0.6, green: 0.88, blue: 1), .init(red: 0.35, green: 0.72, blue: 0.95)), // céu
        (.init(red: 1, green: 0.68, blue: 0.62), .init(red: 0.98, green: 0.45, blue: 0.42)), // coral
        (.init(red: 0.85, green: 0.75, blue: 0.65), .init(red: 0.7, green: 0.55, blue: 0.42)), // urso
        (.init(white: 0.98), .init(red: 0.86, green: 0.88, blue: 0.94)),                     // fantasma
        (.init(red: 0.5, green: 0.52, blue: 0.62), .init(red: 0.3, green: 0.32, blue: 0.42)) // gato cinza
    ]
    private static let ink = Color(red: 0.16, green: 0.15, blue: 0.22)
    var body: some View {
        let (top, bottom) = Self.palette[seed % 12], kind = seed % 6
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { t in
            let s = t.date.timeIntervalSinceReferenceDate + Double(seed) * 0.37
            let hop = busy ? max(0, sin(s * 8)) : 0                    // salto (só para cima)
            let squash = busy ? (1 - hop) * 0.16 : sin(s * 1.8) * 0.025 // achata ao aterrar / respira
            let sway = busy ? sin(s * 4) * 7 : sin(s * 1.2) * (needsYou ? 6 : 3) // a trabalhar abana; à espera balança
            let wave = sin(s * (needsYou ? 9 : 3))                       // braço no ar à espera
            ZStack {
                if needsYou { Circle().fill(Theme.orange.opacity(0.18 + 0.1 * sin(s * 4))).frame(width: 46, height: 46) }
                Ellipse().fill(Color.black.opacity(0.08)).frame(width: 26 - hop * 6, height: 4).offset(y: 21) // sombra no chão
                ZStack {
                    ears(kind, top, bottom).offset(y: 3) // por trás e a entrar no corpo
                    HStack(spacing: 11) { ForEach(0..<2) { _ in Ellipse().fill(bottom).frame(width: 10, height: 6) } }.offset(y: 31 * (1 - squash) / 2 - 2.5)
                    arms(s, bottom, wave)
                    Ellipse()
                        .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .topLeading) { Ellipse().fill(.white.opacity(0.55)).frame(width: 9, height: 5).rotationEffect(.degrees(-25)).offset(x: 7, y: 5) }
                        .frame(width: 34 * (1 + squash), height: 31 * (1 - squash))
                        .shadow(color: bottom.opacity(0.35), radius: 3, y: 2)
                    face(s, lid: top).offset(y: 1)
                }
                .offset(y: -hop * 8)
                .rotationEffect(.degrees(sway), anchor: .bottom)
                if active && !busy { // balão: "?" à espera de uma ordem, "!" quando precisa de ti
                    Text(needsYou ? "!" : "?").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(needsYou ? .white : Self.ink)
                        .frame(width: 15, height: 15).background(needsYou ? Theme.orange : .white, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                        .scaleEffect(1 + 0.08 * sin(s * 3)).offset(x: 17, y: -19)
                }
                if busy { // faíscas de esforço
                    ForEach(0..<2) { i in
                        Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.orange)
                            .opacity(max(0, sin(s * 5 + Double(i) * 2.5))).offset(x: i == 0 ? -20 : 20, y: -14 + Double(i) * 4)
                    }
                }
            }
            .frame(width: 46, height: 48)
        }
        .saturation(active ? 1 : 0.4).opacity(active ? 1 : 0.7)
        .accessibilityLabel(busy ? "A trabalhar" : needsYou ? "Precisa de ti" : "À espera de ti")
    }

    /// Bracinhos: a trabalhar batem como quem escreve; à espera, um no ar ("eu, eu!"), o outro em baixo.
    @ViewBuilder private func arms(_ s: Double, _ c: Color, _ wave: Double) -> some View {
        if !active || busy {
            HStack(spacing: 28) {
                Ellipse().fill(c).frame(width: 7, height: 9).rotationEffect(.degrees(busy ? -20 + sin(s * 16) * 25 : 0))
                Ellipse().fill(c).frame(width: 7, height: 9).rotationEffect(.degrees(busy ? 20 - sin(s * 16 + 1.5) * 25 : 0))
            }.offset(y: 5)
        } else {
            ZStack {
                Ellipse().fill(c).frame(width: 7, height: 9).offset(x: -16, y: 6)
                Capsule().fill(c).frame(width: 6.5, height: 13).rotationEffect(.degrees(25 + wave * 18), anchor: .bottom).offset(x: 16, y: -6)
            }
        }
    }

    @ViewBuilder private func ears(_ k: Int, _ top: Color, _ bottom: Color) -> some View {
        switch k {
        case 1: // gato/raposa: orelhas redondinhas com interior rosa
            HStack(spacing: 10) { ForEach(0..<2) { i in
                RoundedTriangle().fill(top).frame(width: 12, height: 12).overlay { RoundedTriangle().fill(Color.pink.opacity(0.35)).frame(width: 6, height: 6).offset(y: 2) }
                    .rotationEffect(.degrees(i == 0 ? -12 : 12))
            } }.offset(y: -17.5)
        case 2: // antena com bolinha a brilhar
            Capsule().fill(bottom).frame(width: 2.5, height: 9)
                .overlay(alignment: .top) { Circle().fill(Theme.orange).frame(width: 6, height: 6).shadow(color: Theme.orange, radius: 2).offset(y: -4) }.offset(y: -19)
        case 3: // coelho
            HStack(spacing: 7) { ForEach(0..<2) { i in
                Capsule().fill(top).frame(width: 8, height: 17).overlay { Capsule().fill(Color.pink.opacity(0.35)).frame(width: 3.5, height: 11) }
                    .rotationEffect(.degrees(i == 0 ? -10 : 10))
            } }.offset(y: -19)
        case 4: // rebento
            HStack(spacing: -2) {
                Ellipse().fill(Color(red: 0.45, green: 0.8, blue: 0.4)).frame(width: 8, height: 5).rotationEffect(.degrees(-30))
                Ellipse().fill(Color(red: 0.35, green: 0.72, blue: 0.35)).frame(width: 8, height: 5).rotationEffect(.degrees(30))
            }.offset(y: -17)
        case 5: // urso
            HStack(spacing: 16) { ForEach(0..<2) { _ in Circle().fill(bottom).frame(width: 11).overlay { Circle().fill(top).frame(width: 5) } } }.offset(y: -13)
        default: EmptyView()
        }
    }

    @ViewBuilder private func face(_ s: Double, lid: Color) -> some View {
        let blink = Int(s * 8) % 29 == 0
        VStack(spacing: 2.5) {
            HStack(spacing: 9) {
                ForEach(0..<2) { _ in
                    if !active { Arc(up: false).stroke(Self.ink, style: .init(lineWidth: 1.6, lineCap: .round)).frame(width: 6, height: 3) } // a dormir
                    else if blink { Capsule().fill(Self.ink).frame(width: 6, height: 1.6) }
                    else {
                        Ellipse().fill(Self.ink).frame(width: busy ? 5 : 6, height: busy ? 5.5 : 7.5)
                            .overlay(alignment: .topTrailing) { Circle().fill(.white).frame(width: 2.2).offset(x: -0.6, y: 0.8) }
                            .overlay(alignment: .top) { if !busy && !needsYou { Rectangle().fill(lid).frame(height: 3.4) } } // pálpebra a meio: "estou à espera…"
                            .clipShape(Ellipse())
                            .offset(x: busy ? sin(s * 3.2) * 1.8 : 0, y: busy ? 1 : 0) // a varrer o ecrã
                    }
                }
            }
            ZStack { // bochechas + boca
                HStack(spacing: 15) { ForEach(0..<2) { _ in Ellipse().fill(Color.pink.opacity(0.45)).frame(width: 6, height: 3.5) } }
                if busy { Capsule().fill(Self.ink).frame(width: 3.5, height: 1.4) }
                else if needsYou { Ellipse().fill(Self.ink).frame(width: 3.2, height: 3.8) }
                else { Capsule().fill(Self.ink).frame(width: 4.5, height: 1.4).offset(x: 0.8) } // boca de lado: aborrecido, à espera
            }
        }
    }
}

/// Meio arco: sorriso (up false) ou olho fechado.
private struct Arc: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path { Path { p in
        p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY), control: CGPoint(x: r.midX, y: up ? r.minY - r.height : r.maxY + r.height))
    } }
}

private struct RoundedTriangle: Shape {
    func path(in r: CGRect) -> Path { Path { p in
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
    }.strokedPath(.init(lineWidth: 3, lineJoin: .round)).union(Path { p in
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }) }
}

/// Três pontinhos que saltam em vez de reticências paradas.
struct WorkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18)) { t in
            let k = Int(t.date.timeIntervalSinceReferenceDate / 0.18) % 4
            HStack(spacing: 2) { ForEach(0..<3) { i in Circle().frame(width: 4, height: 4).offset(y: k == i ? -3 : 0).opacity(k == i ? 1 : 0.45) } }
                .animation(.spring(duration: 0.18), value: k).padding(.top, 4)
        }
    }
}
