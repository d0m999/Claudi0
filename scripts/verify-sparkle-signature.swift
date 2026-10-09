import CryptoKit
import Foundation

func fail(_ reason: String) -> Never {
    fputs("Sparkle verification failed: \(reason)\n", stderr); exit(1)
}
let args = CommandLine.arguments
if args.count < 4 { fail("usage: key-match|feed|archive <public-key-file> <file-or-signature>") }
do {
    let keyText = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32 else {
        fail("public key")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    if args[1] == "key-match" {
        let secret = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: secret, encoding: .utf8),
            let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            seed.count == 32
        else { fail("private seed format") }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        guard privateKey.publicKey.rawRepresentation == keyData else {
            fail("private/public key mismatch")
        }
    } else {
        let url = URL(fileURLWithPath: args[3])
        let limit = args[1] == "feed" ? 2_000_000 : 40_000_000
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { fail("file too large") }
        let data = try Data(contentsOf: url)
        if args[1] == "feed" {
            let prefix = Data("<!-- sparkle-signatures:\n".utf8)
            guard let range = data.range(of: prefix, options: .backwards),
                let block = String(data: data[range.upperBound...], encoding: .utf8),
                block.hasSuffix("-->\n")
            else { fail("missing feed signature") }
            let fields = block.split(separator: "\n")
            guard let signatureLine = fields.first(where: { $0.hasPrefix("edSignature:") }),
                let lengthLine = fields.first(where: { $0.hasPrefix("length:") }),
                let signature = Data(
                    base64Encoded: signatureLine.dropFirst(12).trimmingCharacters(in: .whitespaces)),
                Int(lengthLine.dropFirst(7).trimmingCharacters(in: .whitespaces))
                    == range.lowerBound,
                publicKey.isValidSignature(signature, for: data[..<range.lowerBound])
            else { fail("feed signature") }
        } else if args[1] == "archive", args.count == 5 {
            guard let signature = Data(base64Encoded: args[4]),
                publicKey.isValidSignature(signature, for: data)
            else { fail("archive signature") }
        } else {
            fail("command")
        }
    }
    print("Sparkle signature verified")
} catch { fail("invalid input") }
