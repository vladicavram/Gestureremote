import Foundation
import Network
import CryptoKit
import Security
import UIKit
import Darwin

// MARK: - Device Model

struct AppleTVDevice: Identifiable, Equatable {
    let id: String   // Bonjour service name
    let name: String
    let endpoint: NWEndpoint
}

// MARK: - Companion Frame Types

private enum CompanionFrameType: UInt8 {
    case psStart = 3
    case psNext  = 4
    case pvStart = 5
    case pvNext  = 6
    case uOPACK  = 7
    case eOPACK  = 8
}

// MARK: - OPACK Codec (minimal, Companion protocol only)

private enum OPACK {

    // MARK: Encode

    static func encode(_ value: Any) -> Data {
        if let dict = value as? [String: Any] {
            let count = dict.count
            var out = Data()
            if count < 15 {
                out.append(UInt8(0xE0 + count))
            } else {
                out.append(0xEF)   // unbounded dict
            }
            for (k, v) in dict {
                out += encode(k)
                out += encode(v)
            }
            if count >= 15 { out.append(0x03) }
            return out
        } else if let str = value as? String {
            let bytes = Data(str.utf8)
            if bytes.count <= 32 {
                return Data([UInt8(0x40 + bytes.count)]) + bytes
            } else if bytes.count <= 0xFF {
                return Data([0x61, UInt8(bytes.count)]) + bytes
            } else {
                let len = UInt16(bytes.count)
                var out = Data([0x62])
                out += withUnsafeBytes(of: len.littleEndian) { Data($0) }
                return out + bytes
            }
        } else if let data = value as? Data {
            if data.count <= 32 {
                return Data([UInt8(0x70 + data.count)]) + data
            } else if data.count <= 0xFF {
                return Data([0x91, UInt8(data.count)]) + data
            } else {
                let len = UInt16(data.count)
                var out = Data([0x92])
                out += withUnsafeBytes(of: len.littleEndian) { Data($0) }
                return out + data
            }
        } else if let array = value as? [Any] {
            var out = Data()
            out.append(array.count < 15 ? UInt8(0xD0 + array.count) : 0xDF)
            for element in array { out += encode(element) }
            if array.count >= 15 { out.append(0x03) }
            return out
        } else if let n = value as? Int {
            return encodeInt(n)
        } else if let n = value as? UInt {
            return encodeInt(Int(n))
        }
        return Data()
    }

    private static func encodeInt(_ n: Int) -> Data {
        if n >= 0 && n < 0x28 {
            return Data([UInt8(n + 8)])
        } else if n >= 0 && n <= 0xFF {
            return Data([0x30, UInt8(n)])
        } else if n >= 0 && n <= 0xFFFF {
            let v = UInt16(n)
            return Data([0x31]) + withUnsafeBytes(of: v.littleEndian) { Data($0) }
        } else {
            let v = UInt32(bitPattern: Int32(truncatingIfNeeded: n))
            return Data([0x32]) + withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
    }

    // MARK: Decode

    static func decodeDict(_ data: Data) -> [String: Any]? {
        let bytes = Array(data)
        guard let (val, _) = decodeValue(bytes, at: 0), let dict = val as? [String: Any] else { return nil }
        return dict
    }

    private static func decodeValue(_ bytes: [UInt8], at offset: Int) -> (Any, Int)? {
        guard offset < bytes.count else { return nil }
        let b = bytes[offset]
        switch b {
        case 0x00: return (false as Any, 1)
        case 0x01: return (true as Any, 1)
        case 0x02: return (NSNull() as Any, 1)
        case 0x03: return nil  // terminator

        case 0x08...0x2F:  // small int: 0..39, stored as n+8
            return (Int(b) - 8, 1)

        case 0x30:  // 1-byte LE int
            guard bytes.count >= offset + 2 else { return nil }
            return (Int(bytes[offset + 1]), 2)

        case 0x31:  // 2-byte LE int
            guard bytes.count >= offset + 3 else { return nil }
            let v = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
            return (v, 3)

        case 0x32:  // 4-byte LE int
            guard bytes.count >= offset + 5 else { return nil }
            let v = Int(bytes[offset+1]) | Int(bytes[offset+2]) << 8
                  | Int(bytes[offset+3]) << 16 | Int(bytes[offset+4]) << 24
            return (v, 5)

        case 0x40...0x60:  // short string (len 0..32)
            let len = Int(b - 0x40)
            guard bytes.count >= offset + 1 + len else { return nil }
            let s = String(bytes: bytes[(offset+1)..<(offset+1+len)], encoding: .utf8) ?? ""
            return (s, 1 + len)

        case 0x61:  // 1-byte len string
            guard bytes.count >= offset + 2 else { return nil }
            let len = Int(bytes[offset + 1])
            guard bytes.count >= offset + 2 + len else { return nil }
            let s = String(bytes: bytes[(offset+2)..<(offset+2+len)], encoding: .utf8) ?? ""
            return (s, 2 + len)

        case 0x62:  // 2-byte LE len string
            guard bytes.count >= offset + 3 else { return nil }
            let len = Int(bytes[offset+1]) | Int(bytes[offset+2]) << 8
            guard bytes.count >= offset + 3 + len else { return nil }
            let s = String(bytes: bytes[(offset+3)..<(offset+3+len)], encoding: .utf8) ?? ""
            return (s, 3 + len)

        case 0x70...0x90:  // short bytes (len 0..32)
            let len = Int(b - 0x70)
            guard bytes.count >= offset + 1 + len else { return nil }
            return (Data(bytes[(offset+1)..<(offset+1+len)]), 1 + len)

        case 0x91:  // 1-byte len bytes
            guard bytes.count >= offset + 2 else { return nil }
            let len = Int(bytes[offset + 1])
            guard bytes.count >= offset + 2 + len else { return nil }
            return (Data(bytes[(offset+2)..<(offset+2+len)]), 2 + len)

        case 0x92:  // 2-byte LE len bytes
            guard bytes.count >= offset + 3 else { return nil }
            let len = Int(bytes[offset+1]) | Int(bytes[offset+2]) << 8
            guard bytes.count >= offset + 3 + len else { return nil }
            return (Data(bytes[(offset+3)..<(offset+3+len)]), 3 + len)

        case 0xD0...0xDE:  // bounded array (count 0..14)
            let count = Int(b - 0xD0)
            var items: [Any] = []
            var pos = offset + 1
            for _ in 0..<count {
                guard let (val, consumed) = decodeValue(bytes, at: pos) else { break }
                items.append(val); pos += consumed
            }
            return (items, pos - offset)

        case 0xDF:  // unbounded array
            var items: [Any] = []
            var pos = offset + 1
            while pos < bytes.count {
                if bytes[pos] == 0x03 { pos += 1; break }
                guard let (val, consumed) = decodeValue(bytes, at: pos) else { break }
                items.append(val); pos += consumed
            }
            return (items, pos - offset)

        case 0xE0...0xEE:  // bounded dict (count 0..14)
            let count = Int(b - 0xE0)
            var dict: [String: Any] = [:]
            var pos = offset + 1
            for _ in 0..<count {
                guard let (kv, kc) = decodeValue(bytes, at: pos) else { break }
                pos += kc
                guard let (vv, vc) = decodeValue(bytes, at: pos) else { break }
                pos += vc
                if let key = kv as? String { dict[key] = vv }
            }
            return (dict, pos - offset)

        case 0xEF:  // unbounded dict
            var dict: [String: Any] = [:]
            var pos = offset + 1
            while pos < bytes.count {
                if bytes[pos] == 0x03 { pos += 1; break }
                guard let (kv, kc) = decodeValue(bytes, at: pos) else { break }
                pos += kc
                guard pos < bytes.count else { break }
                guard let (vv, vc) = decodeValue(bytes, at: pos) else { break }
                pos += vc
                if let key = kv as? String { dict[key] = vv }
            }
            return (dict, pos - offset)

        default:
            return nil
        }
    }
}

// MARK: - TLV8 Codec

private enum TLVTag {
    static let method: UInt8        = 0x00
    static let identifier: UInt8    = 0x01
    static let salt: UInt8          = 0x02
    static let publicKey: UInt8     = 0x03
    static let proof: UInt8         = 0x04
    static let encryptedData: UInt8 = 0x05
    static let seqNo: UInt8         = 0x06
    static let error: UInt8         = 0x07
    static let signature: UInt8     = 0x0A
}

private struct TLV8 {
    static func encode(_ items: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            var remaining = value
            repeat {
                let chunk = remaining.prefix(255)
                remaining = remaining.dropFirst(chunk.count)
                out += Data([tag, UInt8(chunk.count)]) + chunk
            } while !remaining.isEmpty
        }
        return out
    }

    static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            guard data.distance(from: i, to: data.endIndex) >= 2 else { break }
            let tag = data[i]; let len = Int(data[data.index(after: i)])
            i = data.index(i, offsetBy: 2)
            let end = data.index(i, offsetBy: min(len, data.distance(from: i, to: data.endIndex)))
            let chunk = data[i..<end]
            result[tag] = (result[tag] ?? Data()) + chunk
            i = end
        }
        return result
    }
}

// MARK: - Companion Session ChaCha20-Poly1305
// Session nonce: pure 12-byte little-endian counter (Companion protocol spec)

private final class CompanionChaCha {
    private let outputKey: SymmetricKey
    private let inputKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    init(outputKey: Data, inputKey: Data) {
        self.outputKey = SymmetricKey(data: outputKey)
        self.inputKey  = SymmetricKey(data: inputKey)
    }

    func encrypt(_ plaintext: Data, aad: Data) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: sessionNonce(sendCounter))
        sendCounter += 1
        let sealed = try ChaChaPoly.seal(plaintext, using: outputKey, nonce: nonce, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    func decrypt(_ ciphertext: Data, aad: Data) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: sessionNonce(recvCounter))
        recvCounter += 1   // always advance to keep counters in sync
        guard ciphertext.count >= 16 else { throw CocoaError(.coderInvalidValue) }
        let tag = ciphertext.suffix(16)
        let ct  = ciphertext.dropLast(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: inputKey, authenticating: aad)
    }

    private func sessionNonce(_ counter: UInt64) -> Data {
        var bytes = Data(count: 12)
        bytes.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: counter.littleEndian, toByteOffset: 0, as: UInt64.self)
        }
        return bytes
    }
}

// MARK: - Pairing nonce (HAP labels: 4 zero bytes + 8-char ASCII = 12 bytes)

private func pairingNonce(_ label: String) -> ChaChaPoly.Nonce {
    let bytes = Data(repeating: 0, count: 4) + Data(label.utf8)
    return try! ChaChaPoly.Nonce(data: bytes)
}

// MARK: - HKDF-SHA512 helper

private func hkdfSHA512(inputKeyMaterial: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
    let ikm = SymmetricKey(data: inputKeyMaterial)
    let saltKey = HKDF<SHA512>.extract(inputKeyMaterial: ikm, salt: salt)
    return HKDF<SHA512>.expand(pseudoRandomKey: saltKey, info: info, outputByteCount: outputByteCount)
        .withUnsafeBytes { Data($0) }
}

// MARK: - SRP-6a (3072-bit, SHA-512, HAP-style)

private struct SRP {
    static let N_hex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
    static let g: BigUInt = BigUInt([UInt32(5)])

    static func makeN() -> BigUInt { BigUInt(hexString: N_hex)! }

    struct Client {
        let N: BigUInt
        let a: BigUInt
        let A: BigUInt

        init() {
            N = SRP.makeN()
            var bytes = Data(count: 32)
            _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            a = BigUInt(bytes) % N
            A = SRP.g.power(a, modulus: N)
        }

        func computeClientKey(salt: Data, password: String, B_data: Data) -> (S: BigUInt, M1: Data, K: Data) {
            let B = BigUInt(B_data)
            let kHash = SHA512.hash(data: N.toData() + pad(SRP.g.toData(), to: N.toData().count))
            let k = BigUInt(Data(kHash))
            let uHash = SHA512.hash(data: pad(A.toData(), to: N.toData().count) + pad(B_data, to: N.toData().count))
            let u = BigUInt(Data(uHash))
            let upHash = SHA512.hash(data: Data(("Pair-Setup:" + password).utf8))
            let xHash = SHA512.hash(data: salt + Data(upHash))
            let x = BigUInt(Data(xHash))
            let gx = SRP.g.power(x, modulus: N)
            let kgx = (k * gx) % N
            let diff = (B + N * BigUInt([UInt32(3)]) - kgx) % N
            let exp = a + u * x
            let S = diff.power(exp, modulus: N)
            let hN = Data(SHA512.hash(data: N.toData()))
            let hg = Data(SHA512.hash(data: SRP.g.toData()))
            let xorNg = Data(zip(hN, hg).map { $0 ^ $1 })
            let hU = Data(SHA512.hash(data: Data("Pair-Setup".utf8)))
            let K = Data(SHA512.hash(data: S.toData()))
            let M1input = xorNg + hU + salt + A.toData() + B.toData() + K
            let M1 = Data(SHA512.hash(data: M1input))
            return (S, M1, K)
        }

