import WidgetKit
import SwiftUI
import AppIntents

/// A Fala no CarPlay sem autorização da Apple: widget (iOS 26 mostra widgets no Dashboard do CarPlay e aceita toque).
/// Imagem do ecrã do Mac + toque para atualizar.
struct MacEntry: TimelineEntry { let date: Date; let image: Data?; let note: String }

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry { MacEntry(date: .now, image: nil, note: "Ecrã do Mac") }
    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) { Task { completion(await fetch()) } }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        Task { completion(Timeline(entries: [await fetch()], policy: .after(.now.addingTimeInterval(300)))) }
    }
    private func fetch() async -> MacEntry {
        let mac = await MacSender()
        guard await mac.paired else { return MacEntry(date: .now, image: nil, note: "Abre a Fala e liga o Mac") }
        let d = await mac.screen(width: 640)
        return MacEntry(date: .now, image: d, note: d == nil ? (await mac.lastError ?? "Mac sem resposta") : "")
    }
}

struct MacWidgetView: View {
    let e: MacEntry
    var body: some View {
        ZStack(alignment: .bottom) {
            Button(intent: RefreshMacIntent()) {
                if let d = e.image, let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "desktopcomputer").font(.title2)
                        Text(e.note).font(.caption).multilineTextAlignment(.center)
                    }.foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(e.date, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule())
                Spacer(minLength: 0)
            }.padding(8)
        }
        .containerBackground(.black, for: .widget)
    }
}

struct MacWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fala.mac", provider: MacProvider()) { MacWidgetView(e: $0) }
            .configurationDisplayName("Ecrã do Mac")
            .description("Vê o ecrã do Mac. Toca para atualizar.")
            .supportedFamilies([.systemSmall, .systemMedium])
            .contentMarginsDisabled()
    }
}
