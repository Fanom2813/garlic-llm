// The APIs coding agents use: OpenAI (/v1/chat/completions, /v1/models) and Anthropic (/v1/messages,
// /v1/messages/count_tokens), on top of Backend (the console).
import Foundation

func hexID(_ prefix: String) -> String {
    prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
}

/// the prompt does not fit the console's context: a 400 the agent can recognise (and compact its history)
struct ContextOverflow: Error {
    let tokens: Int, limit: Int
}

func errorJSON(_ message: String, type: String = "server_error") -> JSON {
    .object([("error", .object([("message", .string(message)), ("type", .string(type))]))])
}

public final class API: @unchecked Sendable {
    public let backend: Backend

    public init(backend: Backend) { self.backend = backend }

    public func handle(_ req: Request, _ r: Responder) {
        let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")
        if req.method == "OPTIONS" {
            r.send(204, contentType: "text/plain", body: Data(), extra: [("Access-Control-Allow-Headers", "*"),
                                                                          ("Access-Control-Allow-Methods", "GET, POST, OPTIONS")])
            return
        }
        if req.method == "GET" {
            switch path {
            case "/v1/models", "/models":
                let names = Set([backend.currentModel()?.name ?? "ps4"] + (backend.snap.consoleModel.isEmpty ? [] : [backend.snap.consoleModel]))
                r.json(200, .object([("object", .string("list")), ("data", .array(names.sorted().map {
                    .object([("id", .string($0)), ("object", .string("model")), ("created", .int(0)), ("owned_by", .string("ps4"))])
                }))]))
            case "/health", "/":
                let s = backend.snap
                r.json(s.reachable ? 200 : 503, .object([
                    ("status", .string(s.reachable ? "ok" : "ps4 unreachable")), ("model", .string(s.consoleModel)),
                    ("ps4", .string(s.host.map { "\($0):\(s.port)" } ?? "")), ("found_by", .string(s.how)),
                ]))
            default:
                r.json(404, errorJSON("not found", type: "invalid_request_error"))
            }
            return
        }
        guard req.method == "POST" else { r.json(404, errorJSON("not found")); return }
        let body: JSON
        do { body = req.body.isEmpty ? .object([]) : try JSON.parse(req.body) } catch {
            r.json(400, errorJSON("invalid JSON: \(error)", type: "invalid_request_error"))
            return
        }
        guard let model = backend.currentModel() else {
            r.json(503, errorJSON("no tokenizer for the console's model (models folder empty?)"))
            return
        }
        do {
            switch path {
            case "/v1/chat/completions", "/chat/completions": try openAIChat(body, model, r)
            case "/v1/messages", "/messages": try anthropic(body, model, r)
            case "/v1/messages/count_tokens", "/messages/count_tokens":
                let (m, t) = anthropicToOpenAI(body)
                let n = model.encode(try model.render(messages: m, tools: t, think: false)).count
                r.json(200, .object([("input_tokens", .int(n))]))
            default: r.json(404, errorJSON("not found", type: "invalid_request_error"))
            }
        } catch let e as ContextOverflow {
            backend.log("prompt \(e.tokens) tokens does not fit the context (\(e.limit)): sent context_length_exceeded")
            if path.hasSuffix("/messages") {
                r.json(400, .object([("type", .string("error")), ("error", .object([
                    ("type", .string("invalid_request_error")),
                    ("message", .string("prompt is too long: \(e.tokens) tokens > \(e.limit) maximum")),
                ]))]))
            } else {
                r.json(400, .object([("error", .object([
                    ("message", .string("This model's maximum context length is \(e.limit) tokens. However, your messages resulted in \(e.tokens) tokens. Please reduce the length of the messages.")),
                    ("type", .string("invalid_request_error")), ("param", .string("messages")),
                    ("code", .string("context_length_exceeded")),
                ]))]))
            }
        } catch {
            if r.started { r.end() } else { r.json(400, errorJSON("chat template: \(error)", type: "invalid_request_error")) }
        }
    }