        private func pad(_ data: Data, to length: Int) -> Data {
            if data.count >= length { return data }
            return Data(repeating: 0, count: length - data.count) + data
        }
    }
}

// MARK: - BigUInt (minimal, big-endian bytes interface, little-endian UInt32 limbs)

private struct BigUInt {
    var limbs: [UInt32]

    static let zero = BigUInt([UInt32(0)])
    static let one  = BigUInt([UInt32(1)])

    init(_ limbs: [UInt32]) { self.limbs = limbs; normalize() }

    init(_ data: Data) {
        limbs = []
        var d = data
        while d.count % 4 != 0 { d = Data([0]) + d }
        var i = d.startIndex
        while i < d.endIndex {
            let word = UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
            limbs.insert(word, at: 0)
            i += 4
        }
        normalize()
    }

    init?(hexString: String) {
        var hex = hexString.replacingOccurrences(of: " ", with: "")
        if hex.count % 2 != 0 { hex = "0" + hex }
        var bytes = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let end = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<end], radix: 16) else { return nil }
            bytes.append(byte)
            i = end
        }
        self.init(bytes)
    }

    mutating func normalize() {
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
        if limbs.isEmpty { limbs = [0] }   // BigUInt must never have empty limbs
    }

    func toData() -> Data {
        var result = Data()
        for limb in limbs.reversed() {
            result.append(UInt8((limb >> 24) & 0xFF))
            result.append(UInt8((limb >> 16) & 0xFF))
            result.append(UInt8((limb >> 8)  & 0xFF))
            result.append(UInt8( limb        & 0xFF))
        }
        while result.count > 1 && result.first == 0 { result = result.dropFirst() }
        return result
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let maxLen = max(lhs.limbs.count, rhs.limbs.count)
        for i in (0..<maxLen).reversed() {
            let l = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let r = i < rhs.limbs.count ? rhs.limbs[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let maxLen = max(lhs.limbs.count, rhs.limbs.count)
        for i in 0..<maxLen {
            let l = i < lhs.limbs.count ? lhs.limbs[i] : 0
            let r = i < rhs.limbs.count ? rhs.limbs[i] : 0
            if l != r { return false }
        }
        return true
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let maxLen = max(lhs.limbs.count, rhs.limbs.count)
        var result = [UInt32](repeating: 0, count: maxLen + 1)
        var carry: UInt64 = 0
        for i in 0..<maxLen {
            let l = UInt64(i < lhs.limbs.count ? lhs.limbs[i] : 0)
            let r = UInt64(i < rhs.limbs.count ? rhs.limbs[i] : 0)
            let s = l + r + carry
            result[i] = UInt32(s & 0xFFFFFFFF)
            carry = s >> 32
        }
        result[maxLen] = UInt32(carry)
        return BigUInt(result)
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: Int64 = 0
        for i in 0..<lhs.limbs.count {
            let l = Int64(lhs.limbs[i])
            let r = Int64(i < rhs.limbs.count ? rhs.limbs[i] : 0)
            var diff = l - r - borrow
            if diff < 0 { diff += (1 << 32); borrow = 1 } else { borrow = 0 }
            result[i] = UInt32(diff)
        }
        return BigUInt(result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let n = lhs.limbs.count, m = rhs.limbs.count
        var result = [UInt64](repeating: 0, count: n + m + 1)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<m {
                let prod = UInt64(lhs.limbs[i]) * UInt64(rhs.limbs[j]) + result[i+j] + carry
                result[i+j] = prod & 0xFFFF_FFFF
                carry = prod >> 32
            }
            var k = m
            while carry != 0 {
                let s = result[i+k] + carry
                result[i+k] = s & 0xFFFF_FFFF
                carry = s >> 32
                k += 1
            }
        }
        return BigUInt(result.map { UInt32($0) })
    }

    func halved() -> BigUInt {
        var r = limbs
        var carry: UInt32 = 0
        for i in (0..<r.count).reversed() {
            let newCarry = (r[i] & 1) << 31
            r[i] = (r[i] >> 1) | carry
            carry = newCarry
        }
        var result = BigUInt(r)
        result.normalize()
        return result
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        return lhs.divided(by: rhs).remainder
    }

    func divided(by divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        guard !divisor.isZero else { fatalError("Division by zero") }
        guard !(self < divisor) else { return (.zero, self) }

        // Single-limb fast path
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var rem: UInt64 = 0
            var q = [UInt32](repeating: 0, count: self.limbs.count)
            for i in (0..<self.limbs.count).reversed() {
                let cur = (rem << 32) | UInt64(self.limbs[i])
                q[i] = UInt32(cur / d)
                rem  = cur % d
            }
            return (BigUInt(q), BigUInt([UInt32(rem)]))
        }

        // Knuth Algorithm D (multi-limb)
        let n = divisor.limbs.count
        let m = self.limbs.count - n

        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        var u = [UInt32](repeating: 0, count: m + n + 1)
        var v = [UInt32](repeating: 0, count: n)

        if shift == 0 {
            for i in 0..<self.limbs.count { u[i] = self.limbs[i] }
            for i in 0..<n               { v[i] = divisor.limbs[i] }
        } else {
            var carry: UInt32 = 0
            for i in 0..<self.limbs.count {
                let x = (UInt64(self.limbs[i]) << shift) | UInt64(carry)
                u[i]  = UInt32(x & 0xFFFF_FFFF); carry = UInt32(x >> 32)
            }
            u[self.limbs.count] = carry
            carry = 0
            for i in 0..<n {
                let x = (UInt64(divisor.limbs[i]) << shift) | UInt64(carry)
                v[i]  = UInt32(x & 0xFFFF_FFFF); carry = UInt32(x >> 32)
            }
        }

        var q_limbs = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 0x1_0000_0000

        for j in stride(from: m, through: 0, by: -1) {
            let uj_n  = UInt64(u[j + n])
            let top   = uj_n * base + UInt64(u[j + n - 1])
            var q_hat = min(top / UInt64(v[n - 1]), base - 1)
            var r_hat = top - q_hat * UInt64(v[n - 1])

            let vn2  = UInt64(v[n - 2])
            let ujn2 = UInt64(u[j + n - 2])
            while r_hat < base && q_hat * vn2 > r_hat * base + ujn2 {
                q_hat -= 1; r_hat += UInt64(v[n - 1])
            }

            var borrow: UInt64 = 0
            for i in 0..<n {
                let p  = q_hat * UInt64(v[i]) + borrow
                borrow = p >> 32
                let pl = UInt32(p & 0xFFFF_FFFF)
                if u[j + i] >= pl { u[j + i] -= pl }
                else              { u[j + i] &-= pl; borrow += 1 }
            }
            let neg = borrow > uj_n
            u[j + n] &-= UInt32(borrow & 0xFFFF_FFFF)

            q_limbs[j] = UInt32(q_hat)

            if neg {
                q_limbs[j] &-= 1
                var carry: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(u[j + i]) + UInt64(v[i]) + carry
                    u[j + i] = UInt32(s & 0xFFFF_FFFF); carry = s >> 32
                }
                u[j + n] &+= UInt32(carry)
            }
        }

        var rem = [UInt32](repeating: 0, count: n)
        if shift == 0 {
            for i in 0..<n { rem[i] = u[i] }
        } else {
            let rsh = 32 - shift
            for i in 0..<n {
                rem[i] = (u[i] >> shift) | (u[i + 1] << rsh)
            }
        }
        return (BigUInt(q_limbs), BigUInt(rem))
    }

    static func << (lhs: BigUInt, shift: Int) -> BigUInt {
        guard shift > 0 else { return lhs }
        let wordShift = shift / 32
        let bitShift  = shift % 32
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + wordShift + 1)
        if bitShift == 0 {
            for i in 0..<lhs.limbs.count { result[i + wordShift] = lhs.limbs[i] }
        } else {
            var carry: UInt32 = 0
            for i in 0..<lhs.limbs.count {
                let x = (UInt64(lhs.limbs[i]) << bitShift) | UInt64(carry)
                result[i + wordShift] = UInt32(x & 0xFFFF_FFFF)
                carry = UInt32(x >> 32)
            }
            result[lhs.limbs.count + wordShift] = carry
        }
        return BigUInt(result)
    }

    func power(_ exp: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var base   = self % modulus
        var e      = exp
        let zero   = BigUInt.zero
        guard !e.limbs.isEmpty else { return result }
        while !(e == zero) {
            if (e.limbs[0] & 1) == 1 {
                result = (result * base) % modulus
            }
            e = e.halved()
            base = (base * base) % modulus
        }
        return result
    }
}
// MARK: - Companion Credentials

private struct CompanionCredentials: Codable {
    var ltsk: Data      // our Ed25519 seed (32 bytes)
    var ltpk: Data      // our Ed25519 public key (32 bytes)
    var atvLtpk: Data   // ATV's Ed25519 public key (32 bytes)
    var clientId: Data  // our client ID (UUID string as UTF-8)
    var atvId: Data     // ATV's identifier as UTF-8
}

private struct CachedAppleTVDevice: Codable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var lastSeenAt: TimeInterval
}

// MARK: - AppleTVRemote

final class AppleTVRemote: NSObject, ObservableObject, StreamDelegate {

    // MARK: Published (same API — ContentView needs no changes)

    @Published var discoveredDevices: [AppleTVDevice] = []
    @Published var connectedDevice: AppleTVDevice?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectedDeviceName = ""
    @Published var isPairing = false
    @Published var debugLog: [String] = []
    @Published var needsPIN = false
    /// True while a text field on the Apple TV is focused (its on-screen keyboard is showing).
    @Published private(set) var isKeyboardActive = false

    // MARK: Private

    private var netBrowsers: [NetServiceBrowser] = []
    private var resolvingServices: [NetService] = []
    private var nwBrowsers: [NWBrowser] = []

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readBuffer = Data()

    private var activeDevice: AppleTVDevice?
    private var chacha: CompanionChaCha?

    private var srpClient: SRP.Client?
    private var srpSessionKey: Data?
    private var verifyEphemeral: Curve25519.KeyAgreement.PrivateKey?
    private var verifySharedBytes: Data?
    private var pendingCredentials: CompanionCredentials?
    private var pendingPINCompletion: ((String) -> Void)?

    private var credentials: [String: CompanionCredentials] = [:]
    private var resolvedEndpoints: [String: NWEndpoint] = [:]
    private var discoverySources: [String: Set<String>] = [:]
    private var blacklistedNonAppleCompanionIDs: Set<String> = []
    private var raopResolveNamesByService: [String: String] = [:]

    private var lastCommandDate = Date.distantPast
    private let commandCooldown: TimeInterval = 0.6
    private var cmdXid = 1
    private var queuedHIDCommands: [Int] = []
    private let maxQueuedHIDCommands = 20
    private let queuedCommandReplayInterval: TimeInterval = 0.14
    private var isFlushingQueuedCommands = false
    private var pointerQueue: [Int] = []
    private let maxPointerQueue = 6
    private let pointerPressInterval: TimeInterval = 0.07
    private var lastPointerSendDate = Date.distantPast
    private var isDrainingPointerQueue = false
    private var textInputStartXid: Int?
    private var keyboardClearWork: DispatchWorkItem?
    private var sessionEstablishedAt = Date.distantPast

    private var connectTimeoutWork: DispatchWorkItem?
    private var pendingResolveService: NetService?
    private var pendingConnectDevice: AppleTVDevice?
    private var pendingAlternateResolutionID: String?
    private var precomputedSRPClient: SRP.Client?   // ready before user taps Connect
    private var shouldMaintainConnection = false
    private var desiredDevice: AppleTVDevice?
    private var preferredDeviceID: String?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var isSubnetScanRunning = false
    private var subnetScanFallbackWork: DispatchWorkItem?
    private var connectionMonitorTimer: DispatchSourceTimer?
    private var lastInboundFrameDate = Date.distantPast
    private var isHandlingTransportFailure = false
    /// Prevents infinite ping-pong between ports 49152/49153.
    /// Set true after the first alternate-port attempt; reset on every new user-initiated connect.
    private var hasTriedAlternatePort = false
    /// Incremented on every new TCP connection attempt.
    /// Captured in async closures so stale failure callbacks from a previous
    /// connection attempt are silently discarded once a new attempt begins.
    private var connectionEpoch = 0
    /// True once the TCP output stream fires .openCompleted for the current connection.
    /// Cleared on every disconnect.  Used to distinguish connect-phase failures
    /// (port wrong / connection refused) from mid-session drops.
    private var streamOpenedSuccessfully = false
    private let connectionMonitorInterval: TimeInterval = 2
    private let preferredDeviceDefaultsKey = "companion.preferredDeviceID.v1"
    private let cachedDevicesDefaultsKey = "companion.cachedDevices.v1"

