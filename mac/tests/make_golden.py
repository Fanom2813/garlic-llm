"""Reference prompts and token ids from the Python proxy, for checking the native app (GarlicCheck)."""
import json, sys
ROOT = __import__("pathlib").Path(__file__).resolve().parents[2]   # the repository
sys.path.insert(0, str(ROOT / "proxy"))
import proxy

tools = [{"type": "function", "function": {"name": "write_file", "description": "Write a file",
          "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                         "required": ["path", "content"]}}},
         {"type": "function", "function": {"name": "bash", "description": "Run a shell command",
          "parameters": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer"}},
                         "required": ["command"]}}}]
convs = [
    [{"role": "user", "content": "What is 17 * 23? Answer briefly."}],
    [{"role": "system", "content": "You are a coding agent. Ünïcode ✓ 中文 emoji 🚀"},
     {"role": "user", "content": "Create calc.py"},
     {"role": "assistant", "content": "I'll write it.", "reasoning_content": "Plan: write file.",
      "tool_calls": [{"id": "c1", "type": "function", "function": {"name": "write_file",
                      "arguments": "{\"path\": \"calc.py\", \"content\": \"print(1)\\n\"}"}}]},
     {"role": "tool", "tool_call_id": "c1", "content": "wrote 9 bytes"},
     {"role": "user", "content": "Now run it   with  spaces\n\n\ttabs"}],
]
out = []
for name in ["qwen3.5-9b", "maple"]:
    m = proxy.Model(str(ROOT / "models" / "tokenizers" / name), name)
    for ci, c in enumerate(convs):
        for think in (False, True):
            for tl in (None, tools):
                msgs = proxy.openai_messages(c)
                text = m.render(msgs, tl, think)
                out.append({"model": name, "conv": ci, "think": think, "tools": tl is not None, "messages": msgs,
                            "tool_defs": tl, "text": text, "ids": m.encode(text)})
json.dump(out, open(ROOT / "mac" / "tests" / "golden.json", "w"), ensure_ascii=False)
print(len(out), "cases")
