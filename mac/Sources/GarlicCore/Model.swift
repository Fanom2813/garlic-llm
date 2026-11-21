// A model's text side: tokenizer (tokenizer.json) and chat template (Jinja), as the PS4 has none of it.
import Foundation
import Jinja
import OrderedCollections
import Tokenizers

public final class Model: @unchecked Sendable {
    public let name: String
    public let templateSource: String
    let template: Template
    let tokenizer: Tokenizer
    public let stopIds: [Int]
    let bosToken: String, eosToken: String

    public init(folder: URL, name: String) async throws {
        self.name = name
        let cfgData = try Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json"))
        let cfg = try JSON.parse(cfgData)
        let tplURL = folder.appendingPathComponent("chat_template.jinja")
        if let t = try? String(contentsOf: tplURL, encoding: .utf8) {
            templateSource = t
        } else if let t = cfg["chat_template"]?.string {
            templateSource = t
        } else {
            throw JSON.ParseError(description: "no chat template in \(folder.path)")
        }
        template = try Template(templateSource, with: .init(lstripBlocks: true, trimBlocks: true))
        tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        var stops: [Int] = []
        for t in ["<|im_end|>", "<|endoftext|>"] {
            if let id = tokenizer.convertTokenToId(t) { stops.append(id) }
        }
        stopIds = stops
        bosToken = cfg["bos_token"]?.string ?? ""
        eosToken = cfg["eos_token"]?.string ?? ""
    }

    public static func value(_ j: JSON) -> Value {
        switch j {
        case .null: return .null
        case let .bool(b): return .boolean(b)
        case let .int(i): return .int(i)
        case let .double(d): return .double(d)
        case let .string(s): return .string(s)
        case let .array(a): return .array(a.map(value))
        case let .object(kv):
            var d = OrderedDictionary<ObjectKey, Value>(minimumCapacity: kv.count)
            for (k, v) in kv { d[.string(k)] = value(v) }
            return .object(d)
        }
    }

    /// The prompt text: messages (template form) and tools (OpenAI form, or nil)
    public func render(messages: JSON, tools: JSON?, think: Bool) throws -> String {
        var ctx: [String: Value] = [
            "messages": Model.value(messages),
            "add_generation_prompt": .boolean(true),
            "enable_thinking": .boolean(think),
            "bos_token": .string(bosToken),
            "eos_token": .string(eosToken),
        ]
        if let t = tools, let a = t.array, !a.isEmpty { ctx["tools"] = Model.value(t) } else { ctx["tools"] = .null }
        return try template.render(ctx)
    }

    public func encode(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }

    public func decode(_ ids: [Int]) -> String { tokenizer.decode(tokens: ids, skipSpecialTokens: false) }
}
