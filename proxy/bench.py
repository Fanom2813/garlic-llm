#!/usr/bin/env python3
"""Benchmark the PS4 through the proxy, then show the console's own profiler lines.

  python bench.py                      (proxy at http://127.0.0.1:8000, PS4 FTP on port 2121 of the console the proxy found)

Runs: a short answer, a long generation, a long prompt (prompt-reading speed) and a follow-up that should hit the
prompt cache. Prints tok/s for each, then the "[maple]" profile / decode / prompt lines from /data/ps4ai_log.txt.
"""
import argparse
import json
import re
import time
import urllib.error
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--proxy", default="http://127.0.0.1:8000")
ap.add_argument("--ps4", default="", help="console address for its log (default: ask the proxy)")
ap.add_argument("--quick", action="store_true", help="only the short and long generation")
a = ap.parse_args()


def chat(messages, max_tokens, label):
    body = json.dumps({"model": "ps4", "messages": messages, "max_tokens": max_tokens, "temperature": 0,
                       "stream": False}).encode()
    t0 = time.time()
    req = urllib.request.Request(a.proxy + "/v1/chat/completions", data=body, headers={"Content-Type": "application/json"})
    d = json.loads(urllib.request.urlopen(req, timeout=1800).read())
    dt = time.time() - t0
    u = d["usage"]
    m = d["choices"][0]["message"]
    text = (m.get("reasoning_content") or "") + (m.get("content") or "")
    print(f"{label:22s} prompt {u['prompt_tokens']:5d} (cached {u['prompt_tokens_details']['cached_tokens']:5d})  "
          f"new {u['completion_tokens']:4d}  wall {dt:6.1f}s  -> {u['completion_tokens'] / dt:5.1f} tok/s overall")
    return m, text


print("model:", json.loads(urllib.request.urlopen(a.proxy + "/v1/models", timeout=10).read())["data"][0]["id"])
msgs = [{"role": "user", "content": "What is 17 * 23? Answer briefly."}]
chat(msgs, 64, "short answer")
chat([{"role": "user", "content": "Write a Python function that checks if a number is prime, with a short explanation."}],
     400, "long generation")
if not a.quick:
    code = "\n".join(f"def f{i}(x):\n    return x * {i} + {i * 7 % 13}\n" for i in range(120))
    long_msgs = [{"role": "system", "content": "You are a careful coding assistant."},
                 {"role": "user", "content": "Here is a module:\n```python\n" + code + "\n```\nWhich function returns the largest value for x = 3? Answer with the function name only."}]
    m, _ = chat(long_msgs, 64, "long prompt")
    follow = long_msgs + [{"role": "assistant", "content": m.get("content") or ""},
                          {"role": "user", "content": "And for x = -3?"}]
    chat(follow, 64, "follow-up (cache)")

print("\n--- console profiler (/data/ps4ai_log.txt) ---")
if not a.ps4:
    try:
        urllib.request.urlopen(a.proxy + "/health", timeout=10)
    except urllib.error.HTTPError:
        pass
    a.ps4 = json.loads(urllib.request.urlopen(a.proxy + "/health", timeout=10).read())["ps4"].split(":")[0]
log = urllib.request.urlopen(f"ftp://{a.ps4}:2121/data/ps4ai_log.txt", timeout=60).read().decode("utf-8", "replace")
for line in log.splitlines():
    if re.search(r"\[maple\] (profile|decode|prompt)|raw: \d+ tokens in", line):
        print(line[:260])
