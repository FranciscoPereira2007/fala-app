import Foundation
import CryptoKit

// Ferramenta de teste: a cifra Swift real (Shared/LinkCrypto.swift) contra a Kotlin.
// seal T ID BODY | open T FRAME | sealReply T ID BODY | openReply T ID FRAME | room T   (tudo em hex)
func unhex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! }) }
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
let a = CommandLine.arguments
switch a[1] {
case "seal": print(hex(LinkCrypto.seal(unhex(a[4]), id: unhex(a[3]), token: a[2])))
case "open":
    guard let r = LinkCrypto.open(unhex(a[3]), token: a[2]) else { print("FAIL"); exit(1) }
    print(hex(r.id) + " " + hex(r.body) + " " + String(Int64(r.sent.timeIntervalSince1970 * 1000)))
case "sealReply": print(hex(LinkCrypto.sealReply(unhex(a[4]), id: unhex(a[3]), token: a[2])))
case "openReply":
    guard let b = LinkCrypto.openReply(unhex(a[4]), id: unhex(a[3]), token: a[2]) else { print("FAIL"); exit(1) }
    print(hex(b))
case "room": print(LinkCrypto.room(a[2]))
default: exit(2)
}
