// The reply as it streams: reasoning (<think>...</think>), visible text, and tool-call blocks; then the calls themselves.
import Foundation

let toolOpen = "<tool_call>"

private func regex(_ p: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators])
}

private let blockRE = regex("<tool_call>(.*?)(?:</tool_call>|$)")
private let funcRE = regex("<function=([^>\\n]+)>(.*?)</function>")
private let paramRE = regex("<parameter=([^>\\n]+)>\\n?(.*?)\\n?</parameter>")
private let scalarRE = try! NSRegularExpression(pattern: "^(-?\\d+(\\.\\d+)?|true|false|null)$")

private func groups(_ re: NSRegularExpression, _ s: String) -> [[String]] {
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        (1 ..< m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// A parameter's text as the schema wants it: strings stay text, other types parse as JSON when they can.
func coerce(_ value: String, _ schema: JSON?) -> JSON {
    let t = schema?["type"]?.string
    let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if t == "string" { return .string(value) }
    if t == nil {
        let first = v.first
        let looksJSON = first == "{" || first == "[" || first == "\""
        let scalar = scalarRE.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
        if !looksJSON && !scalar { return .string(value) }
    }
    if let j = try? JSON.parse(value) { return j }
    return .string(value)
}

public struct ToolCall {
    public let name: String
    public let arguments: JSON
}

/// Tool calls in Qwen's XML form (<function=...><parameter=...>) or JSON form ({"name":..., "arguments":...}).
public func parseToolCalls(_ text: String, tools: JSON?) -> [ToolCall] {
    var schemas: [String: JSON] = [:]
    for t in tools?.array ?? [] {
        let f = t["function"] ?? t
        if let n = f["name"]?.string { schemas[n] = f["parameters"]?["properties"] ?? .object([]) }
    }
    var calls: [ToolCall] = []
    for g in groups(blockRE, text) {
        let block = g[0]
        if let f = groups(funcRE, block).first {
            let name = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let props = schemas[name]
            var args: [(String, JSON)] = []
            for p in groups(paramRE, f[1]) {
                let k = p[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let val = coerce(p[1], props?[k])
                if let i = args.firstIndex(where: { $0.0 == k }) { args[i].1 = val } else { args.append((k, val)) }
            }
            calls.append(ToolCall(name: name, arguments: .object(args)))
            continue
        }
        if let j = try? JSON.parse(block.trimmingCharacters(in: .whitespacesAndNewlines)), let n = j["name"]?.string {
            calls.append(ToolCall(name: n, arguments: j["arguments"] ?? j["parameters"] ?? .object([])))
        }
    }
    return calls
}

/// Splits the streamed text into reasoning (inside <think>...</think>), visible content, and tool-call text.
/// feed() returns (reasoning delta, content delta); the tool calls are parsed from toolText at the end.
public final class Splitter {
    enum State { case start, think, content, tool }
    var buf = ""
    var state: State
    public private(set) var toolText = ""

    /// thinking nil: the reply decides (a reasoning model opens with <think>)
    public init(thinking: Bool?) {
        switch thinking {
        case nil: state = .start
        case true?: state = .think
        case false?: state = .content
        }
    }

    static func hold(_ s: String, _ tag: String) -> Int {   // keep back a tail that may be the start of the tag
        let n = s.count
        var k = min(tag.count - 1, n)
        while k > 0 {
            if s.hasSuffix(String(tag.prefix(k))) { return n - k }
            k -= 1
        }
        return n
    }

    public func feed(_ text: String, final: Bool = false) -> (String, String) {
        buf += text
        var r = "", c = ""
        loop: while true {
            switch state {
            case .start:
                let head = String(buf.drop(while: { $0 == "\n" }))
                if head.hasPrefix("<think>") {
                    buf = String(head.dropFirst("<think>".count))
                    state = .think
                    continue
                }
                if final || head.count >= "<think>".count || !"<think>".hasPrefix(head) {
                    state = .content
                    continue
                }
                break loop
            case .think:
                if let range = buf.range(of: "</think>") {
                    r += buf[..<range.lowerBound].replacingOccurrences(of: "<think>", with: "")
                    buf = String(buf[range.upperBound...].drop(while: { $0 == "\n" }))
                    state = .content
                    continue
                }
                let cut = final ? buf.count : Splitter.hold(buf, "</think>")
                r += String(buf.prefix(cut)).replacingOccurrences(of: "<think>", with: "")
                buf = String(buf.dropFirst(cut))
                break loop
            case .content:
                if let range = buf.range(of: toolOpen) {
                    c += buf[..<range.lowerBound]
                    toolText += buf[range.lowerBound...]
                    buf = ""
                    state = .tool
                    break loop
                }
                let cut = final ? buf.count : Splitter.hold(buf, toolOpen)
                c += buf.prefix(cut)
                buf = String(buf.dropFirst(cut))
                break loop
            case .tool:   // everything after the first <tool_call> belongs to the calls
                toolText += buf
                buf = ""
                break loop
            }
        }
        return (r, c)
    }
}