    // one generation, shared by both dialects: emit(kind, text) as it streams; returns the stats and the tool calls
    func run(_ messages: JSON, _ tools: JSON?, _ req: JSON, _ model: Model, _ r: Responder, start: () -> Void,
             emit: (String, String) -> Void) throws -> (GenStats, [ToolCall]) {
        var think = req["enable_thinking"]?.bool ?? backend.defaultThink
        if let t = req["thinking"], case .object = t { think = t["type"]?.string == "enabled" }
        let text = try model.render(messages: messages, tools: tools, think: think)
        let n = backend.countPrompt(model, text), limit = backend.contextLimit
        if n + 2 + 128 > limit { throw ContextOverflow(tokens: n, limit: limit) }   // (no room for a reply)
        start()   // (the stream's head only once the prompt is known to fit)
        var maxNew = Int(req["max_tokens"]?.number ?? req["max_completion_tokens"]?.number ?? Double(backend.defaultMaxTokens))
        maxNew = max(1, min(maxNew, backend.defaultMaxTokens))
        let temperature = req["temperature"]?.number ?? backend.defaultTemperature
        let seed = UInt32(truncatingIfNeeded: Int(req["seed"]?.number ?? Double(UInt32.random(in: 0 ... UInt32.max))))
        var stopStrs: [String] = []
        if let s = req["stop"]?.string ?? req["stop_sequences"]?.string { stopStrs = [s] }
        else { stopStrs = (req["stop"]?.array ?? req["stop_sequences"]?.array ?? []).compactMap { $0.string } }
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split: Splitter
        if tail.hasSuffix("<think>") { split = Splitter(thinking: true) }            // the template opened the reasoning
        else if tail.hasSuffix("</think>") { split = Splitter(thinking: false) }     // reasoning closed by the template
        else if !model.templateSource.contains("enable_thinking") { split = Splitter(thinking: nil) }
        else { split = Splitter(thinking: think) }
        var gen: [Int] = []
        var shown = ""
        var stopped = false
        let st = backend.generate(model: model, text: text, maxNew: maxNew, temperature: temperature, seed: seed,
                                  onTokens: { toks in
            gen.append(contentsOf: toks)
            var full = model.decode(gen.last.map { model.stopIds.contains($0) } ?? false ? Array(gen.dropLast()) : gen)
            if full.hasSuffix("\u{FFFD}") { return }   // half of a character: wait for the rest
            for s in stopStrs where !s.isEmpty {
                if let rg = full.range(of: s) { full = String(full[..<rg.lowerBound]); stopped = true }
            }
            let delta = full.hasPrefix(shown) ? String(full.dropFirst(shown.count)) : ""
            shown = full
            let (rr, cc) = split.feed(delta)
            if !rr.isEmpty { emit("reasoning", rr) }
            if !cc.isEmpty { emit("content", cc) }
        }, cancelled: { stopped || r.isClosed })
        let (rr, cc) = split.feed("", final: true)
        if !rr.isEmpty { emit("reasoning", rr) }
        if !cc.isEmpty { emit("content", cc) }
        let calls = split.toolText.isEmpty ? [] : parseToolCalls(split.toolText, tools: tools)
        var s2 = st
        if stopped { s2.finish = "stop" }
        backend.recordRequest(s2, calls: calls.count)
        for c in calls { backend.log("  tool call \(c.name) \(String(c.arguments.dumps().prefix(160)))") }
        if !split.toolText.isEmpty && calls.isEmpty { backend.log("  could not parse the tool call: \(split.toolText.prefix(200))") }
        return (s2, calls)
    }

