import SwiftUI
import AppKit
import CoreText

// Figtree (UI) e EB Garamond (títulos), as mesmas famílias do Flow, OFL, embutidas na app.
enum FalaFonts {
    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    /// Variable font com eixo wght exato (o Flow usa 550, 650...).
    static func make(_ family: String, _ size: CGFloat, _ weight: Double) -> Font {
        let wght = 0x77676874 // 'wght'
        let d = NSFontDescriptor(fontAttributes: [.family: family]).addingAttributes([.variation: [wght: weight]])
        if let f = NSFont(descriptor: d, size: size) { return Font(f) }
        return .system(size: size)
    }
}

extension Font {
    static func figtree(_ size: CGFloat, weight: Double = 400) -> Font { FalaFonts.make("Figtree", size, weight) }
    static func garamond(_ size: CGFloat, italic: Bool = false, weight: Double = 400) -> Font {
        let f = FalaFonts.make("EB Garamond", size, weight)
        return italic ? f.italic() : f
    }
}

/// Tokens do Flow (light). Ver NOTES.md secção C.A.
enum Flow {
    static let bg = Color(hex: 0xfcfcfb)          // --background sand-50
    static let bg2 = Color(hex: 0xeeebe3)         // --background-secondary sand-600
    static let bg3 = Color(hex: 0xf5f4f0)         // --background-tertiary sand-500
    static let chrome = Color(hex: 0xf5f4f0)      // fundo da janela atrás do cartão
    static let card = Color.white
    static let fg = Color(hex: 0x1a1a1a)
    static let fg3 = Color(hex: 0x71716e)
    static let border = Color(hex: 0xeeebe3)
    static let hoverRow = Color(hex: 0xeeebe3).opacity(0.7)
    static let orange = Color(hex: 0xf9b45c)
    static let lilac = Color(hex: 0xf0d7ff)
    static let lilacBorder = Color(hex: 0xd2ace9)
    static let teal = Color(hex: 0x034f46)
    static let ease = Animation.easeInOut(duration: 0.15)
}
