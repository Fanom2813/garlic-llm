// JSON that keeps the order of object keys (chat templates print tool schemas with tojson, so the prompt depends on
// it), with a parser and a writer that matches Python's json.dumps(ensure_ascii=False).
import Foundation

public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSON? {
        if case let .object(kv) = self { return kv.first(where: { $0.0 == key })?.1 }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case let .array(a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var array: [JSON]? { if case let .array(a) = self { return a }; return nil }
    public var object: [(String, JSON)]? { if case let .object(o) = self { return o }; return nil }
    public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var number: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    /// JSON object with one key replaced or added (order kept; a new key goes last)
    public func setting(_ key: String, _ value: JSON) -> JSON {
        guard case var .object(kv) = self else { return self }
        if let i = kv.firstIndex(where: { $0.0 == key }) { kv[i].1 = value } else { kv.append((key, value)) }
        return .object(kv)
    }

    // ---- parsing ----
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ data: Data) throws -> JSON { try parse(String(decoding: data, as: UTF8.self)) }

    public static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        if p.i != p.b.count { throw ParseError(description: "extra data at \(p.i)") }
        return v
    }

    struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        func err(_ m: String) -> ParseError { ParseError(description: "\(m) at byte \(i)") }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512 else { throw err("too deep") }
            guard i < b.count else { throw err("unexpected end") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var kv: [(String, JSON)] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                while true {
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("expected key") }
                    let k = try str()
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("expected :") }
                    i += 1
                    skipWS()
                    let v = try value(depth: depth + 1)
                    if let j = kv.firstIndex(where: { $0.0 == k }) { kv[j].1 = v } else { kv.append((k, v)) }
                    skipWS()
                    guard i < b.count else { throw err("unexpected end") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                    throw err("expected , or }")
                }
            case UInt8(ascii: "["):
                i += 1
                var a: [JSON] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    skipWS()
                    a.append(try value(depth: depth + 1))
                    skipWS()
                    guard i < b.count else { throw err("unexpected end") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw err("expected , or ]")
                }
            case UInt8(ascii: "\""):
                return .string(try str())
            case UInt8(ascii: "t"):
                guard lit("true") else { throw err("bad literal") }
                return .bool(true)
            case UInt8(ascii: "f"):
                guard lit("false") else { throw err("bad literal") }
                return .bool(false)
            case UInt8(ascii: "n"):
                guard lit("null") else { throw err("bad literal") }
                return .null
            default:
                return try num()
            }
        }

        mutating func lit(_ s: String) -> Bool {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i ..< i + u.count]) == u else { return false }
            i += u.count
            return true
        }

        mutating func num() throws -> JSON {
            let s = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            var isInt = true
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { i += 1 } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") ||
                    c == UInt8(ascii: "E") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { isInt = false; i += 1 } else { break }
            }
            let t = String(decoding: b[s ..< i], as: UTF8.self)
            if t.isEmpty || t == "-" { throw err("bad value") }
            if isInt, let v = Int(t) { return .int(v) }
            guard let d = Double(t) else { throw err("bad number") }
            return .double(d)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw err("bad escape") }
            var v: UInt32 = 0
            for _ in 0 ..< 4 {
                let c = b[i]
                i += 1
                v <<= 4
                switch c {
                case 0x30 ... 0x39: v |= UInt32(c - 0x30)
                case 0x41 ... 0x46: v |= UInt32(c - 0x41 + 10)
                case 0x61 ... 0x66: v |= UInt32(c - 0x61 + 10)
                default: throw err("bad hex")
                }
            }
            return v
        }

        mutating func str() throws -> String {
            i += 1   // opening quote
            var out = [UInt8]()
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { break }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if cp >= 0xD800, cp < 0xDC00, i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let lo = try hex4()
                            if lo >= 0xDC00, lo < 0xE000 { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) }
                        }
                        let sc = Unicode.Scalar(cp) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(Character(sc)).utf8))
                    default: out.append(e)
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            throw err("unterminated string")
        }
    }

    // ---- writing (Python json.dumps, ensure_ascii=False; indent like Python's) ----
    public func dumps(indent: Int? = nil, ensureASCII: Bool = false) -> String {
        var s = ""
        write(&s, indent: indent, level: 0, ascii: ensureASCII)
        return s
    }

    public var data: Data { Data(dumps().utf8) }

    static func quote(_ str: String, ascii: Bool) -> String {
        var o = "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0C}": o += "\\f"
            default:
                if u.value < 0x20 || (ascii && u.value > 0x7E) {
                    if u.value > 0xFFFF {
                        let v = u.value - 0x10000
                        o += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                    } else {
                        o += String(format: "\\u%04x", u.value)
                    }
                } else {
                    o.unicodeScalars.append(u)
                }
            }
        }
        return o + "\""
    }

    static func pyFloat(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    func write(_ s: inout String, indent: Int?, level: Int, ascii: Bool) {
        switch self {
        case .null: s += "null"
        case let .bool(b): s += b ? "true" : "false"
        case let .int(i): s += String(i)
        case let .double(d): s += JSON.pyFloat(d)
        case let .string(t): s += JSON.quote(t, ascii: ascii)
        case let .array(a):
            if a.isEmpty { s += "[]"; return }
            s += "["
            for (k, v) in a.enumerated() {
                if let n = indent { s += "\n" + String(repeating: " ", count: n * (level + 1)) } else if k > 0 { s += " " }
                v.write(&s, indent: indent, level: level + 1, ascii: ascii)
                if k < a.count - 1 { s += "," }
            }
            if let n = indent { s += "\n" + String(repeating: " ", count: n * level) }
            s += "]"
        case let .object(kv):
            if kv.isEmpty { s += "{}"; return }
            s += "{"
            for (k, (key, v)) in kv.enumerated() {
                if let n = indent { s += "\n" + String(repeating: " ", count: n * (level + 1)) } else if k > 0 { s += " " }
                s += JSON.quote(key, ascii: ascii) + ": "
                v.write(&s, indent: indent, level: level + 1, ascii: ascii)
                if k < kv.count - 1 { s += "," }
            }
            if let n = indent { s += "\n" + String(repeating: " ", count: n * level) }
            s += "}"
        }
    }
}