    func openAIChat(_ req: JSON, _ model: Model, _ r: Responder) throws {
        let messages = openAIMessages(req["messages"])
        let tools: JSON? = (req["tools"]?.array?.isEmpty ?? true) ? nil : req["tools"]
        let stream = req["stream"]?.bool ?? false
        let cid = hexID("chatcmpl-"), created = Int(Date().timeIntervalSince1970)
        var reasoning = "", content = ""
        func chunk(_ delta: JSON, _ finish: String? = nil, _ usage: JSON? = nil) -> JSON {
            var o: [(String, JSON)] = [("id", .string(cid)), ("object", .string("chat.completion.chunk")), ("created", .int(created)),
                                       ("model", .string(model.name)),
                                       ("choices", .array([.object([("index", .int(0)), ("delta", delta),
                                                                    ("finish_reason", finish.map { .string($0) } ?? .null)])]))]
            if let usage { o.append(("usage", usage)) }
            return .object(o)
        }
        let (st, calls) = try run(messages, tools, req, model, r, start: {
            if stream {
                r.sseStart()
                r.sse(chunk(.object([("role", .string("assistant")), ("content", .string(""))])))
            }
        }) { kind, text in
            if kind == "reasoning" { reasoning += text } else { content += text }
            if stream { r.sse(chunk(.object([(kind == "reasoning" ? "reasoning_content" : "content", .string(text))]))) }
        }
        if let e = st.error, content.isEmpty {
            if stream { r.sse(errorJSON(e)); r.end() } else { r.json(502, errorJSON(e)) }
            return
        }
        let toolCalls: [JSON] = calls.enumerated().map { i, c in
            .object([("id", .string(hexID("call_"))), ("type", .string("function")), ("index", .int(i)),
                     ("function", .object([("name", .string(c.name)), ("arguments", .string(c.arguments.dumps()))]))])
        }
        let finish = !toolCalls.isEmpty ? "tool_calls" : (st.finish == "length" ? "length" : "stop")
        let usage = JSON.object([("prompt_tokens", .int(st.prompt)), ("completion_tokens", .int(st.generated)),
                                 ("total_tokens", .int(st.prompt + st.generated)),
                                 ("prompt_tokens_details", .object([("cached_tokens", .int(st.cached))]))])
        if stream {
            if !toolCalls.isEmpty { r.sse(chunk(.object([("tool_calls", .array(toolCalls))]))) }
            r.sse(chunk(.object([]), finish, usage))
            r.sse("[DONE]")
            r.end()
            return
        }
        var msg: [(String, JSON)] = [("role", .string("assistant")),
                                     ("content", content.isEmpty && !toolCalls.isEmpty ? .null : .string(content))]
        if !reasoning.isEmpty { msg.append(("reasoning_content", .string(reasoning))) }
        if !toolCalls.isEmpty {
            msg.append(("tool_calls", .array(toolCalls.map { tc in
                .object((tc.object ?? []).filter { $0.0 != "index" })
            })))
        }
        r.json(200, .object([("id", .string(cid)), ("object", .string("chat.completion")), ("created", .int(created)),
                             ("model", .string(model.name)),
                             ("choices", .array([.object([("index", .int(0)), ("message", .object(msg)),
                                                          ("finish_reason", .string(finish))])])), ("usage", usage)]))
    }

