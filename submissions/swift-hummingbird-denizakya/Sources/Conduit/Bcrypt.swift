// Minimal bcrypt wrapper over the vendored OpenBSD C implementation (Sources/CVaporBcrypt,
// from Vapor's CVaporBcrypt, MIT). Always cost 10, per SPEC.md rule 7.
import CVaporBcrypt
import Foundation

enum Bcrypt {
    enum BcryptError: Error { case invalidCost, invalidSalt, hashFailure, invalidHash }

    /// Generates a "$2a$10$<22 chars>" salt (OpenBSD radix-64 of 16 random bytes).
    private static func generateSalt() throws -> String {
        var random = [UInt8](repeating: 0, count: 16)
        for i in random.indices { random[i] = UInt8.random(in: 0...255) }
        let encoded = [UInt8](unsafeUninitializedCapacity: 22) { buf, count in
            let bytes = UnsafeMutablePointer<Int8>.allocate(capacity: 25)
            defer { bytes.deallocate() }
            _ = random.withUnsafeBytes { raw in
                vapor_encode_base64(bytes, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
            let cs = String(cString: bytes).utf8
            count = min(22, cs.count)
            for (i, b) in cs.prefix(22).enumerated() { buf[i] = b }
        }
        return "$2a$10$" + String(decoding: encoded, as: UTF8.self)
    }

    /// Hash with a salt that may be a full "$2a$.." prefix or a bare 22-char salt; keeps the hash's version.
    private static func hash(_ plaintext: String, salt rawSalt: String) throws -> String {
        var normalizedSalt: String
        if rawSalt.count == 22 {
            normalizedSalt = "$2a$10$" + rawSalt
        } else {
            let revision = String(rawSalt.prefix(4))
            guard revision == "$2a$" || revision == "$2b$" || revision == "$2y$" else {
                throw BcryptError.invalidSalt
            }
            // Normalize $2y$ (crypt_blowfish alias of $2a$) to $2a$, as the C code only knows 2a/2b.
            normalizedSalt = revision == "$2y$" ? "$2a$" + rawSalt.dropFirst(4) : rawSalt
        }
        guard normalizedSalt.count == 29 else { throw BcryptError.invalidSalt }
        var out = [CChar](repeating: 0, count: 128)
        let rc = normalizedSalt.withCString { salt in
            plaintext.withCString { key in
                vapor_bcrypt_hashpass(key, salt, &out, 128)
            }
        }
        guard rc == 0 else { throw BcryptError.hashFailure }
        return String(cString: out)
    }

    /// New hash with a random salt.
    static func hash(_ plaintext: String) throws -> String {
        try hash(plaintext, salt: generateSalt())
    }

    /// Constant-time-ish verify: re-hash with the stored hash's salt and compare checksums.
    static func verify(_ plaintext: String, hash: String) throws -> Bool {
        let salt = String(hash.prefix(29))
        guard salt.count == 29 else { throw BcryptError.invalidHash }
        let candidate = try Bcrypt.hash(plaintext, salt: salt)
        let a = candidate.suffix(31)
        let b = hash.suffix(31)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}