    private enum CompanionState {
        case idle
        case pvStep1    // sent PV_Start M1, waiting PV_Next M2
        case pvStep2    // sent PV_Next M3, waiting PV_Next M4 (success)
        case psStep1    // sent PS_Start M1, waiting PS_Next M2
        case psStep2    // got M2, waiting for PIN / M4
        case psStep3    // sent PS_Next M5, waiting PS_Next M6
        case ready
    }
    private var companionState: CompanionState = .idle

    // MARK: - Init

    override init() {
        super.init()
        loadCredentials()
        loadCachedDevices()
        loadPreferredDeviceID()
    }

    private func precomputeSRPClient() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            print("[SRP] precompute start")
            let t0 = Date()
            let client = SRP.Client()
            let elapsed = -t0.timeIntervalSinceNow
            print("[SRP] precompute done in \(String(format: "%.2f", elapsed))s")
            DispatchQueue.main.async { [weak self] in
                self?.precomputedSRPClient = client
                self?.log("SRP pre-warm done (\(String(format: "%.2f", elapsed))s)")
            }
        }
    }

    // MARK: - Discovery

    func startDiscovery() {
        log("Scanning for Apple TVs (_companion-link, _mediaremotetv, _airplay, _raop)...")
        stopDiscovery()
        blacklistedNonAppleCompanionIDs.removeAll()
        restoreCachedDevices()
        triggerLocalNetworkPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.startBrowsers()
        }
        // Fallback: only scan the subnet if Bonjour hasn't resolved a concrete Companion
        // endpoint after 6 s. hasLikelyAppleTVCandidate() returns true if any device
        // already has a hostPort or resolvedEndpoint — meaning Bonjour worked and the
        // scan would only collide with and corrupt the good discovery.
        let fallbackWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isConnected, !self.isConnecting, !self.isPairing else { return }
            guard !self.isSubnetScanRunning else { return }
            guard !self.hasLikelyAppleTVCandidate() else {
                self.log("Bonjour resolved an Apple TV — skipping subnet scan")
                return
            }
            self.log("No Apple TV via Bonjour — starting TCP subnet scan…")
            self.scanSubnetForAppleTV()
        }
        subnetScanFallbackWork = fallbackWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: fallbackWork)
    }

    private func hasLikelyAppleTVCandidate() -> Bool {
        for device in discoveredDevices {
            if blacklistedNonAppleCompanionIDs.contains(device.id) { continue }
            // If any device is already fully resolved (has a concrete hostPort endpoint
            // set by _companion-link or a verified probe), skip the subnet scan.
            if case .hostPort = device.endpoint { return true }
            if resolvedEndpoints[device.id] != nil { return true }
            let sources = discoverySources[device.id] ?? []
            if sources.contains("raop-resolve") ||
                sources.contains("nwbrowser:_mediaremotetv._tcp") ||
                sources.contains("netservice:_mediaremotetv._tcp") {
                return true
            }
            if device.name.lowercased().contains("apple tv") {
                return true
            }
        }
        return false
    }

    private func isLikelyAppleTV(serviceType: String,
                                 serviceName: String,
                                 txtRecord: [String: String]?) -> Bool {
        if serviceType == "_companion-link._tcp" {
            if let rpMd = txtRecord?["rpMd"], !rpMd.isEmpty {
                return rpMd.lowercased().contains("appletv")
            }
            return true
        }

        if serviceType == "_airplay._tcp" {
            if let model = txtRecord?["model"], !model.isEmpty {
                return model.lowercased().contains("appletv")
            }
            // TXT metadata is sometimes omitted in browse callbacks.
            // Allow through and decide later at connect/probe stage.
            return true
        }

        if serviceType == "_raop._tcp" {
            if let am = txtRecord?["am"], !am.isEmpty {
                return am.lowercased().hasPrefix("appletv")
            }
            return true
        }

        // _mediaremotetv is the primary service used by Apple's Remote discovery.
        return true
    }

    func rescan() {
        discoveredDevices.removeAll()
        stopDiscovery()
        startDiscovery()
    }

    func stopDiscovery() {
        subnetScanFallbackWork?.cancel()
        subnetScanFallbackWork = nil
        netBrowsers.forEach { $0.stop() }
        netBrowsers.removeAll()
        nwBrowsers.forEach { $0.cancel() }
        nwBrowsers.removeAll()
        resolvingServices.removeAll()
        discoverySources.removeAll()
        raopResolveNamesByService.removeAll()
    }

    private func triggerLocalNetworkPermission() {
        let conn = NWConnection(host: "224.0.0.251", port: 5353, using: .udp)
        conn.stateUpdateHandler = { state in
            if state == .ready { conn.send(content: Data([0]), completion: .idempotent); conn.cancel() }
        }
        conn.start(queue: .main)
    }

    private func startBrowsers() {
        for serviceType in ["_companion-link._tcp", "_mediaremotetv._tcp", "_airplay._tcp", "_appletv-v2._tcp"] {
            let nb = NetServiceBrowser()
            nb.delegate = self
            nb.schedule(in: .main, forMode: .common)
            nb.searchForServices(ofType: serviceType, inDomain: "")
            netBrowsers.append(nb)

            let desc = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
            let nwb  = NWBrowser(for: desc, using: .tcp)
            let svc  = serviceType
            nwb.stateUpdateHandler = { [weak self] s in
                switch s {
                case .failed(let e): self?.log("NWBrowser(\(svc)) failed: \(e)")
                case .ready:         self?.log("NWBrowser(\(svc)) ready")
                default: break
                }
            }
            nwb.browseResultsChangedHandler = { [weak self] results, changes in
                guard let self else { return }
                for change in changes {
                    if case .added(let r) = change,
                       case .service(let name, let t, let domain, _) = r.endpoint {
                        var txtStrings: [String: String]? = nil
                        if case .bonjour(let txtRecord) = r.metadata {
                            var parsed: [String: String] = [:]
                            for key in ["rpMd", "am", "model", "deviceid"] {
                                if let value = txtRecord[key], !value.isEmpty {
                                    parsed[key] = value
                                }
                            }
                            if !parsed.isEmpty {
                                txtStrings = parsed
                            }
                        }
                        guard self.isLikelyAppleTV(serviceType: svc,
                                                   serviceName: name,
                                                   txtRecord: txtStrings) else {
                            self.log("Skipping non-Apple-TV service [\(svc)]: \(name)")
                            continue
                        }
                        self.log("Found [\(svc)]: \(name)")
                        let ep = NWEndpoint.service(name: name, type: t, domain: domain, interface: nil)
                        let dev = AppleTVDevice(id: name, name: name, endpoint: ep)
                        self.registerDiscoveredDevice(dev, source: "nwbrowser:\(svc)")
                    } else if case .removed(let r) = change,
                              case .service(let name, _, _, _) = r.endpoint {
                        self.unregisterDiscoveredDevice(id: name, source: "nwbrowser:\(svc)")
                    }
                }
            }
            nwb.start(queue: .main)
            nwBrowsers.append(nwb)
        }

        log("Browsers started (_companion-link + _mediaremotetv + _airplay + _appletv-v2)")

        // _raop._tcp gets through routers that block _companion-link._tcp multicast.
        // Apple TV RAOP entries have TXT key am=AppleTV… and are named "MAC@DeviceName".
        // Resolve the hostname (DeviceName.local) then connect on port 49152.
        let raopDesc = NWBrowser.Descriptor.bonjour(type: "_raop._tcp", domain: nil)
        let raopBrowser = NWBrowser(for: raopDesc, using: .tcp)
        raopBrowser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                guard case .added(let r) = change,
                      case .service(let rawName, _, let domain, _) = r.endpoint else { continue }
                // RAOP names are "MACADDR@FriendlyName" — extract friendly name
                let friendlyName = rawName.contains("@")
                    ? String(rawName.split(separator: "@", maxSplits: 1).last ?? Substring(rawName))
                    : rawName
                // Filter: must have am=AppleTV in TXT record
                if case .bonjour(let txt) = r.metadata {
                    let am = txt["am"] ?? ""
                    guard am.lowercased().hasPrefix("appletv") else {
                        self.log("[_raop] skipping non-Apple-TV: \(friendlyName) (am='\(am)')")
                        continue
                    }
                    self.log("[_raop] found Apple TV: \(friendlyName) (am=\(am)) — resolving service…")
                }
                // Resolve using DNS-SD service record to handle names with spaces/symbols.
                self.resolveRAOPService(rawName: rawName, domain: domain, friendlyName: friendlyName)
            }
        }
        raopBrowser.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { self?.log("NWBrowser(_raop) failed: \(e)") }
        }
        raopBrowser.start(queue: .main)
        nwBrowsers.append(raopBrowser)
    }

    private func resolveRAOPService(rawName: String, domain: String, friendlyName: String) {
        let svc = NetService(domain: domain, type: "_raop._tcp.", name: rawName)
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        raopResolveNamesByService[rawName] = friendlyName
        resolvingServices.append(svc)
        svc.resolve(withTimeout: 8)
    }

    // MARK: - TCP Subnet Scanner (mDNS fallback)

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: ptr.pointee.ifa_name) == "en0" else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf,
                           socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: buf)
            }
        }
        return address
    }

    private func scanSubnetForAppleTV() {
        guard !isSubnetScanRunning else { return }
        isSubnetScanRunning = true

        guard let localIP = getWiFiAddress() else {
            log("TCP scan: could not determine local Wi-Fi IP")
            isSubnetScanRunning = false
            return
        }
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else {
            isSubnetScanRunning = false
            return
        }
        let prefix = parts[0...2].joined(separator: ".")
        let companionPorts = [49152, 49153]
        log("TCP scan: probing \(prefix).1-254 on ports 49152/49153…")

        let scanOpQueue = OperationQueue()
        scanOpQueue.maxConcurrentOperationCount = 20   // cap concurrent TCP probes
        let group = DispatchGroup()
        let lock = NSLock()
        var foundPortsByHost: [String: Set<Int>] = [:]

        for i in 1...254 {
            let host = "\(prefix).\(i)"
            for port in companionPorts {
                group.enter()
                scanOpQueue.addOperation {
                    var done = false
                    let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 49152
                    let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
                    let connQueue = DispatchQueue(label: "com.gestureremote.tcpscan.conn")
                    conn.stateUpdateHandler = { state in
                        guard !done else { return }
                        switch state {
                        case .ready:
                            done = true; conn.cancel()
                            lock.lock()
                            var ports = foundPortsByHost[host] ?? Set<Int>()
                            ports.insert(port)
                            foundPortsByHost[host] = ports
                            lock.unlock()
                            group.leave()
                        case .failed, .cancelled:
                            if !done { done = true; group.leave() }
                        default: break
                        }
                    }
                    conn.start(queue: connQueue)
                    // Per-endpoint timeout: 1.5 s
                    connQueue.asyncAfter(deadline: .now() + 1.5) {
                        if !done { done = true; conn.cancel(); group.leave() }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if foundPortsByHost.isEmpty {
                self.log("TCP scan: no companion-capable device found")
                self.isSubnetScanRunning = false
            } else {
                let candidates = foundPortsByHost.keys.sorted()
                let verifyGroup = DispatchGroup()

                for host in candidates {
                    let ports = foundPortsByHost[host] ?? []
                    let preferredOrder = ports.contains(49152) ? [49152, 49153] : [49153, 49152]
                    let available = preferredOrder.filter { ports.contains($0) }
                    let portsText = ports.sorted().map(String.init).joined(separator: ",")

                    guard let firstPort = available.first else { continue }

                    verifyGroup.enter()
                    self.probeCompanionEndpoint(host: host, port: firstPort) { [weak self] ok in
                        guard let self else { verifyGroup.leave(); return }
                        if ok {
                            self.log("TCP scan: verified Companion at \(host):\(firstPort) (open: \(portsText))")
                            let endpoint = NWEndpoint.hostPort(
                                host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: UInt16(firstPort))!)
                            let dev = AppleTVDevice(id: host, name: host, endpoint: endpoint)
                            self.registerDiscoveredDevice(dev, source: "tcp-scan")
                            verifyGroup.leave()
                            return
                        }

                        if available.count > 1 {
                            let secondPort = available[1]
                            self.probeCompanionEndpoint(host: host, port: secondPort) { [weak self] ok2 in
                                guard let self else { verifyGroup.leave(); return }
                                if ok2 {
                                    self.log("TCP scan: verified Companion at \(host):\(secondPort) (open: \(portsText))")
                                    let endpoint = NWEndpoint.hostPort(
                                        host: NWEndpoint.Host(host),
                                        port: NWEndpoint.Port(rawValue: UInt16(secondPort))!)
                                    let dev = AppleTVDevice(id: host, name: host, endpoint: endpoint)
                                    self.registerDiscoveredDevice(dev, source: "tcp-scan")
                                } else {
                                    self.log("TCP scan: host \(host) open but not Companion (open: \(portsText))")
                                }
                                verifyGroup.leave()
                            }
                        } else {
                            self.log("TCP scan: host \(host) open but not Companion (open: \(portsText))")
                            verifyGroup.leave()
                        }
                    }
                }

                verifyGroup.notify(queue: .main) { [weak self] in
                    guard let self else { return }
                    if self.discoveredDevices.isEmpty {
                        self.log("TCP scan: no Apple TV Companion endpoint verified")
                    }
                    self.isSubnetScanRunning = false
                }
            }
        }
    }

    private func probeCompanionEndpoint(host: String,
                                        port: Int,
                                        completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(false)
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.gestureremote.probe.\(host).\(port)")
        var finished = false

        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { completion(ok) }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Some Apple TV states accept TCP on Companion ports but remain silent
                // until a full session start. Treat successful connect as valid.
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }

        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3.0) {
            finish(false)
        }
    }

    private func probeFirstCompanionPort(host: String,
                                         ports: [Int],
                                         completion: @escaping (Int?) -> Void) {
        let validPorts = Array(Set(ports)).filter { $0 > 0 && $0 <= 65535 }
        guard !validPorts.isEmpty else {
            completion(nil)
            return
        }

        let preferred = ports.first
        let ordered = validPorts.sorted {
            if $0 == preferred { return true }
            if $1 == preferred { return false }
            return $0 < $1
        }

        func attempt(_ index: Int) {
            guard index < ordered.count else {
                completion(nil)
                return
            }
            let port = ordered[index]
            probeCompanionEndpoint(host: host, port: port) { ok in
                if ok {
                    completion(port)
                } else {
                    attempt(index + 1)
                }
            }
        }

        attempt(0)
    }

    private func registerDiscoveredDevice(_ device: AppleTVDevice, source: String = "unknown") {
        if blacklistedNonAppleCompanionIDs.contains(device.id) {
            return
        }

        var sources = discoverySources[device.id] ?? Set<String>()
        sources.insert(source)
        discoverySources[device.id] = sources

        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
        cacheDeviceIfHostPort(device)
        maybeAutoConnect(to: device)
    }

    private func cacheDeviceIfHostPort(_ device: AppleTVDevice) {
        guard case .hostPort(let host, let port) = device.endpoint else { return }

        // If a _companion-link resolution already set a live endpoint for this device,
        // only cache if we're using that same endpoint. This prevents the _mediaremotetv
        // probe (which may match port 49152 on a non-Companion service) from overwriting
        // a correct live port in the cache.
        if let resolved = resolvedEndpoints[device.id],
           case .hostPort(_, let resolvedPort) = resolved,
           resolvedPort.rawValue != port.rawValue {
            return
        }

        let hostString: String
        switch host {
        case .name(let n, _): hostString = n
        case .ipv4(let addr): hostString = "\(addr)"
        case .ipv6(let addr): hostString = "\(addr)"
        @unknown default: return
        }

        let cached = CachedAppleTVDevice(
            id: device.id,
            name: device.name,
            host: hostString,
            port: Int(port.rawValue),
            lastSeenAt: Date().timeIntervalSince1970
        )
        saveCachedDevice(cached)
    }

    private func saveCachedDevice(_ device: CachedAppleTVDevice) {
        var all = loadCachedDevicesFromDefaults()
        all.removeAll { $0.id == device.id }
        all.append(device)
        all.sort { $0.lastSeenAt > $1.lastSeenAt }
        if all.count > 8 {
            all = Array(all.prefix(8))
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: cachedDevicesDefaultsKey)
        }
    }

    private func removeCachedDevice(id: String, reason: String) {
        var all = loadCachedDevicesFromDefaults()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: cachedDevicesDefaultsKey)
        }
        log("Removed cached endpoint for \(id): \(reason)")
    }

    private func loadCachedDevices() {
        let cached = loadCachedDevicesFromDefaults()
        if !cached.isEmpty {
            log("Loaded \(cached.count) cached Apple TV endpoint(s)")
        }
    }

    private func loadCachedDevicesFromDefaults() -> [CachedAppleTVDevice] {
        guard let data = UserDefaults.standard.data(forKey: cachedDevicesDefaultsKey),
              let devices = try? JSONDecoder().decode([CachedAppleTVDevice].self, from: data) else {
            return []
        }
        return devices
    }

    private func restoreCachedDevices() {
        let cached = loadCachedDevicesFromDefaults()
        guard !cached.isEmpty else { return }

        for c in cached {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(c.port)) else { continue }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(c.host), port: nwPort)
            let dev = AppleTVDevice(id: c.id, name: c.name, endpoint: endpoint)
            // Register without auto-connecting — Bonjour hasn't run yet and the
            // cached port may be stale. Auto-connect is deferred until after Bonjour
            // resolution has had a chance to update resolvedEndpoints with the live port.
            if let idx = discoveredDevices.firstIndex(where: { $0.id == dev.id }) {
                discoveredDevices[idx] = dev
            } else {
                discoveredDevices.append(dev)
            }
            var sources = discoverySources[dev.id] ?? Set<String>()
            sources.insert("cache")
            discoverySources[dev.id] = sources
        }
        log("Restored \(cached.count) cached Apple TV endpoint(s)")

        // Give Bonjour 2 s to resolve the live port before allowing auto-connect
        // from the cache. If Bonjour updates resolvedEndpoints in that window,
        // connect(to:) will use the live endpoint instead of the stale cached one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.isConnected, !self.isConnecting else { return }
            for dev in self.discoveredDevices {
                // Prefer a Bonjour-resolved endpoint over the cached one
                if let resolved = self.resolvedEndpoints[dev.id],
                   case .hostPort(let host, let port) = resolved {
                    let freshDev = AppleTVDevice(id: dev.id, name: dev.name,
                                                 endpoint: .hostPort(host: host, port: port))
                    self.maybeAutoConnect(to: freshDev)
                } else {
                    self.maybeAutoConnect(to: dev)
                }
            }
        }
    }

    private func unregisterDiscoveredDevice(id: String, source: String) {
        var sources = discoverySources[id] ?? Set<String>()
        sources.remove(source)

        if sources.isEmpty {
            discoverySources.removeValue(forKey: id)
            discoveredDevices.removeAll { $0.id == id }
            resolvedEndpoints.removeValue(forKey: id)
        } else {
            discoverySources[id] = sources
        }
    }

    private func blacklistNonAppleCompanionID(_ id: String, reason: String) {
        blacklistedNonAppleCompanionIDs.insert(id)
        discoverySources.removeValue(forKey: id)
        resolvedEndpoints.removeValue(forKey: id)
        discoveredDevices.removeAll { $0.id == id }
        if pendingConnectDevice?.id == id {
            pendingConnectDevice = nil
        }
        if activeDevice?.id == id, !isConnected {
            desiredDevice = nil
        }
        log("Ignoring \(id): \(reason)")
    }

    private func maybeAutoConnect(to device: AppleTVDevice) {
        guard !isConnected, !isConnecting, !isPairing else { return }

        let isResolvedDevice: Bool
        switch device.endpoint {
        case .hostPort:
            isResolvedDevice = true
        default:
            isResolvedDevice = resolvedEndpoints[device.id] != nil
        }

        guard isResolvedDevice else {
            log("Auto-connect deferred until \(device.name) resolves")
            return
        }

        if let preferredDeviceID, device.id == preferredDeviceID {
            log("Auto-connecting to saved Apple TV: \(device.name)")
            connect(to: device)
            return
        }

        let pairedDiscoveredDevices = discoveredDevices.filter { credentials[$0.id] != nil }
        if preferredDeviceID == nil, pairedDiscoveredDevices.count == 1, pairedDiscoveredDevices[0].id == device.id {
            log("Auto-connecting to paired Apple TV: \(device.name)")
            connect(to: device)
            return
        }

        if preferredDeviceID == nil, credentials.isEmpty, discoveredDevices.count == 1 {
            log("Auto-connecting to only discovered Apple TV: \(device.name)")
            connect(to: device)
        }
    }

    // MARK: - Connect

    func connect(to device: AppleTVDevice) {
        reconnectWork?.cancel(); reconnectWork = nil
        performDisconnect(manual: false)
        desiredDevice = device
        shouldMaintainConnection = true
        reconnectAttempt = 0   // user-initiated: reset backoff
        hasTriedAlternatePort = false  // fresh connect: allow one alternate-port attempt
        log("Connecting to \(device.name)...")
        isConnecting = true

        // Always prefer a freshly resolved Bonjour endpoint over a possibly stale
        // hostPort carried by cached/manual discovery objects.
        if let resolved = resolvedEndpoints[device.id] {
            if case .hostPort(let host, let port) = resolved {
                log("[PortFlow] using resolved endpoint first for \(device.name): \(host):\(port.rawValue)")
            }
            startTCPConnection(to: device, endpoint: resolved)
            return
        }

        // Devices discovered via RAOP/TCP scan already have a concrete hostPort.
        // Do not re-resolve through _companion-link mDNS (often blocked on this LAN).
        if case .hostPort = device.endpoint {
            if case .hostPort(let host, let port) = device.endpoint {
                log("[PortFlow] using cached/manual endpoint first for \(device.name): \(host):\(port.rawValue)")
            }
            startTCPConnection(to: device, endpoint: device.endpoint)
            return
        }

        log("[PortFlow] no direct endpoint for \(device.name), resolving via _companion-link")
        resolveAndConnect(device: device)
    }

    private func resolveAndConnect(device: AppleTVDevice) {
        log("Resolving \(device.id) via mDNS...")
        pendingAlternateResolutionID = nil
        let svc = NetService(domain: "local.", type: "_companion-link._tcp", name: device.id)
        svc.delegate = self
        svc.schedule(in: .main, forMode: .common)
        pendingResolveService = svc
        pendingConnectDevice = device

        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isConnecting else { return }
            self.log("mDNS resolve timed out -- try Manual IP (port 49153)")
            self.pendingResolveService?.stop()
            self.pendingResolveService = nil
            self.pendingConnectDevice = nil
            self.isConnecting = false
            self.scheduleReconnect(reason: "mDNS resolve timed out")
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        svc.resolve(withTimeout: 8)
    }

    private func resolveAndConnectViaAlternateServices(device: AppleTVDevice) {
        pendingResolveService?.stop()
        pendingResolveService = nil
        pendingConnectDevice = device
        pendingAlternateResolutionID = device.id

        let serviceTypes = ["_mediaremotetv._tcp", "_airplay._tcp", "_appletv-v2._tcp"]
        log("Companion-link resolution failed for \(device.name) -- trying alternate service resolution")

        connectTimeoutWork?.cancel()
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isConnecting, self.pendingConnectDevice?.id == device.id else { return }
            self.pendingConnectDevice = nil
            self.pendingAlternateResolutionID = nil
            self.isConnecting = false
            self.log("Alternate service resolution timed out for \(device.name)")
            self.scheduleReconnect(reason: "alternate service resolution timed out")
        }
        connectTimeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeoutWork)

        for type in serviceTypes {
            let svc = NetService(domain: "local.", type: type, name: device.id)
            svc.delegate = self
            svc.schedule(in: .main, forMode: .common)
            resolvingServices.append(svc)
            svc.resolve(withTimeout: 5)
        }
    }

    private func startTCPConnection(to device: AppleTVDevice, endpoint: NWEndpoint) {
        connectTimeoutWork?.cancel()

        let hostname: String
        let portNum: Int
        switch endpoint {
        case .hostPort(let host, let port):
            portNum = Int(port.rawValue)
            switch host {
            case .name(let n, _): hostname = n
            case .ipv4(let addr): hostname = "\(addr)"
            case .ipv6(let addr): hostname = "\(addr)"
            @unknown default: log("Unknown host type"); isConnecting = false; return
            }
        default:
            log("Need a hostPort endpoint -- tap Manual IP (port 49153)")
            isConnecting = false
            return
        }

        connectionEpoch += 1
        log("TCP connecting to \(hostname):\(portNum)...")
        activeDevice = device
        readBuffer = Data()
        companionState = .idle

        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: hostname, port: portNum,
                                inputStream: &inStream, outputStream: &outStream)
        guard let inp = inStream, let out = outStream else {
            log("Failed to create streams"); isConnecting = false; return
        }
        inputStream = inp; outputStream = out
        inp.delegate = self; out.delegate = self
        inp.schedule(in: .main, forMode: .common)
        out.schedule(in: .main, forMode: .common)
        inp.open(); out.open()

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.isConnecting else { return }
            self.log("TCP timed out")
            let failingDevice = self.activeDevice ?? self.desiredDevice
            let failingEndpoint = self.activeDevice?.endpoint ?? self.desiredDevice?.endpoint
            self.closeStreams(); self.isConnecting = false
            if let dev = failingDevice {
                self.removeCachedDevice(id: dev.id, reason: "TCP connect timeout")
            }
            if self.tryAlternateCompanionPort(for: device, from: endpoint, reason: "TCP connect timed out") {
                return
            }
            if let dev = failingDevice, let ep = failingEndpoint {
                self.attemptCompanionPortRecovery(for: dev, from: ep, reason: "TCP connect timed out")
                self.prepareReresolutionAfterConnectPhaseFailure(device: dev, failingEndpoint: ep, reason: "TCP connect timed out")
            }
            self.scheduleReconnect(reason: "TCP connect timed out")
        }
        connectTimeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutWork)
    }

    private func prepareReresolutionAfterConnectPhaseFailure(device: AppleTVDevice,
                                                             failingEndpoint: NWEndpoint,
                                                             reason: String) {
        resolvedEndpoints.removeValue(forKey: device.id)

        // If we connected through a Bonjour service name (typical Apple TV discovery),
        // switch desiredDevice back to a service endpoint so next reconnect resolves
        // the current live Companion port instead of reusing a stale one.
        if !device.id.contains(".") {
            let serviceEp = NWEndpoint.service(name: device.id, type: "_companion-link._tcp",
                                               domain: "local.", interface: nil)
            desiredDevice = AppleTVDevice(id: device.id, name: device.name, endpoint: serviceEp)
            log("[PortFlow] dropped stale endpoint for \(device.name); forcing _companion-link re-resolution")
            log("\(reason) — will re-resolve \(device.name) via Bonjour on next attempt")
            return
        }

        // For IP-based/manual IDs we cannot reliably re-resolve by Bonjour name.
        // Keep the hostPort and rely on alternate-port + backoff reconnect path.
        desiredDevice = AppleTVDevice(id: device.id, name: device.name, endpoint: failingEndpoint)
    }

    private func tryAlternateCompanionPort(for device: AppleTVDevice,
                                           from endpoint: NWEndpoint,
                                           reason: String) -> Bool {
        // Only try the alternate port once per connection cycle.
        // If we've already bounced ports, fall back to scheduleReconnect so backoff applies.
        guard !hasTriedAlternatePort else { return false }
        guard case .hostPort(let host, let port) = endpoint else { return false }
        let current = Int(port.rawValue)
        let alternate: Int
        if current == 49152 {
            alternate = 49153
        } else if current == 49153 {
            alternate = 49152
        } else {
            return false
        }

        guard let alternatePort = NWEndpoint.Port(rawValue: UInt16(alternate)) else { return false }
        let alternateEndpoint = NWEndpoint.hostPort(host: host, port: alternatePort)
        let alternateDevice = AppleTVDevice(id: device.id, name: device.name, endpoint: alternateEndpoint)

        hasTriedAlternatePort = true  // mark so the next failure goes to backoff reconnect
        log("\(reason) -- retrying \(device.name) on port \(alternate)")
        // Do NOT change desiredDevice or resolvedEndpoints here.
        // desiredDevice must stay pointing to the original port so that when the
        // alternate also fails, scheduleReconnect reconnects to the original port,
        // not the alternate — preventing the 49152↔49153 ping-pong.
        startTCPConnection(to: alternateDevice, endpoint: alternateEndpoint)
        return true
    }

    private func attemptCompanionPortRecovery(for device: AppleTVDevice,
                                              from endpoint: NWEndpoint,
                                              reason: String) {
        guard !hasTriedAlternatePort else { return }
        guard case .hostPort(let host, let port) = endpoint else { return }

        let currentPort = Int(port.rawValue)
        guard currentPort != 49152, currentPort != 49153 else { return }

        let hostString: String
        switch host {
        case .name(let n, _): hostString = n
        case .ipv4(let addr): hostString = "\(addr)"
        case .ipv6(let addr): hostString = "\(addr)"
        @unknown default: return
        }

        hasTriedAlternatePort = true
        log("\(reason) -- probing fallback Companion ports [49153, 49152] for \(hostString)")

        probeFirstCompanionPort(host: hostString, ports: [49153, 49152]) { [weak self] matchedPort in
            guard let self else { return }
            guard let matchedPort,
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(matchedPort)) else {
                self.log("\(reason) -- no fallback Companion port responded")
                return
            }

            let recoveredEndpoint = NWEndpoint.hostPort(host: host, port: nwPort)
            let recoveredDevice = AppleTVDevice(id: device.id, name: device.name, endpoint: recoveredEndpoint)
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.performDisconnect(manual: false)
            self.isConnecting = true
            self.log("Recovered Companion endpoint for \(device.name) on port \(matchedPort) -- reconnecting now")
            self.startTCPConnection(to: recoveredDevice, endpoint: recoveredEndpoint)
        }
    }

    func connectManually(host: String, port: Int) {
        let portVal = NWEndpoint.Port(rawValue: UInt16(port)) ?? 49153
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portVal)
        let dev = AppleTVDevice(id: host, name: host, endpoint: endpoint)
        if !discoveredDevices.contains(where: { $0.id == host }) {
            registerDiscoveredDevice(dev, source: "manual")
        }
        connect(to: dev)
    }

    func disconnect() {
        performDisconnect(manual: true)
    }

    private func performDisconnect(manual: Bool) {
        connectTimeoutWork?.cancel(); connectTimeoutWork = nil
        pendingResolveService?.stop(); pendingResolveService = nil
        pendingConnectDevice = nil
        pendingAlternateResolutionID = nil
        if manual {
            shouldMaintainConnection = false
            desiredDevice = nil
            reconnectWork?.cancel(); reconnectWork = nil
            reconnectAttempt = 0
        }
        closeStreams(); activeDevice = nil
        chacha = nil; cmdXid = 1
        srpClient = nil; srpSessionKey = nil
        verifyEphemeral = nil; verifySharedBytes = nil
        pendingCredentials = nil; pendingPINCompletion = nil
        isConnected = false; isConnecting = false
        textInputStartXid = nil
        // The TV drops the connection every so often and we reconnect within ~1 s; keep the
        // keyboard state through that so typing isn't interrupted. Cleared only if still down.
        keyboardClearWork?.cancel()
        let clear = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected else { return }
            self.setKeyboardActive(false)
        }
        keyboardClearWork = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: clear)
        connectedDevice = nil; connectedDeviceName = ""
        isPairing = false; needsPIN = false
        companionState = .idle
        isFlushingQueuedCommands = false
        if manual {
            queuedHIDCommands.removeAll()
        }
        stopConnectionMonitor()
        lastInboundFrameDate = .distantPast
        isHandlingTransportFailure = false
        streamOpenedSuccessfully = false
    }

    private func scheduleReconnect(reason: String) {
        guard shouldMaintainConnection else { return }
        guard let device = desiredDevice ?? activeDevice else { return }
        guard !isConnected, !isConnecting else { return }
        // Never interrupt an ongoing pairing — let it complete so credentials get saved.
        // The pairing will schedule its own reconnect if the connection drops mid-setup.
        guard !isPairing else {
            log("\(reason) -- reconnect deferred (pairing in progress)")
            return
        }

        reconnectWork?.cancel()
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt - 1)))  // 1, 2, 4, 8, 16, 30s cap
        log("\(reason) -- reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempt))")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldMaintainConnection else { return }
            guard !self.isConnected, !self.isConnecting else { return }
            // Use the live desiredDevice: a caller may have switched it to a .service
            // endpoint to force Bonjour re-resolution after a connect-phase failure.
            guard let liveDevice = self.desiredDevice else { return }
            self.log("Reconnecting to \(liveDevice.name) (attempt \(self.reconnectAttempt))")
            // New backoff cycle: allow one alternate-port attempt for this cycle.
            self.hasTriedAlternatePort = false
            // Call internal reconnect — does NOT reset reconnectAttempt
            self.performDisconnect(manual: false)
            self.isConnecting = true
            self.log("Connecting to \(liveDevice.name)...")

            if let resolved = self.resolvedEndpoints[liveDevice.id] {
                self.startTCPConnection(to: liveDevice, endpoint: resolved)
                return
            }
            if case .hostPort = liveDevice.endpoint {
                self.startTCPConnection(to: liveDevice, endpoint: liveDevice.endpoint)
                return
            }
            self.resolveAndConnect(device: liveDevice)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeStreams() {
        inputStream?.close(); inputStream?.remove(from: .main, forMode: .common); inputStream = nil
        outputStream?.close(); outputStream?.remove(from: .main, forMode: .common); outputStream = nil
        readBuffer = Data()
    }

    private func startConnectionMonitor() {
        stopConnectionMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + connectionMonitorInterval,
                       repeating: connectionMonitorInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.shouldMaintainConnection else { return }
            guard !self.isConnecting else { return }

            guard self.isConnected else {
                self.scheduleReconnect(reason: "Monitor: disconnected")
                return
            }

            guard let input = self.inputStream, let output = self.outputStream else {
                self.handleTransportFailure(reason: "Monitor: stream missing")
                return
            }

            let badStatuses: Set<Stream.Status> = [.closed, .error, .notOpen]
            if badStatuses.contains(input.streamStatus) || badStatuses.contains(output.streamStatus) {
                self.handleTransportFailure(
                    reason: "Monitor: bad stream status in=\(input.streamStatus.rawValue) out=\(output.streamStatus.rawValue)"
                )
                return
            }

        }
        connectionMonitorTimer = timer
        timer.resume()
    }

    private func stopConnectionMonitor() {
        connectionMonitorTimer?.cancel()
        connectionMonitorTimer = nil
    }

    private func handleTransportFailure(reason: String) {
        guard !isHandlingTransportFailure else { return }
        isHandlingTransportFailure = true
        performDisconnect(manual: false)
        scheduleReconnect(reason: reason)
    }

    // MARK: - Companion Frame I/O

    private func sendFrame(type: CompanionFrameType, payload: Data) {
        let len = payload.count
        var frame = Data([
            type.rawValue,
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8)  & 0xFF),
            UInt8( len        & 0xFF)
        ])
        frame += payload
        log("-> Frame type=\(type.rawValue) payloadLen=\(len)")
        sendRaw(frame)
    }

    private func sendEOPACK(_ dict: [String: Any]) {
        guard let chach = chacha else { log("sendEOPACK: no session keys"); return }
        let plain = OPACK.encode(dict)
        let encLen = plain.count + 16
        let header = Data([
            CompanionFrameType.eOPACK.rawValue,
            UInt8((encLen >> 16) & 0xFF),
            UInt8((encLen >> 8)  & 0xFF),
            UInt8( encLen        & 0xFF)
        ])
        guard let encrypted = try? chach.encrypt(plain, aad: header) else {
            log("E_OPACK encrypt failed"); return
        }
        sendRaw(header + encrypted)
    }

    private func sendRaw(_ data: Data) {
        guard let out = outputStream else { return }
        var didFailWrite = false
        var writeFailureReason = ""
        data.withUnsafeBytes { ptr in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = out.write(base.advanced(by: offset), maxLength: data.count - offset)
                if written < 0 {
                    let err = out.streamError?.localizedDescription ?? "unknown"
                    log("sendRaw: write error \(err)")
                    didFailWrite = true
                    writeFailureReason = "write error: \(err)"
                    return
                }
                if written == 0 {
                    log("sendRaw: no progress (wrote 0 bytes)")
                    didFailWrite = true
                    writeFailureReason = "write stalled"
                    return
                }
                offset += written
            }
        }
        if didFailWrite {
            let epoch = connectionEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionEpoch == epoch else { return }
                self.handleTransportFailure(reason: writeFailureReason)
            }
        }
    }

    // MARK: - Frame Parser

    private func processReadBuffer() {
        while true {
            let snapshot = readBuffer
            guard snapshot.count >= 4 else { return }

            let frameType = snapshot[0]
            let length = Int(snapshot[1]) << 16 | Int(snapshot[2]) << 8 | Int(snapshot[3])
            guard snapshot.count >= 4 + length else { return }

            let frameSize = 4 + length
            let frame = Data(snapshot.prefix(frameSize))
            let header = Data(frame.prefix(4))
            let payload = Data(frame.dropFirst(4))
            // Consume from the same immutable snapshot to avoid traps if
            // readBuffer changes re-entrantly during stream callbacks.
            readBuffer = Data(snapshot.dropFirst(frameSize))
            lastInboundFrameDate = Date()
            handleFrame(type: frameType, header: header, payload: payload)
        }
    }

    private func handleFrame(type: UInt8, header: Data, payload: Data) {
        switch type {
        case CompanionFrameType.psNext.rawValue:
            guard let opack = OPACK.decodeDict(payload) else {
                let hex = payload.prefix(12).map { String(format: "%02x", $0) }.joined()
                log("<- PS_Next: OPACK decode failed (\(payload.count)B start:\(hex))")
                return
            }
            guard let pdData = opack["_pd"] as? Data else {
                log("<- PS_Next: _pd missing (keys:\(opack.keys.sorted().joined(separator: ",")))")
                return
            }
            let pd = TLV8.decode(pdData)
            log("<- PS_Next seqNo=\((pd[TLVTag.seqNo]?.first).map { String($0) } ?? "?")")
            handlePairSetupResponse(tlv: pd)

        case CompanionFrameType.pvNext.rawValue:
            guard let opack = OPACK.decodeDict(payload) else {
                let hex = payload.prefix(12).map { String(format: "%02x", $0) }.joined()
                log("<- PV_Next: OPACK decode failed (\(payload.count)B start:\(hex))")
                return
            }
            guard let pdData = opack["_pd"] as? Data else {
                log("<- PV_Next: _pd missing (keys:\(opack.keys.sorted().joined(separator: ",")))")
                return
            }
            let pd = TLV8.decode(pdData)
            log("<- PV_Next seqNo=\((pd[TLVTag.seqNo]?.first).map { String($0) } ?? "?")")
            handlePairVerifyResponse(tlv: pd)

        case CompanionFrameType.eOPACK.rawValue:
            guard let chach = chacha else { return }
            // Always decrypt (advances the receive counter), then look at the message.
            guard let plain = try? chach.decrypt(payload, aad: header),
                  let message = OPACK.decodeDict(plain) else { return }
            handleCompanionMessage(message)

        case CompanionFrameType.uOPACK.rawValue:
            let opack = OPACK.decodeDict(payload)
            log("<- U_OPACK keys=[\(opack?.keys.sorted().joined(separator: ",") ?? "")]")

        case 16:  // SessionStartRequest — TV sends this as its opening handshake
            log("<- SessionStartRequest (\(payload.count)B) -- responding then starting pairing")
            sendRaw(Data([17,0,0,0]))   // SessionStartResponse, empty payload
            beginPairing()

        default:
            log("<- Frame type=\(type) len=\(payload.count)")
        }
    }

    // MARK: - Pair Verify

    private func startPairVerify(creds: CompanionCredentials) {
        log("PairVerify: starting...")
        companionState = .pvStep1
        let ek = Curve25519.KeyAgreement.PrivateKey()
        verifyEphemeral = ek
        let ourPub = ek.publicKey.rawRepresentation
        let tlv = TLV8.encode([
            (TLVTag.seqNo,     Data([0x01])),
            (TLVTag.publicKey, ourPub)
        ])
        let payload = OPACK.encode(["_pd": tlv, "_auTy": 4] as [String: Any])
        sendFrame(type: .pvStart, payload: payload)
    }

    private func handlePairVerifyResponse(tlv: [UInt8: Data]) {
        if tlv[TLVTag.error] != nil {
            log("PairVerify: error from ATV -- starting PairSetup (credentials kept until new pairing succeeds)")
            // Do NOT clear credentials here. A transient network error causes ATV to return an
            // error on PairVerify, and wiping credentials at this point makes the app permanently
            // lose the pairing on the next reconnect. Credentials will be overwritten naturally
            // when PairSetup M6 completes successfully.
            startPairSetup()
            return
        }
        guard let seqNo = tlv[TLVTag.seqNo]?.first else { log("PV: no seqNo"); return }

        switch (companionState, seqNo) {
        case (.pvStep1, 0x02):
            handlePairVerifyM2(tlv: tlv)

        case (.pvStep2, 0x04):
            guard let sharedBytes = verifySharedBytes else { return }
            let outputKey = hkdfSHA512(inputKeyMaterial: sharedBytes,
                                       salt: Data(),
                                       info: Data("ClientEncrypt-main".utf8),
                                       outputByteCount: 32)
            let inputKey  = hkdfSHA512(inputKeyMaterial: sharedBytes,
                                       salt: Data(),
                                       info: Data("ServerEncrypt-main".utf8),
                                       outputByteCount: 32)
            chacha = CompanionChaCha(outputKey: outputKey, inputKey: inputKey)
            companionState = .ready
            isConnected = true
            connectedDevice = activeDevice
            connectedDeviceName = activeDevice?.name ?? ""
            if let deviceID = activeDevice?.id { savePreferredDeviceID(deviceID) }
            reconnectAttempt = 0
            lastInboundFrameDate = Date()
            startConnectionMonitor()
            log("Session established -- ready for commands")
            sessionEstablishedAt = Date()
            startKeyboardEvents()
            flushQueuedCommandsIfNeeded()

        default:
            log("PairVerify: unexpected seqNo=\(seqNo) in state=\(companionState)")
        }
    }

    private func handlePairVerifyM2(tlv: [UInt8: Data]) {
        guard let serverPK_data = tlv[TLVTag.publicKey],
              let encrypted     = tlv[TLVTag.encryptedData],
              let ek            = verifyEphemeral,
              let dev           = activeDevice,
              let creds         = credentials[dev.id] else {
            log("PairVerify M2: missing data"); return
        }

        guard let serverPK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPK_data),
              let shared   = try? ek.sharedSecretFromKeyAgreement(with: serverPK) else {
            log("PairVerify M2: DH failed"); return
        }
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        verifySharedBytes = sharedBytes

        let verifyKey = hkdfSHA512(inputKeyMaterial: sharedBytes,
                                   salt: Data("Pair-Verify-Encrypt-Salt".utf8),
                                   info: Data("Pair-Verify-Encrypt-Info".utf8),
                                   outputByteCount: 32)
        let symKey = SymmetricKey(data: verifyKey)
        let ct = encrypted.dropLast(16); let tag = encrypted.suffix(16)
        guard let box   = try? ChaChaPoly.SealedBox(nonce: pairingNonce("PV-Msg02"), ciphertext: ct, tag: tag),
              let inner = try? ChaChaPoly.open(box, using: symKey, authenticating: Data()) else {
            log("PairVerify M2: decrypt failed"); return
        }
        let innerTLV = TLV8.decode(inner)
        let theirId  = innerTLV[TLVTag.identifier] ?? Data()
        let theirSig = innerTLV[TLVTag.signature]  ?? Data()

        // Verify server signature
        let verifyMsg = serverPK_data + theirId + ek.publicKey.rawRepresentation
        if !creds.atvLtpk.isEmpty,
           let serverSignKey = try? Curve25519.Signing.PublicKey(rawRepresentation: creds.atvLtpk) {
            let valid = (try? serverSignKey.isValidSignature(theirSig, for: verifyMsg)) ?? false
            if !valid {
                log("PairVerify M2: server sig invalid -- keeping credentials, will retry via PairSetup")
                // Don't clear credentials on a single sig failure; it may be a transient issue.
                // A successful PairSetup will overwrite them if they're truly stale.
                startPairSetup(); return
            }
            log("PairVerify M2: server sig OK")
        }

        // Sign our response
        let signMsg = ek.publicKey.rawRepresentation + creds.clientId + serverPK_data
        guard let clientSignKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: creds.ltsk),
              let ourSig = try? clientSignKey.signature(for: signMsg) else {
            log("PairVerify M2: signing failed"); return
        }

        let innerOut = TLV8.encode([
            (TLVTag.identifier, creds.clientId),
            (TLVTag.signature,  ourSig)
        ])
        guard let sealed3 = try? ChaChaPoly.seal(innerOut, using: symKey,
                                                  nonce: pairingNonce("PV-Msg03"),
                                                  authenticating: Data()) else {
            log("PairVerify M2: encrypt M3 failed"); return
        }
        let tlv3 = TLV8.encode([
            (TLVTag.seqNo,         Data([0x03])),
            (TLVTag.encryptedData, sealed3.ciphertext + sealed3.tag)
        ])
        companionState = .pvStep2
        sendFrame(type: .pvNext, payload: OPACK.encode(["_pd": tlv3] as [String: Any]))
    }

    // MARK: - Pair Setup (TV shows PIN; user reads and enters it)

    private func beginPairing() {
        guard companionState == .idle, let dev = activeDevice else { return }
        if let creds = credentials[dev.id] {
            log("Credentials found -- starting PairVerify")
            startPairVerify(creds: creds)
        } else {
            log("No credentials -- starting PairSetup (watch Apple TV for PIN)")
            startPairSetup()
        }
    }

    private func startPairSetup() {
        log("PairSetup: starting -- watch Apple TV screen for PIN")
        isPairing = true
        companionState = .psStep1

        log("PairSetup: computing SRP client...")
        let epochAtStart = connectionEpoch
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let client = SRP.Client()
            let elapsed = -t0.timeIntervalSinceNow
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.connectionEpoch == epochAtStart,
                      self.companionState == .psStep1 else { return }
                self.log("PairSetup: SRP client ready (\(String(format: "%.2f", elapsed))s)")
                self.srpClient = client
                self.sendPSStart()
            }
        }
    }

    private func sendPSStart() {
        let tlv = TLV8.encode([
            (TLVTag.method, Data([0x00])),
            (TLVTag.seqNo,  Data([0x01]))
        ])
        log("PairSetup M1: sending PS_Start")
        sendFrame(type: .psStart, payload: OPACK.encode(["_pd": tlv, "_pwTy": 1] as [String: Any]))
    }

    private func handlePairSetupResponse(tlv: [UInt8: Data]) {
        if tlv[TLVTag.error] != nil {
            log("PairSetup error=\(tlv[TLVTag.error]?.first ?? 0)")
            isPairing = false; needsPIN = false; isConnecting = false
            return
        }
        guard let seqNo = tlv[TLVTag.seqNo]?.first else { log("PS: no seqNo"); return }
        switch seqNo {
        case 0x02: handlePairSetupM2(tlv: tlv)
        case 0x04: handlePairSetupM4(tlv: tlv)
        case 0x06: handlePairSetupM6(tlv: tlv)
        default:   log("PairSetup: unexpected seqNo=\(seqNo)")
        }
    }

    private func handlePairSetupM2(tlv: [UInt8: Data]) {
        guard let salt   = tlv[TLVTag.salt],
              let B_data = tlv[TLVTag.publicKey] else {
            log("PairSetup M2: missing salt/pubkey"); return
        }
        log("PairSetup M2: received -- check Apple TV for PIN")
        companionState = .psStep2
        needsPIN = true
        pendingPINCompletion = { [weak self] pin in
            guard let self, let srp = self.srpClient else { return }
            self.log("PairSetup M3: computing SRP (may take a few seconds)...")
            // computeClientKey is a 3072-bit modular exponentiation — must run off main thread
            let capturedSrp = srp
            let capturedSalt = salt
            let capturedBData = B_data
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (_, M1, K) = capturedSrp.computeClientKey(
                    salt: capturedSalt, password: pin, B_data: capturedBData)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.srpSessionKey = K
                    let tlv3 = TLV8.encode([
                        (TLVTag.seqNo,     Data([0x03])),
                        (TLVTag.publicKey, capturedSrp.A.toData()),
                        (TLVTag.proof,     M1)
                    ])
                    self.log("PairSetup M3: sending SRP proof")
                    self.sendFrame(type: .psNext,
                                   payload: OPACK.encode(["_pd": tlv3, "_pwTy": 1] as [String: Any]))
                }
            }
        }
    }

    func submitPIN(_ pin: String) {
        needsPIN = false
        pendingPINCompletion?(pin)
        pendingPINCompletion = nil
    }

    private func handlePairSetupM4(tlv: [UInt8: Data]) {
        log("PairSetup M4: proof accepted -- sending M5")
        guard let K = srpSessionKey else { log("PairSetup M4: no session key"); return }
        sendPairSetupM5(sessionKey: K)
    }

    private func sendPairSetupM5(sessionKey K: Data) {
        let signingKey = Curve25519.Signing.PrivateKey()
        let ltsk = signingKey.rawRepresentation
        let ltpk = signingKey.publicKey.rawRepresentation
        let clientId = Data(UUID().uuidString.utf8)

        let sessKey = hkdfSHA512(inputKeyMaterial: K,
                                 salt: Data("Pair-Setup-Encrypt-Salt".utf8),
                                 info: Data("Pair-Setup-Encrypt-Info".utf8),
                                 outputByteCount: 32)
        let iosX = hkdfSHA512(inputKeyMaterial: K,
                              salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
                              info: Data("Pair-Setup-Controller-Sign-Info".utf8),
                              outputByteCount: 32)
        guard let sig = try? signingKey.signature(for: iosX + clientId + ltpk) else {
            log("PairSetup M5: signing failed"); return
        }
        let inner = TLV8.encode([
            (TLVTag.identifier, clientId),
            (TLVTag.publicKey,  ltpk),
            (TLVTag.signature,  sig)
        ])
        let symKey = SymmetricKey(data: sessKey)
        guard let sealed = try? ChaChaPoly.seal(inner, using: symKey,
                                                nonce: pairingNonce("PS-Msg05"),
                                                authenticating: Data()) else {
            log("PairSetup M5: encrypt failed"); return
        }
        let tlv = TLV8.encode([
            (TLVTag.seqNo,         Data([0x05])),
            (TLVTag.encryptedData, sealed.ciphertext + sealed.tag)
        ])
        companionState = .psStep3
        pendingCredentials = CompanionCredentials(ltsk: ltsk, ltpk: ltpk,
                                                  atvLtpk: Data(), clientId: clientId, atvId: Data())
        sendFrame(type: .psNext, payload: OPACK.encode(["_pd": tlv, "_pwTy": 1] as [String: Any]))
    }

    private func handlePairSetupM6(tlv: [UInt8: Data]) {
        guard let K         = srpSessionKey,
              var pending   = pendingCredentials,
              let encrypted = tlv[TLVTag.encryptedData] else {
            log("PairSetup M6: missing data"); return
        }
        let sessKey = hkdfSHA512(inputKeyMaterial: K,
                                 salt: Data("Pair-Setup-Encrypt-Salt".utf8),
                                 info: Data("Pair-Setup-Encrypt-Info".utf8),
                                 outputByteCount: 32)
        let symKey = SymmetricKey(data: sessKey)
        let ct = encrypted.dropLast(16); let tag = encrypted.suffix(16)
        guard let box   = try? ChaChaPoly.SealedBox(nonce: pairingNonce("PS-Msg06"), ciphertext: ct, tag: tag),
              let inner = try? ChaChaPoly.open(box, using: symKey, authenticating: Data()) else {
            log("PairSetup M6: decrypt failed"); return
        }
        let innerTLV = TLV8.decode(inner)
        pending.atvLtpk = innerTLV[TLVTag.publicKey]  ?? Data()
        pending.atvId   = innerTLV[TLVTag.identifier] ?? Data()
        log("PairSetup M6: ATV LTPK \(pending.atvLtpk.count)B")

        guard let dev = activeDevice else { return }
        credentials[dev.id] = pending
        saveCredentials()
        pendingCredentials = nil
        isPairing = false
        log("PairSetup complete -- starting PairVerify")
        startPairVerify(creds: pending)
    }

    // MARK: - HID Commands (Companion E_OPACK)

    func send(gesture: Gesture) {
        guard gesture != .none else { return }
        guard let cmd = hidCommand(for: gesture) else { return }

        guard isConnected else {
            enqueueHIDCommand(cmd, source: "gesture:\(gesture.displayName)")
            scheduleReconnect(reason: "Send requested while disconnected")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastCommandDate) >= commandCooldown else { return }
        lastCommandDate = now
        sendHID(command: cmd)
    }

    /// Finger typing: skips the gesture cooldown, but paces presses so tvOS registers each
    /// down+up pair. Dropped while disconnected (stale arrows would mistype).
    func sendPointer(gesture: Gesture) {
        guard isConnected, let cmd = hidCommand(for: gesture) else { return }
        // Never drop a Select: that would lose a typed character.
        guard pointerQueue.count < maxPointerQueue || gesture == .select else { return }
        pointerQueue.append(cmd)
        drainPointerQueue()
    }

    private func drainPointerQueue() {
        guard !isDrainingPointerQueue, !pointerQueue.isEmpty else { return }
        let wait = pointerPressInterval - Date().timeIntervalSince(lastPointerSendDate)
        if wait > 0 {
            isDrainingPointerQueue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.isDrainingPointerQueue = false
                self?.drainPointerQueue()
            }
            return
        }
        guard isConnected else { pointerQueue.removeAll(); return }
        let now = Date()
        lastPointerSendDate = now
        lastCommandDate = now
        sendHID(command: pointerQueue.removeFirst(), releaseAfter: 0.04)
        drainPointerQueue()
    }

    // MARK: - Keyboard (text input) events

    /// Same sequence pyatv uses: start a remote session, subscribe to text-input events,
    /// then start text input. The TV then reports _tiStarted/_tiStopped as fields gain/lose focus.
    private func startKeyboardEvents() {
        keyboardClearWork?.cancel()
        sendSystemInfo()
        sendCompanionMessage("_sessionStart", type: 2, content: [
            "_srvT": "com.apple.tvremoteservices",
            "_sid": Int(UInt32.random(in: 1...0x7FFF_FFFF)),
        ])
        sendCompanionMessage("_interest", type: 1, content: ["_regEvents": ["_tiStarted", "_tiStopped"]])
        textInputStartXid = sendCompanionMessage("_tiStart", type: 2, content: [:])
    }

    /// Identifies this app to the TV, as pyatv does right after pairing. Without it the TV closed
    /// every session after ~36 s.
    private func sendSystemInfo() {
        let defaults = UserDefaults.standard
        let idsKey = "companion.idsID.v1", pubKey = "companion.pubID.v1"
        let idsID = defaults.string(forKey: idsKey) ?? UUID().uuidString
        let pubID = defaults.string(forKey: pubKey) ?? (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined(separator: ":")
        defaults.set(idsID, forKey: idsKey)
        defaults.set(pubID, forKey: pubKey)

        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }

        sendCompanionMessage("_systemInfo", type: 2, content: [
            "_bf": 0,
            "_cf": 512,
            "_clFl": 128,
            "_i": String(idsID.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased(),
            "_idsID": idsID,
            "_pubID": pubID,
            "_sf": 256,
            "_sv": "170.18",
            "model": model,
            "name": "GestureRemote",
        ])
    }

    /// type: 1 = event, 2 = request. Returns the transaction id.
    @discardableResult
    private func sendCompanionMessage(_ identifier: String, type: Int, content: [String: Any]) -> Int {
        let xid = cmdXid; cmdXid += 1
        sendEOPACK(["_i": identifier, "_x": xid, "_t": type, "_c": content])
        return xid
    }

    private func handleCompanionMessage(_ message: [String: Any]) {
        let identifier = message["_i"] as? String
        let content = message["_c"] as? [String: Any]
        switch identifier {
        case "_tiStarted":
            setKeyboardActive(true)
        case "_tiStopped":
            setKeyboardActive(false)
        case nil:
            // Response to _tiStart carries _tiD when a text field is already focused.
            if let xid = message["_x"] as? Int, xid == textInputStartXid {
                textInputStartXid = nil
                setKeyboardActive(content?["_tiD"] != nil)
            } else if let error = message["_em"] ?? message["_ec"] {
                log("<- error response x=\(message["_x"] ?? "?"): \(error)")
            }
        default:
            // Anything else the TV sends; logged to find out why it drops the connection.
            log("<- \(identifier ?? "?") t=\(message["_t"] ?? "?") keys=\((content ?? [:]).keys.sorted())")
        }
    }

    private func setKeyboardActive(_ active: Bool) {
        guard isKeyboardActive != active else { return }
        isKeyboardActive = active
        log("TV keyboard \(active ? "shown" : "hidden")")
    }

    private func enqueueHIDCommand(_ command: Int, source: String) {
        if queuedHIDCommands.count >= maxQueuedHIDCommands {
            queuedHIDCommands.removeFirst()
            log("Offline queue full -- dropped oldest command")
        }
        queuedHIDCommands.append(command)
        log("Queued command while disconnected [\(source)] (pending: \(queuedHIDCommands.count))")
    }

    private func flushQueuedCommandsIfNeeded() {
        guard isConnected else { return }
        guard !queuedHIDCommands.isEmpty else { return }
        guard !isFlushingQueuedCommands else { return }

        isFlushingQueuedCommands = true
        log("Reconnected -- replaying \(queuedHIDCommands.count) queued command(s)")

        func sendNext() {
            guard isConnected else {
                isFlushingQueuedCommands = false
                return
            }
            guard !queuedHIDCommands.isEmpty else {
                isFlushingQueuedCommands = false
                return
            }

            let command = queuedHIDCommands.removeFirst()
            sendHID(command: command)
            DispatchQueue.main.asyncAfter(deadline: .now() + queuedCommandReplayInterval) {
                sendNext()
            }
        }

        sendNext()
    }

    /// Press and release. Pointer steps use a shorter press so they can repeat faster.
    private func sendHID(command: Int, releaseAfter: TimeInterval = 0.08) {
        let xid1 = cmdXid; cmdXid += 1
        let xid2 = cmdXid; cmdXid += 1
        sendEOPACK(["_i": "_hidC", "_x": xid1, "_t": 2,
                    "_c": ["_hBtS": 1, "_hidC": command] as [String: Any]])
        let capturedXid2 = xid2
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseAfter) { [weak self] in
            self?.sendEOPACK(["_i": "_hidC", "_x": capturedXid2, "_t": 2,
                              "_c": ["_hBtS": 2, "_hidC": command] as [String: Any]])
        }
    }

    private func hidCommand(for gesture: Gesture) -> Int? {
        switch gesture {
        case .swipeUp:    return 1
        case .swipeDown:  return 2
        case .swipeLeft:  return 3
        case .swipeRight: return 4
        case .menu:       return 7
        case .back:       return 5
        case .select:     return 6
        case .playPause:  return 14
        case .volumeUp:   return 8     // Siri Remote volume buttons (HDMI-CEC / IR to the TV)
        case .volumeDown: return 9
        case .none:       return nil
        }
    }

    // MARK: - Credentials persistence

    private func saveCredentials() {
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: "companion.credentials.v2")
        }
    }

    private func savePreferredDeviceID(_ deviceID: String) {
        preferredDeviceID = deviceID
        UserDefaults.standard.set(deviceID, forKey: preferredDeviceDefaultsKey)
    }

    private func loadCredentials() {
        if let data = UserDefaults.standard.data(forKey: "companion.credentials.v2"),
           let creds = try? JSONDecoder().decode([String: CompanionCredentials].self, from: data) {
            credentials = creds
            log("Loaded credentials for \(creds.count) device(s)")
        }
    }

    private func loadPreferredDeviceID() {
        preferredDeviceID = UserDefaults.standard.string(forKey: preferredDeviceDefaultsKey)
        if let preferredDeviceID {
            log("Preferred Apple TV: \(preferredDeviceID)")
        }
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.log(msg) }
            return
        }
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[Companion] \(msg)")
        debugLog.append("[\(ts)] \(msg)")
        if debugLog.count > 60 { debugLog.removeFirst() }
    }
}

