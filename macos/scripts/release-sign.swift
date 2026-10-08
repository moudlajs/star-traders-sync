// Ed25519 release signing (#108): the app refuses an update whose dmg does not verify against the embedded key.
// Usage: keygen PRIVATE_KEY_FILE | sign FILE (key in $STS_RELEASE_SIGNING_KEY) | verify FILE SIG_FILE PUBLIC_KEY
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-sign: \(message)\n".utf8))
    exit(1)
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

func decode(_ text: String, _ what: String) -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(what) is not base64")
    }
    return data
}

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count) {
case ("keygen", 3):
    let key = Curve25519.Signing.PrivateKey()
    let path = args[2]
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let secret = ProcessInfo.processInfo.environment["STS_RELEASE_SIGNING_KEY"], !secret.isEmpty else {
        fail("STS_RELEASE_SIGNING_KEY is not set")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: decode(secret, "the signing key")) else {
        fail("the signing key is not an Ed25519 private key")
    }
    guard let signature = try? key.signature(for: read(args[2])) else { fail("signing failed") }
    print(signature.base64EncodedString())
case ("verify", 5):
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: decode(args[4], "the public key")) else {
        fail("not an Ed25519 public key")
    }
    let signature = decode(String(decoding: read(args[3]), as: UTF8.self), "the signature")
    guard key.isValidSignature(signature, for: read(args[2])) else { fail("\(args[2]) does NOT verify") }
    print("ok: \(args[2]) verifies")
default:
    fail("usage: keygen PRIVATE_KEY_FILE | sign FILE | verify FILE SIG_FILE PUBLIC_KEY")
}
