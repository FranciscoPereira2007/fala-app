import Foundation
import CoreGraphics

/// Teclado do iPhone a funcionar como teclado do Mac (corpo "K" + JSON). Precisa da Acessibilidade.
/// {"t":"olá"} escreve texto onde estiver o cursor; {"k":"return","m":["cmd"]} carrega numa tecla com modificadores.
/// Trackpad: {"dx","dy"} move o rato; {"ax","ay"} põe-no num ponto 0..1 do monitor; {"c":1|2|3} clique/duplo/direito onde está o rato; {"sx","sy"} scroll; {"b":"down"|"up"} arrastar.
enum RemoteInput {
    struct Cmd: Codable { var t: String?; var k: String?; var m: [String]?; var n: Int?
        var dx: Double?; var dy: Double?; var c: Int?; var sx: Int?; var sy: Int?; var b: String?; var md: UInt32?; var ax: Double?; var ay: Double? }
    private static var dragging = false
    /// Jarvis: teclas direto para esta app (sem a pôr à frente nem mexer onde o Fran está a escrever).
    nonisolated(unsafe) static var targetPID: pid_t?

    static let keys: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "`": 50, "/": 44,
        "=": 24, "-": 27, "[": 33, "]": 30,
    ]

    /// nil = feito; senão o erro.
    static func apply(_ c: Cmd) -> String? {
        let src = CGEventSource(stateID: .hidSystemState)
        mouse(c, src)
        if let t = c.t, !t.isEmpty {
            // Unicode direto: acentos, emojis e qualquer layout de teclado.
            for chunk in Array(t.utf16).chunked(20) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    if let p = targetPID { e?.postToPid(p) } else { e?.post(tap: .cghidEventTap) }
                }
            }
        }
        if let k = c.k {
            guard let code = keys[k.lowercased()] else { return "Tecla desconhecida: \(k)" }
            var flags: CGEventFlags = []
            for m in c.m ?? [] {
                switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
                case "opt", "alt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break }
            }
            if (123...126).contains(code) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) } // setas reais: ⌃← / ⌃↑ do sistema só disparam com estas flags
            for _ in 0..<max(1, min(c.n ?? 1, 200)) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                    e?.flags = flags
                    if let p = targetPID { e?.postToPid(p) } else { e?.post(tap: .cghidEventTap) }
                }
            }
        }
        return nil
    }
}

extension RemoteInput {
    private static func allDisplays() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), n: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Trackpad do iPhone: tudo relativo à posição atual do rato (como o trackpad do MacBook).
    static func mouse(_ c: Cmd, _ src: CGEventSource?) {
        var p = CGEvent(source: nil)?.location ?? .zero
        // md = monitor escolhido no iPhone: o rato fica preso nele. Sem md o rato anda por todos e a imagem segue-o.
        let b = c.md.map { CGDisplayBounds($0) } ?? allDisplays()
        if c.md != nil, !b.contains(p) {
            p = CGPoint(x: b.midX, y: b.midY)
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let ax = c.ax, let ay = c.ay { // ponto exato (0..1) do monitor que o iPhone mostra: o dedo é o rato
            let d = CGDisplayBounds(c.md ?? RemoteScreen.cursorDisplay())
            p = CGPoint(x: d.minX + d.width * min(max(ax, 0), 1), y: d.minY + d.height * min(max(ay, 0), 1))
            CGEvent(mouseEventSource: src, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if c.dx != nil || c.dy != nil {
            p.x = min(max(p.x + (c.dx ?? 0), b.minX), b.maxX - 1); p.y = min(max(p.y + (c.dy ?? 0), b.minY), b.maxY - 1)
            CGEvent(mouseEventSource: src, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let b = c.b {
            dragging = b == "down"
            CGEvent(mouseEventSource: src, mouseType: dragging ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let k = c.c {
            let (dn, up, btn): (CGEventType, CGEventType, CGMouseButton) = k == 3 ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            for i in 1...(k == 2 ? 2 : 1) {
                for t in [dn, up] {
                    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: btn)
                    e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    e?.flags = [] // sem ⌃/⌘ herdados: ⌃+clique no Mac = clique direito
                    e?.post(tap: .cghidEventTap)
                }
            }
        }
        if c.sx != nil || c.sy != nil {
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(c.sy ?? 0), wheel2: Int32(c.sx ?? 0), wheel3: 0)?.post(tap: .cghidEventTap)
        }
    }
}

private extension Array {
    func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}

import ScreenCaptureKit
import AppKit

/// Ecrã do Mac no iPhone (fase 2 do estudo do Parsec): JPEG do ecrã principal a pedido, cliques por coordenadas 0..1.
enum RemoteScreen {
    private static var displays: [SCDisplay] = [] // ponytail: cache; refeita ao pedir a lista ou se a captura falhar

    /// Monitor onde está o rato (sem monitor escolhido, o iPhone mostra este: segue-te entre ecrãs).
    static func cursorDisplay() -> CGDirectDisplayID {
        let p = CGEvent(source: nil)?.location ?? .zero
        var id: CGDirectDisplayID = 0, n: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0 ? id : CGMainDisplayID()
    }

    /// Monitores para o iPhone escolher: o MacBook primeiro, depois os externos pela ordem do ecrã.
    static func list() async -> [[String: Any]] {
        displays = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.displays
            .sorted { (CGDisplayIsBuiltin($0.displayID) != 0 ? 0 : 1, $0.frame.minX) < (CGDisplayIsBuiltin($1.displayID) != 0 ? 0 : 1, $1.frame.minX) } ?? []
        var n = 0
        return displays.map { d in
            let builtin = CGDisplayIsBuiltin(d.displayID) != 0
            if !builtin { n += 1 }
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.localizedName
            return ["id": d.displayID, "name": builtin ? "MacBook" : name ?? "Monitor \(n)"]
        }
    }

    /// Imagem de um monitor (`id`; nil = principal) com `width` px de largura (JPEG, ou HEIC = metade do tamanho, para a internet).
    /// nil = sem permissão de Gravação de Ecrã.
    static func snapshot(width: Int = 1280, quality: Double = 0.55, heic: Bool = false, display id: UInt32? = nil) async -> Data? {
        if displays.isEmpty { _ = await list() }
        let want = id ?? cursorDisplay()
        guard let d = displays.first(where: { $0.displayID == want }) ?? displays.first else { return nil }
        let cfg = SCStreamConfiguration()
        let k = Double(width) / Double(d.width)
        cfg.width = width; cfg.height = Int(Double(d.height) * k)
        cfg.showsCursor = true
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) else { displays = []; return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, (heic ? "public.heic" : "public.jpeg") as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Clique no ponto (x, y em 0..1 do monitor `id`; nil = principal). right = clique direito; double = duplo clique.
    static func click(x: Double, y: Double, right: Bool = false, double: Bool = false, display id: UInt32? = nil) {
        let b = CGDisplayBounds(id ?? cursorDisplay())
        let p = CGPoint(x: b.minX + b.width * min(max(x, 0), 1), y: b.minY + b.height * min(max(y, 0), 1))
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        let (dn, up, btn): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for i in 1...(double ? 2 : 1) {
            for t in [dn, up] {
                let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: btn)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    static func scroll(dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}
