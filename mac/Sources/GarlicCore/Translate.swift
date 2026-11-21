// OpenAI and Anthropic requests -> the messages and tools the chat template expects.
import Foundation

public func textOf(_ content: JSON?) -> String {
    guard let content else { return "" }
    switch content {
    case let .string(s): return s
    case .null: return ""
    case let .array(parts):
        var out = ""
        for p in parts {
            if case let .string(s) = p { out += s; continue }
            let t = p["type"]?.string ?? ""
            if ["text", "input_text", "output_text"].contains(t) { out += p["text"]?.string ?? "" }
            else if ["image_url", "image", "input_image"].contains(t) { out += "[image omitted: this model reads text only]" }
        }
        return out
    default: return content.dumps()
    }
}

/// OpenAI chat messages -> template form (tool-call arguments as objects, content as text)
public func openAIMessages(_ msgs: JSON?) -> JSON {
    var out: [JSON] = []
    for m in msgs?.array ?? [] {
        var role = m["role"]?.string ?? "user"
        if role == "developer" { role = "system" }
        var o: [(String, JSON)] = [("role", .string(role)), ("content", .string(textOf(m["content"])))]
        if let rc = m["reasoning_content"]?.string, !rc.isEmpty { o.append(("reasoning_content", .string(rc))) }
        if role == "assistant", let tcs = m["tool_calls"]?.array, !tcs.isEmpty {
            var calls: [JSON] = []
            for tc in tcs {
                let f = tc["function"] ?? .object([])
                var args = f["arguments"] ?? .object([])
                if case let .string(s) = args {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { args = .object([]) }
                    else if let j = try? JSON.parse(s) { args = j }
                    else { args = .object([("input", .string(s))]) }
                }
                calls.append(.object([("id", tc["id"] ?? .null), ("type", .string("function")),
                                      ("function", .object([("name", f["name"] ?? .null), ("arguments", args)]))]))
            }
            o.append(("tool_calls", .array(calls)))
        }
        if role == "tool", let id = m["tool_call_id"], !id.isNull { o.append(("tool_call_id", id)) }
        out.append(.object(o))
    }
    return .array(out)
}

/// Anthropic /v1/messages request -> (messages, tools) in OpenAI form
public func anthropicToOpenAI(_ req: JSON) -> (JSON, JSON) {
    var msgs: [JSON] = []
    if let sys = req["system"], !sys.isNull {
        let s = sys.string ?? textOf(sys)
        if !s.isEmpty { msgs.append(.object([("role", .string("system")), ("content", .string(s))])) }
    }
    for m in req["messages"]?.array ?? [] {
        let role = m["role"]?.string ?? "user"
        if let s = m["content"]?.string {
            msgs.append(.object([("role", .string(role)), ("content", .string(s))]))
            continue
        }
        var texts = "", calls: [JSON] = [], results: [JSON] = []
        for b in m["content"]?.array ?? [] {
            switch b["type"]?.string ?? "" {
            case "text": texts += b["text"]?.string ?? ""
            case "tool_use":
                calls.append(.object([("id", b["id"] ?? .null), ("type", .string("function")),
                                      ("function", .object([("name", b["name"] ?? .null),
                                                            ("arguments", b["input"] ?? .object([]))]))]))
            case "tool_result":
                let c = b["content"]
                results.append(.object([("role", .string("tool")), ("tool_call_id", b["tool_use_id"] ?? .null),
                                        ("content", .string(c?.string ?? textOf(c)))]))
            case "image": texts += "[image omitted: this model reads text only]"
            default: break
            }
        }
        if role == "assistant" {
            var o: [(String, JSON)] = [("role", .string("assistant")), ("content", .string(texts))]
            if !calls.isEmpty { o.append(("tool_calls", .array(calls))) }
            msgs.append(.object(o))
        } else {
            msgs.append(contentsOf: results)
            if !texts.isEmpty { msgs.append(.object([("role", .string("user")), ("content", .string(texts))])) }
        }
    }
    var tools: [JSON] = []
    for t in req["tools"]?.array ?? [] {
        guard let n = t["name"] else { continue }
        tools.append(.object([("type", .string("function")),
                              ("function", .object([("name", n), ("description", t["description"] ?? .string("")),
                                                    ("parameters", t["input_schema"] ?? .object([("type", .string("object"))]))]))]))
    }
    return (openAIMessages(.array(msgs)), .array(tools))
}
