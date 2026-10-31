import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main struct FalaWidgets: WidgetBundle {
    var body: some Widget { DictationLiveActivity(); MacWidget(); SendControl(); NewControl() }
}

/// Centro de Controlo (iOS 18): Enviar e Novo sem abrir a app.
struct SendControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.fran.fala.send") {
            ControlWidgetButton(action: SendDictationIntent()) { Label("Enviar ditado", systemImage: "checkmark.circle.fill") }
        }.displayName("Enviar ditado").description("Envia o ditado da Fala para o computador.")
    }
}
struct NewControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.fran.fala.new") {
            ControlWidgetButton(action: NewDictationIntent()) { Label("Novo ditado", systemImage: "plus.circle.fill") }
        }.displayName("Novo ditado").description("Envia o ditado atual e começa outro.")
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { ctx in
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    icon(ctx.state.phase).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(ctx.state.phase)).font(.headline)
                        if ctx.state.phase == "rec" { Text(ctx.state.started, style: .timer).font(.subheadline).monospacedDigit() }
                        if !ctx.state.text.isEmpty { Text(ctx.state.text).font(.subheadline).lineLimit(2).opacity(0.8) }
                    }
                    Spacer()
                }
                if ["rec", "pause"].contains(ctx.state.phase) { buttons(ctx.state.phase) }
            }
            .padding(16).activityBackgroundTint(Color.black.opacity(0.85)).foregroundStyle(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { icon(ctx.state.phase) }
                DynamicIslandExpandedRegion(.center) { Text(title(ctx.state.phase)) }
                DynamicIslandExpandedRegion(.trailing) { if ctx.state.phase == "rec" { Text(ctx.state.started, style: .timer).monospacedDigit() } }
                DynamicIslandExpandedRegion(.bottom) { if ["rec", "pause"].contains(ctx.state.phase) { buttons(ctx.state.phase) } }
            } compactLeading: { icon(ctx.state.phase) } compactTrailing: {
                if ctx.state.phase == "rec" { Text(ctx.state.started, style: .timer).monospacedDigit().frame(width: 40) }
            } minimal: { icon(ctx.state.phase) }
        }
        .supplementalActivityFamilies([.small]) // também no Dashboard do CarPlay (iOS 26, sem autorização da Apple)
    }
    /// Enviar (= o certo da aba Ditar) · Pausar/Continuar · Novo (envia e começa outro).
    private func buttons(_ phase: String) -> some View {
        HStack(spacing: 8) {
            Button(intent: SendDictationIntent()) { Label("Enviar", systemImage: "checkmark").frame(maxWidth: .infinity).foregroundStyle(.black) }.tint(.white)
            Button(intent: PauseDictationIntent()) { Label(phase == "pause" ? "Seguir" : "Pausar", systemImage: phase == "pause" ? "play.fill" : "pause.fill").frame(maxWidth: .infinity) }.tint(.orange)
            Button(intent: NewDictationIntent()) { Label("Novo", systemImage: "plus").frame(maxWidth: .infinity) }.tint(.gray)
        }
        .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).labelStyle(.titleAndIcon)
    }
    private func title(_ p: String) -> String {
        switch p { case "rec": "A ouvir…"; case "pause": "Em pausa"; case "send": "A enviar para o Mac…"; case "done": "Colado no Mac"; default: "Guardado para depois" }
    }
    @ViewBuilder private func icon(_ p: String) -> some View {
        Image(systemName: p == "rec" ? "waveform" : p == "pause" ? "pause.circle" : p == "send" ? "arrow.up.circle" : p == "done" ? "checkmark.circle.fill" : "clock")
            .foregroundStyle(p == "rec" ? .orange : p == "done" ? .green : .white)
            .symbolEffect(.variableColor.iterative, isActive: p == "rec")
    }
}
