import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Catálogo e arte partilhados com Android. A escolha usa o ID, nunca a posição.
struct Mascot: Decodable, Identifiable {
    let id: String
    let name: String
    let isNew: Bool
    static let preference = "fala.mascot"
    static let folder = Bundle.main.url(forResource: "Pets", withExtension: "bundle")
    static let all: [Mascot] = {
        guard let url = folder?.appendingPathComponent("catalog.json"), let data = try? Data(contentsOf: url),
              let pets = try? JSONDecoder().decode([Mascot].self, from: data) else { return [] }
        return pets
    }()
    static func resolve(_ selection: String, session: String) -> Mascot? {
        if let chosen = all.first(where: { $0.id == selection }) { return chosen }
        guard !all.isEmpty else { return nil }
        let hash = session.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        return all[Int(hash % UInt32(all.count))]
    }
}

/// Só a mascote selecionada anima nas Definições; as restantes são miniaturas.
struct MascotPreview: View {
    let id: String
    var row = 0
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let cache = NSCache<NSString, CGImage>()
    private var strip: CGImage? {
        if let image = Self.cache.object(forKey: id as NSString) { return image }
        guard let url = Mascot.folder?.appendingPathComponent(id + ".png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 576, image.height == 312 else { return nil }
        Self.cache.setObject(image, forKey: id as NSString, cost: image.bytesPerRow * image.height)
        Self.cache.totalCostLimit = 12 * 1024 * 1024
        return image
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: row == 2 ? 0.12 : 0.15, paused: !animated || reduceMotion)) { time in
            let frame = animated && !reduceMotion ? Int(time.date.timeIntervalSinceReferenceDate / (row == 2 ? 0.12 : 0.15)) % 6 : 0
            if let strip, let image = strip.cropping(to: CGRect(x: frame * 96, y: row * 104, width: 96, height: 104)) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(96.0 / 104, contentMode: .fit)
            }
        }
        .accessibilityHidden(true)
    }
}

struct MascotPicker: View {
    @AppStorage(Mascot.preference) private var selection = ""
    @State private var previewRow = 1
    private var chosen: String { Mascot.all.contains(where: { $0.id == selection }) ? selection : "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Escolhe quem te acompanha nas sessões.").foregroundStyle(.secondary)
            Picker("Pré-visualização", selection: $previewRow) {
                Text("Calmo").tag(0)
                Text("À espera").tag(1)
                Text("A trabalhar").tag(2)
            }.pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                tile(id: "", name: "Automático", preview: "fala-jarvis")
                ForEach(Mascot.all) { pet in tile(id: pet.id, name: pet.name, preview: pet.id) }
            }
            Text("Automático varia por sessão. A tua escolha fica guardada neste dispositivo.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func tile(id: String, name: String, preview: String) -> some View {
        let selected = chosen == id
        return Button { selection = id } label: {
            VStack(spacing: 4) {
                MascotPreview(id: preview, row: previewRow, animated: selected).frame(height: 70)
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 100).padding(6)
            .background(selected ? Theme.lilac : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.ink : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).padding(7) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