    func anthropic(_ req: JSON, _ model: Model, _ r: Responder) throws {
        let (messages, toolsArr) = anthropicToOpenAI(req)
        let tools: JSON? = (toolsArr.array?.isEmpty ?? true) ? nil : toolsArr
        let stream = req["stream"]?.bool ?? false
        let mid = hexID("msg_")
        let modelName = req["model"]?.string ?? model.name
        var blocks: [(String, String)] = []
        var idx = -1
        var kind: String?
        func openBlock(_ k: String) {
            idx += 1
            kind = k
            blocks.append((k, ""))
            if stream {
                let cb: JSON = k == "thinking" ? .object([("type", .string("thinking")), ("thinking", .string(""))])
                    : .object([("type", .string("text")), ("text", .string(""))])
                r.sse(.object([("type", .string("content_block_start")), ("index", .int(idx)), ("content_block", cb)]),
                      event: "content_block_start")
            }
        }
        func closeBlock() {
            if kind != nil && stream {
                r.sse(.object([("type", .string("content_block_stop")), ("index", .int(idx))]), event: "content_block_stop")
            }
            kind = nil
        }
        let (st, calls) = try run(messages, tools, req, model, r, start: {
            if stream {
                r.sseStart()
                r.sse(.object([("type", .string("message_start")), ("message", .object([
                    ("id", .string(mid)), ("type", .string("message")), ("role", .string("assistant")), ("model", .string(modelName)),
                    ("content", .array([])), ("stop_reason", .null), ("stop_sequence", .null),
                    ("usage", .object([("input_tokens", .int(0)), ("output_tokens", .int(0))])),
                ]))]), event: "message_start")
            }
        }) { k0, text in
            let k = k0 == "reasoning" ? "thinking" : "text"
            if kind != k { closeBlock(); openBlock(k) }
            blocks[blocks.count - 1].1 += text
            if stream {
                let d: JSON = k == "thinking" ? .object([("type", .string("thinking_delta")), ("thinking", .string(text))])
                    : .object([("type", .string("text_delta")), ("text", .string(text))])
                r.sse(.object([("type", .string("content_block_delta")), ("index", .int(idx)), ("delta", d)]),
                      event: "content_block_delta")
            }
        }
        if let e = st.error, blocks.isEmpty {
            let err = JSON.object([("type", .string("error")), ("error", .object([("type", .string("api_error")), ("message", .string(e))]))])
            if stream { r.sse(err, event: "error"); r.end() } else { r.json(502, err) }
            return
        }
        closeBlock()
        var uses: [JSON] = []
        for c in calls {
            let uid = hexID("toolu_")
            uses.append(.object([("type", .string("tool_use")), ("id", .string(uid)), ("name", .string(c.name)), ("input", c.arguments)]))
            if stream {
                idx += 1
                r.sse(.object([("type", .string("content_block_start")), ("index", .int(idx)), ("content_block", .object([
                    ("type", .string("tool_use")), ("id", .string(uid)), ("name", .string(c.name)), ("input", .object([])),
                ]))]), event: "content_block_start")
                r.sse(.object([("type", .string("content_block_delta")), ("index", .int(idx)), ("delta", .object([
                    ("type", .string("input_json_delta")), ("partial_json", .string(c.arguments.dumps())),
                ]))]), event: "content_block_delta")
                r.sse(.object([("type", .string("content_block_stop")), ("index", .int(idx))]), event: "content_block_stop")
            }
        }
        let stop = !uses.isEmpty ? "tool_use" : (st.finish == "length" ? "max_tokens" : "end_turn")
        let usage = JSON.object([("input_tokens", .int(st.prompt - st.cached)), ("cache_read_input_tokens", .int(st.cached)),
                                 ("output_tokens", .int(st.generated))])
        if stream {
            r.sse(.object([("type", .string("message_delta")), ("delta", .object([("stop_reason", .string(stop)), ("stop_sequence", .null)])),
                           ("usage", usage)]), event: "message_delta")
            r.sse(.object([("type", .string("message_stop"))]), event: "message_stop")
            r.end()
            return
        }
        var content: [JSON] = blocks.filter { !$0.1.isEmpty }.map { k, t in
            k == "thinking" ? .object([("type", .string("thinking")), ("thinking", .string(t)), ("signature", .string(""))])
                : .object([("type", .string("text")), ("text", .string(t))])
        }
        content += uses
        r.json(200, .object([("id", .string(mid)), ("type", .string("message")), ("role", .string("assistant")),
                             ("model", .string(modelName)), ("content", .array(content)), ("stop_reason", .string(stop)),
                             ("stop_sequence", .null), ("usage", usage)]))
    }
}
