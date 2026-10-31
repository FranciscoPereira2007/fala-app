import SwiftUI
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Transforms: como os do Flow, mas com o modelo da Apple no próprio Mac (grátis, offline).
enum LocalAI {
    static func run(_ instruction: String, on text: String) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return "Apple Intelligence não está disponível neste Mac." }
            do {
                let s = LanguageModelSession(instructions: "Responde só com o texto final, em português de Portugal, sem comentários. Nunca uses travessões.")
                return try await s.respond(to: "\(instruction)\n\nTexto:\n\(text)").content
            } catch { return "Erro: \(error.localizedDescription)" }
        }
        #endif
        return "Precisa do macOS 26."
    }
}

