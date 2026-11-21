// Checks the native text side against the Python proxy's output (tests/golden.json): same prompt, same token ids.
import Foundation
import GarlicCore

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/golden.json")
let models = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "../models/tokenizers")
let golden = try JSON.parse(try Data(contentsOf: root))
var loaded: [String: Model] = [:]
var fails = 0
for c in golden.array ?? [] {
    let name = c["model"]!.string!
    if loaded[name] == nil { loaded[name] = try await Model(folder: models.appendingPathComponent(name), name: name) }
    let m = loaded[name]!
    let label = "\(name) conv \(c["conv"]!.number!) think \(c["think"]!.bool!) tools \(c["tools"]!.bool!)"
    do {
        let text = try m.render(messages: c["messages"]!, tools: c["tool_defs"]!.isNull ? nil : c["tool_defs"]!,
                                think: c["think"]!.bool!)
        let want = c["text"]!.string!
        let ids = m.encode(want)
        let wantIds = (c["ids"]!.array ?? []).map { Int($0.number!) }
        let round = m.decode(ids)
        var notes: [String] = []
        if text != want {
            let a = Array(text), b = Array(want)
            var k = 0
            while k < min(a.count, b.count), a[k] == b[k] { k += 1 }
            notes.append("TEXT differs at \(k): swift \(String(a[k ..< min(k + 60, a.count)]).debugDescription) vs python \(String(b[k ..< min(k + 60, b.count)]).debugDescription)")
        }
        if ids != wantIds {
            var k = 0
            while k < min(ids.count, wantIds.count), ids[k] == wantIds[k] { k += 1 }
            notes.append("IDS differ at \(k) of \(wantIds.count): swift \(Array(ids[k ..< min(k + 8, ids.count)])) vs python \(Array(wantIds[k ..< min(k + 8, wantIds.count)]))")
        }
        if round != want { notes.append("decode round trip differs") }
        if notes.isEmpty { print("ok   \(label): \(ids.count) tokens") } else {
            fails += 1
            print("FAIL \(label):\n  " + notes.joined(separator: "\n  "))
        }
    } catch {
        fails += 1
        print("FAIL \(label): \(error)")
    }
}
print(fails == 0 ? "ALL MATCH" : "\(fails) FAILED")