// MARK: - NetServiceBrowserDelegate

extension AppleTVRemote: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        log("Found service: \(service.name)")
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 10)
        resolvingServices.append(service)

        let ep = NWEndpoint.service(name: service.name, type: service.type,
                                    domain: service.domain, interface: nil)
        let dev = AppleTVDevice(id: service.name, name: service.name, endpoint: ep)
        registerDiscoveredDevice(dev, source: "netservice:\(service.type)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        unregisterDiscoveredDevice(id: service.name, source: "netservice:\(service.type)")
        resolvingServices.removeAll { $0.name == service.name }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log("Browser didNotSearch: \(errorDict)")
    }
}

// MARK: - NetServiceDelegate

extension AppleTVRemote: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        if sender.type.contains("_raop") {
            var resolvedIP: String?
            if let addresses = sender.addresses {
                for addressData in addresses {
                    addressData.withUnsafeBytes { ptr in
                        guard let base = ptr.baseAddress else { return }
                        let sa = base.assumingMemoryBound(to: sockaddr.self)
                        if sa.pointee.sa_family == UInt8(AF_INET) {
                            let sin = base.assumingMemoryBound(to: sockaddr_in.self)
                            var addr = sin.pointee.sin_addr
                            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                                resolvedIP = String(cString: buf)
                            }
                        }
                    }
                    if resolvedIP != nil { break }
                }
            }

            guard let ip = resolvedIP else {
                log("Resolved _raop \(sender.name) but no IPv4 address")
                resolvingServices.removeAll { $0.name == sender.name && $0.type == sender.type }
                raopResolveNamesByService.removeValue(forKey: sender.name)
                return
            }

            let friendlyName = raopResolveNamesByService.removeValue(forKey: sender.name) ?? sender.name
            probeFirstCompanionPort(host: ip, ports: [49152, 49153]) { [weak self] matchedPort in
                guard let self else { return }
                if let matchedPort, let port = NWEndpoint.Port(rawValue: UInt16(matchedPort)) {
                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: port)
                    self.log("Resolved via _raop service: \(friendlyName) → \(ip):\(matchedPort)")
                    let dev = AppleTVDevice(id: friendlyName, name: friendlyName, endpoint: endpoint)
                    self.registerDiscoveredDevice(dev, source: "raop-resolve")
                } else {
                    self.log("_raop host \(ip) did not expose Companion on 49152/49153")
                }
                self.resolvingServices.removeAll { $0.name == sender.name && $0.type == sender.type }
            }
            return
        }

        guard sender.port > 0, let addresses = sender.addresses, !addresses.isEmpty else {
            log("Resolved \(sender.name) but no address"); return
        }

        var resolvedIP: String?
        for addressData in addresses {
            addressData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                if sa.pointee.sa_family == UInt8(AF_INET) {
                    let sin = base.assumingMemoryBound(to: sockaddr_in.self)
                    var addr = sin.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        resolvedIP = String(cString: buf)
                    }
                }
            }
            if resolvedIP != nil { break }
        }

        let host = resolvedIP ?? sender.hostName ?? (sender.name + ".local.")

        // Companion-link TXT can be incomplete on some networks. Reject only when rpMd
        // is explicitly present and clearly not an Apple TV model.
        if sender.type.contains("_companion-link") {
            var rpMd = ""
            if let txtData = sender.txtRecordData() {
                let txt = NetService.dictionary(fromTXTRecord: txtData)
                rpMd = txt["rpMd"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            log("Resolve \(sender.name) [companion-link] port=\(sender.port) rpMd='\(rpMd)'")
            if !rpMd.isEmpty && !rpMd.lowercased().contains("appletv") {
                blacklistNonAppleCompanionID(sender.name,
                                             reason: "non-Apple-TV companion-link rpMd='\(rpMd)'")
                resolvingServices.removeAll { $0.name == sender.name }
                return
            }
        }

        if sender.type.contains("_mediaremotetv") || sender.type.contains("_airplay") || sender.type.contains("_appletv-v2") {
            // Non-Companion services (AirPlay/MediaRemoteTV/Appletv-v2) often advertise
            // ports like 7000 that are not Companion, so probe only known Companion fallbacks.
            let candidatePorts = [49153, 49152]
            probeFirstCompanionPort(host: host, ports: candidatePorts) { [weak self] matchedPort in
                guard let self else { return }
                defer { self.resolvingServices.removeAll { $0.name == sender.name } }

                guard let matchedPort,
                      let portVal = NWEndpoint.Port(rawValue: UInt16(matchedPort)) else {
                    self.log("Resolved \(sender.name) -> \(host) but no Companion endpoint found (tried \(candidatePorts.sorted()))")
                    return
                }

                // Do NOT overwrite an endpoint already set by _companion-link resolution.
                // _companion-link gives the real Companion port (e.g. 55047); probing
                // fixed ports 49152/49153 can match a different Apple TV service that
                // accepts TCP but isn't Companion, causing an infinite wrong-port loop.
                if self.resolvedEndpoints[sender.name] != nil {
                    self.log("Resolved \(sender.name) [\(sender.type)] -> \(host):\(matchedPort) (kept _companion-link endpoint)")
                    self.resolvingServices.removeAll { $0.name == sender.name }
                    return
                }

                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portVal)
                self.resolvedEndpoints[sender.name] = endpoint
                self.log("Resolved \(sender.name) -> \(host):\(matchedPort) [Companion verified]")

                let dev = AppleTVDevice(id: sender.name, name: sender.name, endpoint: endpoint)
                self.registerDiscoveredDevice(dev, source: "netservice:\(sender.type)")

                if let pending = self.pendingConnectDevice, pending.id == sender.name {
                    self.connectTimeoutWork?.cancel()
                    self.pendingConnectDevice = nil
                    self.pendingResolveService = nil
                    self.pendingAlternateResolutionID = nil
                    self.startTCPConnection(to: dev, endpoint: endpoint)
                }
            }
            return
        }

        let resolvedPort = UInt16(sender.port)

        guard let portVal = NWEndpoint.Port(rawValue: resolvedPort) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: portVal)
        resolvedEndpoints[sender.name] = endpoint
        log("Resolved \(sender.name) -> \(host):\(resolvedPort)")

        let dev = AppleTVDevice(id: sender.name, name: sender.name, endpoint: endpoint)
        registerDiscoveredDevice(dev)
        resolvingServices.removeAll { $0.name == sender.name }

        if let pending = pendingConnectDevice, pending.id == sender.name {
            connectTimeoutWork?.cancel()
            pendingConnectDevice = nil
            pendingResolveService = nil
            startTCPConnection(to: dev, endpoint: endpoint)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        log("didNotResolve \(sender.name): \(errorDict["NSNetServicesErrorCode"] ?? -1)")
        resolvingServices.removeAll { $0.name == sender.name }
        if sender.type.contains("_raop") {
            raopResolveNamesByService.removeValue(forKey: sender.name)
            return
        }
        if let pending = pendingConnectDevice, pending.id == sender.name {
            connectTimeoutWork?.cancel()
            pendingResolveService = nil
            if let fallback = resolvedEndpoints[pending.id] {
                guard case .hostPort(let host, let port) = fallback else {
                    resolvedEndpoints.removeValue(forKey: pending.id)
                    log("Resolution failed -- fallback endpoint invalid for \(pending.name)")
                    pendingConnectDevice = nil
                    pendingAlternateResolutionID = nil
                    isConnecting = false
                    scheduleReconnect(reason: "mDNS resolution failed")
                    return
                }

                let hostString: String
                switch host {
                case .name(let n, _): hostString = n
                case .ipv4(let addr): hostString = "\(addr)"
                case .ipv6(let addr): hostString = "\(addr)"
                @unknown default:
                    resolvedEndpoints.removeValue(forKey: pending.id)
                    log("Resolution failed -- fallback host type unsupported for \(pending.name)")
                    pendingConnectDevice = nil
                    pendingAlternateResolutionID = nil
                    isConnecting = false
                    scheduleReconnect(reason: "mDNS resolution failed")
                    return
                }

                let fallbackPort = Int(port.rawValue)
                log("[PortFlow] validating fallback endpoint for \(pending.name): \(hostString):\(fallbackPort)")
                probeCompanionEndpoint(host: hostString, port: fallbackPort) { [weak self] ok in
                    guard let self else { return }
                    if ok {
                        self.pendingConnectDevice = nil
                        self.pendingAlternateResolutionID = nil
                        self.log("Resolution failed -- using validated fallback endpoint \(hostString):\(fallbackPort) for \(pending.name)")
                        self.startTCPConnection(to: pending, endpoint: fallback)
                    } else {
                        self.resolvedEndpoints.removeValue(forKey: pending.id)
                        self.log("Resolution failed -- stale fallback endpoint \(hostString):\(fallbackPort), re-resolving")
                        if self.pendingAlternateResolutionID == pending.id {
                            self.pendingConnectDevice = nil
                            self.pendingAlternateResolutionID = nil
                            self.isConnecting = false
                            self.scheduleReconnect(reason: "mDNS resolution failed")
                        } else {
                            self.resolveAndConnectViaAlternateServices(device: pending)
                        }
                    }
                }
                return
            }
            if pendingAlternateResolutionID != pending.id {
                resolveAndConnectViaAlternateServices(device: pending)
            }
        }
    }
}

// MARK: - StreamDelegate (TCP I/O)

extension AppleTVRemote {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {

        case .openCompleted where aStream === outputStream:
            connectTimeoutWork?.cancel()
            streamOpenedSuccessfully = true
            log("TCP connected -- waiting for SessionStartRequest")
            isConnecting = false
            if let activeDevice {
                cacheDeviceIfHostPort(activeDevice)
            }
            // The TV sends SessionStartRequest (type 16) first.
            // We must reply with type 17 BEFORE starting pairing.
            // Fallback: if TV doesn't send it within 1.5s, start directly.
            // Capture epoch so a stale timer from a previous port attempt cannot
            // trigger beginPairing() on a different connection.
            let epochAtOpen = connectionEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self,
                      self.connectionEpoch == epochAtOpen,
                      self.companionState == .idle,
                      self.activeDevice != nil else { return }
                self.log("No SessionStartRequest received -- starting pairing directly")
                self.beginPairing()
            }

        case .openCompleted where aStream === inputStream:
            break

        case .hasBytesAvailable where aStream === inputStream:
            guard let inp = inputStream else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = inp.read(&buf, maxLength: buf.count)
            if n > 0 { readBuffer.append(contentsOf: buf[0..<n]); processReadBuffer() }

        case .errorOccurred:
            let err = aStream.streamError?.localizedDescription ?? "unknown"
            let failingDevice = activeDevice
            let failingEndpoint = activeDevice?.endpoint
            let wasConnectPhase = !streamOpenedSuccessfully
            performDisconnect(manual: false)
            if wasConnectPhase, let dev = failingDevice {
                removeCachedDevice(id: dev.id, reason: "Stream error during connect phase: \(err)")
            }
            if let dev = failingDevice, let ep = failingEndpoint,
               tryAlternateCompanionPort(for: dev, from: ep, reason: "Stream error: \(err)") {
                return
            }
            // If the stream never opened (connect-phase failure: refused/timeout),
            // the stored port may be stale.  Switch to a Bonjour service endpoint so
            // scheduleReconnect re-resolves _companion-link._tcp for the live port.
            if wasConnectPhase, let dev = failingDevice ?? desiredDevice {
                resolvedEndpoints.removeValue(forKey: dev.id)
                let serviceEp = NWEndpoint.service(name: dev.id, type: "_companion-link._tcp",
                                                   domain: "local.", interface: nil)
                desiredDevice = AppleTVDevice(id: dev.id, name: dev.name, endpoint: serviceEp)
                log("Connect-phase failure — will re-resolve \(dev.name) via Bonjour on next attempt")
            }
            scheduleReconnect(reason: "Stream error: \(err)")

        case .endEncountered:
            if companionState == .ready {
                log(String(format: "TV closed the session after %.1f s", Date().timeIntervalSince(sessionEstablishedAt)))
            }
            let failingDevice = activeDevice
            let failingEndpoint = activeDevice?.endpoint
            let wasConnectPhase = !streamOpenedSuccessfully
            performDisconnect(manual: false)
            if wasConnectPhase, let dev = failingDevice {
                removeCachedDevice(id: dev.id, reason: "Connection closed during connect phase")
            }
            if let dev = failingDevice, let ep = failingEndpoint,
               tryAlternateCompanionPort(for: dev, from: ep, reason: "Connection closed by remote") {
                return
            }
            if wasConnectPhase, let dev = failingDevice ?? desiredDevice {
                resolvedEndpoints.removeValue(forKey: dev.id)
                let serviceEp = NWEndpoint.service(name: dev.id, type: "_companion-link._tcp",
                                                   domain: "local.", interface: nil)
                desiredDevice = AppleTVDevice(id: dev.id, name: dev.name, endpoint: serviceEp)
                log("Connect-phase close — will re-resolve \(dev.name) via Bonjour on next attempt")
            }
            scheduleReconnect(reason: "Connection closed by remote")

        default:
            break
        }
    }
}
