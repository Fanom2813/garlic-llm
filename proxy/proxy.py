#!/usr/bin/env python3
"""ps4proxy: OpenAI- and Anthropic-compatible API on this Mac; inference on the PS4 (Garlic Server, POST /v1/raw).

The PS4 only turns token ids into token ids (with a prompt cache). Everything else happens here: the model's own chat
template (Jinja, from its tokenizer files), tokenizing, tool definitions, parsing <tool_call> blocks, streaming, and
both API dialects. Coding agents talk to this proxy:

  OpenAI:    base_url http://127.0.0.1:8000/v1      (POST /v1/chat/completions, GET /v1/models)
  Anthropic: base_url http://127.0.0.1:8000         (POST /v1/messages, POST /v1/messages/count_tokens)

Run:  python proxy.py                     (finds the console by itself: its UDP announcement, or a scan)
      python proxy.py --ps4 http://192.168.1.50:8080   (a fixed address)
Test without a PS4:  python proxy.py --selftest
"""
import argparse
import http.client
import json
import re
import socket
import subprocess
import struct
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
TOKENIZERS = HERE.parent / "models" / "tokenizers"   # tools/fetch_tokenizers.sh puts them there


# ---- model: tokenizer + chat template -------------------------------------------------------------------------------

class Model:
    def __init__(self, model_dir, name):
        d = Path(model_dir)
        self.name = name
        self.tok = Tokenizer.from_file(str(d / "tokenizer.json"))
        cfg = json.loads((d / "tokenizer_config.json").read_text())
        tpl = (d / "chat_template.jinja").read_text() if (d / "chat_template.jinja").exists() else cfg["chat_template"]
        env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=["jinja2.ext.loopcontrols"])
        env.filters["tojson"] = lambda x, indent=None, ensure_ascii=False: json.dumps(x, indent=indent,
                                                                                       ensure_ascii=ensure_ascii)
        env.globals["raise_exception"] = self._raise
        self.template = env.from_string(tpl)
        self.template_src = tpl
        vocab = self.tok.get_vocab(with_added_tokens=True)
        self.im_end = vocab.get("<|im_end|>")
        self.eos = vocab.get("<|endoftext|>")
        self.stop_ids = [i for i in (self.im_end, self.eos) if i is not None]
        self.bos_token = cfg.get("bos_token") if isinstance(cfg.get("bos_token"), str) else ""
        self.eos_token = cfg.get("eos_token") if isinstance(cfg.get("eos_token"), str) else ""

    @staticmethod
    def _raise(msg):
        raise jinja2.TemplateError(msg)

    def render(self, messages, tools=None, think=False):
        return self.template.render(messages=messages, tools=tools or None, add_generation_prompt=True,
                                    enable_thinking=think, bos_token=self.bos_token, eos_token=self.eos_token)

    def encode(self, text):
        return self.tok.encode(text, add_special_tokens=False).ids

    def decode(self, ids):
        return self.tok.decode(ids, skip_special_tokens=False)


# ---- PS4 backend ----------------------------------------------------------------------------------------------------

MODELS = {}


def current_model():
    """The model loaded on the console (GET /v1/models), with its tokenizer files from models/<name>; cached 3 s."""
    now = time.time()
    if CURRENT.get("t", 0) > now - 3 and CURRENT.get("m"):
        return CURRENT["m"]
    name = None
    try:
        c = http.client.HTTPConnection(PS4B.host, PS4B.port, timeout=5)
        c.request("GET", "/v1/models")
        name = json.loads(c.getresponse().read())["data"][0]["id"]
        c.close()
        LAST_OK["t"] = now
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", str(name)) or ".." in name:   # (a folder name, never a path)
            name = None
    except (OSError, ValueError, KeyError, IndexError, http.client.HTTPException):
        scan_for_ps4()
    m = CURRENT.get("m")
    if name and (not m or m.name != name):
        d = TOKENIZERS / name
        if not (d / "tokenizer.json").exists() and "-" in name:   # (maple-fast: the maple tokenizer)
            d = TOKENIZERS / name.rsplit("-", 1)[0]
        if (d / "tokenizer.json").exists():
            if name not in MODELS:
                MODELS[name] = Model(d, name)
            m = MODELS[name]
            sys.stderr.write(f"[ps4] model on the console: {name} (tokenizer {d})\n")
        elif not m:
            m = MODEL
            sys.stderr.write(f"[ps4] console reports model '{name}' but models/{name} is missing; using {m.name}\n")
    CURRENT.update(t=now, m=m or MODEL)
    return CURRENT["m"]


CURRENT = {}
PS4B = None


# ---- finding the console ------------------------------------------------------------------------------------------
# Its address changes (DHCP, no fixed IP). Garlic Server 1.21+ announces itself on UDP 8099 every 2 s
# ("GARLIC1 <port> <model>"); older servers are found by asking each address of this Mac's /24 networks for
# GET /v1/models on port 8080 (when the console stops answering, at most every 20 s).

BEACON_PORT = 8099
FOUND = {"beacon_t": 0.0, "scan_t": 0.0}


LAST_OK = {"t": 0.0}   # when the current console last answered
IGNORED = set()


def set_ps4(host, port, why):
    if PS4B and (PS4B.host, PS4B.port) != (host, port) and why.startswith("announcement") and time.time() - LAST_OK["t"] < 15:
        # announcements are not authenticated: keep a console that answers (anyone on the network could announce)
        if host not in IGNORED:
            IGNORED.add(host)
            sys.stderr.write(f"[ps4] ignoring an announcement from {host}:{port} while {PS4B.host} answers\n")
        return
    if PS4B and (PS4B.host, PS4B.port) != (host, port):
        sys.stderr.write(f"[ps4] console at {host}:{port} ({why})\n")
        PS4B.host, PS4B.port = host, port
        CURRENT.clear()


def beacon_listener():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    try:
        s.bind(("", BEACON_PORT))
    except OSError as e:
        sys.stderr.write(f"[ps4] cannot listen for announcements on UDP {BEACON_PORT}: {e}\n")
        return
    while True:
        try:
            data, (host, _) = s.recvfrom(256)
            f = data.decode("ascii", "replace").split()
            if len(f) >= 2 and f[0] == "GARLIC1" and f[1].isdigit():
                FOUND["beacon_t"] = time.time()
                set_ps4(host, int(f[1]), "announcement" + (f", model {f[2]}" if len(f) > 2 else ""))
        except OSError:
            time.sleep(1)


def local_subnets():
    nets = set()
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
        for a in re.findall(r"inet (\d+\.\d+\.\d+)\.\d+ netmask", out):
            if not a.startswith("127."):
                nets.add(a)
    except (OSError, subprocess.SubprocessError):
        pass
    return sorted(nets)


def probe(host, port=8080):
    try:
        c = http.client.HTTPConnection(host, port, timeout=1.5)
        c.request("GET", "/v1/models")
        r = c.getresponse()
        ok = r.status == 200 and b'"data"' in r.read(4096)
        c.close()
        return ok
    except (OSError, http.client.HTTPException):
        return False


def scan_for_ps4():
    """Background: try every address of this Mac's /24 networks (64 at a time)."""
    now = time.time()
    if now - FOUND["scan_t"] < 20 or now - FOUND["beacon_t"] < 10:
        return
    FOUND["scan_t"] = now

    def run():
        from concurrent.futures import ThreadPoolExecutor
        hosts = [f"{n}.{i}" for n in local_subnets() for i in range(1, 255)]
        with ThreadPoolExecutor(64) as ex:
            for h, ok in zip(hosts, ex.map(probe, hosts)):
                if ok:
                    set_ps4(h, 8080, "network scan")
                    return
        sys.stderr.write("[ps4] scan: no Garlic Server on " + ", ".join(n + ".x" for n in local_subnets()) + "\n")

    threading.Thread(target=run, daemon=True).start()


class PS4:
    """One request at a time (the console has one engine). Keeps the token-exact text of the last exchange so the next
    prompt can reuse its ids, which keeps the console's prompt cache hitting."""

    def __init__(self, url, model, timeout=1800):
        u = urlparse(url)
        self.host, self.port = u.hostname, u.port or 8080
        self.model = model
        self.timeout = timeout
        self.lock = threading.Lock()
        self.last_text, self.last_ids = None, None

    def prompt_ids(self, text):
        if getattr(self, "last_model", None) is not self.model:   # another model: nothing to reuse
            self.last_text = self.last_ids = None
            self.last_model = self.model
        if self.last_text and text.startswith(self.last_text):
            return self.last_ids + self.model.encode(text[len(self.last_text):])
        return self.model.encode(text)

    def generate(self, text, max_new, temperature, seed, on_tokens, cancelled=lambda: False):
        """Streams the reply: on_tokens(list_of_ids) per step. Returns a stats dict."""
        ids = self.prompt_ids(text)
        stops = self.model.stop_ids
        body = (b"GRW1" + struct.pack("<IIfIII", len(ids), max_new, float(temperature), seed & 0xFFFFFFFF, len(stops), 0)
                + struct.pack(f"<{len(stops)}I", *stops) + struct.pack(f"<{len(ids)}I", *ids))
        stats = dict(prompt=len(ids), cached=0, prefill_s=0.0, decode_s=0.0, generated=0, finish="error", error=None)
        gen = []
        conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        try:
            conn.request("POST", "/v1/raw", body=body, headers={"Content-Type": "application/octet-stream"})
            resp = conn.getresponse()
            if resp.status != 200:
                stats["error"] = f"PS4 HTTP {resp.status}: {resp.read()[:300]!r}"
                return stats
            while True:
                line = resp.readline()
                if not line:
                    break
                line = line.decode("utf-8", "replace").rstrip("\n")
                kind, _, rest = line.partition(" ")
                if kind == "c":
                    stats["cached"] = int(rest.split()[0])
                elif kind == "p":
                    stats["prefill_s"] = float(rest.split()[1])
                elif kind == "t":
                    toks = [int(x) for x in rest.split()]
                    gen.extend(toks)
                    on_tokens(toks)
                    if cancelled():
                        stats["finish"] = "cancel"
                        break
                elif kind == "d":
                    f, n, s = rest.split()
                    stats.update(finish=f, generated=int(n), decode_s=float(s))
                    break
                elif kind == "e":
                    stats["error"] = "PS4: " + rest
                    break
        except (OSError, http.client.HTTPException) as e:
            stats["error"] = f"cannot reach the PS4 at {self.host}:{self.port}: {e}"
            scan_for_ps4()
        finally:
            conn.close()
        # what the console has read: the prompt and every generated token except a final stop token
        read = gen[:-1] if gen and gen[-1] in stops else gen
        if stats["error"] is None and stats["finish"] in ("stop", "length"):
            self.last_ids = ids + read
            self.last_text = text + self.model.decode(read)
        else:
            self.last_text = self.last_ids = None
        return stats


# ---- output parsing: reasoning, content, tool calls -----------------------------------------------------------------

TOOL_OPEN, TOOL_CLOSE = "<tool_call>", "</tool_call>"
FUNC_RE = re.compile(r"<function=([^>\n]+)>(.*?)</function>", re.S)
PARAM_RE = re.compile(r"<parameter=([^>\n]+)>\n?(.*?)\n?</parameter>", re.S)


def _coerce(value, schema):
    t = (schema or {}).get("type")
    if t == "string" or (t is None and not value.strip()[:1] in ("{", "[", '"') and not re.fullmatch(
            r"-?\d+(\.\d+)?|true|false|null", value.strip())):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return value


def parse_tool_calls(text, tools):
    """Tool calls in Qwen3.5's XML form (<function=...><parameter=...>) or JSON form ({"name":..., "arguments":...})."""
    schemas = {}
    for t in tools or []:
        f = t.get("function", t)
        schemas[f.get("name")] = (f.get("parameters") or {}).get("properties", {})
    calls = []
    for block in re.findall(r"<tool_call>(.*?)(?:</tool_call>|$)", text, re.S):
        m = FUNC_RE.search(block)
        if m:
            name = m.group(1).strip()
            props = schemas.get(name, {})
            args = {k.strip(): _coerce(v, props.get(k.strip())) for k, v in PARAM_RE.findall(m.group(2))}
            calls.append((name, args))
            continue
        try:
            j = json.loads(block.strip())
            calls.append((j["name"], j.get("arguments", j.get("parameters", {}))))
        except (ValueError, KeyError, TypeError):
            pass
    return calls


class Splitter:
    """Splits the streamed text into reasoning (inside <think>...</think>), visible content, and tool-call blocks.
    feed() returns (reasoning_delta, content_delta); tool calls are taken at the end (finish())."""

    def __init__(self, thinking):
        self.buf = ""
        # thinking None: the reply decides (a reasoning model such as Maple opens with <think>)
        self.state = "start" if thinking is None else ("think" if thinking else "content")
        self.tool_text = ""
        self.sent_tools = False

    @staticmethod
    def _hold(s, tags):
        for tag in tags:   # keep back a tail that may be the start of a tag
            for k in range(min(len(tag) - 1, len(s)), 0, -1):
                if s.endswith(tag[:k]):
                    return len(s) - k
        return len(s)

    def feed(self, text, final=False):
        self.buf += text
        r, c = "", ""
        while True:
            if self.state == "start":
                head = self.buf.lstrip("\n")
                if head.startswith("<think>"):
                    self.buf = head[len("<think>"):]
                    self.state = "think"
                    continue
                if final or len(head) >= len("<think>") or not "<think>".startswith(head):
                    self.state = "content"
                    continue
                break
            if self.state == "think":
                i = self.buf.find("</think>")
                if i >= 0:
                    r += self.buf[:i].replace("<think>", "")
                    self.buf = self.buf[i + len("</think>"):].lstrip("\n")
                    self.state = "content"
                    continue
                cut = len(self.buf) if final else self._hold(self.buf, ["</think>"])
                r += self.buf[:cut].replace("<think>", "")
                self.buf = self.buf[cut:]
                break
            if self.state == "content":
                i = self.buf.find(TOOL_OPEN)
                if i >= 0:
                    c += self.buf[:i]
                    self.tool_text += self.buf[i:]
                    self.buf = ""
                    self.state = "tool"
                    break
                cut = len(self.buf) if final else self._hold(self.buf, [TOOL_OPEN])
                c += self.buf[:cut]
                self.buf = self.buf[cut:]
                break
            if self.state == "tool":   # everything after the first <tool_call> belongs to the calls
                self.tool_text += self.buf
                self.buf = ""
                break
        return r, c


# ---- API translation ------------------------------------------------------------------------------------------------

def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for p in content:
            if isinstance(p, dict):
                if p.get("type") in ("text", "input_text", "output_text"):
                    out.append(p.get("text", ""))
                elif p.get("type") in ("image_url", "image", "input_image"):
                    out.append("[image omitted: this model reads text only]")
            elif isinstance(p, str):
                out.append(p)
        return "".join(out)
    return "" if content is None else str(content)


def openai_messages(msgs):
    """OpenAI chat messages -> what the chat template expects (arguments as dicts, content as text)."""
    out = []
    for m in msgs:
        role = m.get("role", "user")
        if role == "developer":
            role = "system"
        o = {"role": role, "content": _text_of(m.get("content"))}
        if m.get("reasoning_content"):
            o["reasoning_content"] = m["reasoning_content"]
        if role == "assistant" and m.get("tool_calls"):
            tcs = []
            for tc in m["tool_calls"]:
                f = tc.get("function", {})
                args = f.get("arguments", {})
                if isinstance(args, str):
                    try:
                        args = json.loads(args) if args.strip() else {}
                    except ValueError:
                        args = {"input": args}
                tcs.append({"id": tc.get("id"), "type": "function", "function": {"name": f.get("name"), "arguments": args}})
            o["tool_calls"] = tcs
        if role == "tool" and m.get("tool_call_id"):
            o["tool_call_id"] = m["tool_call_id"]
        out.append(o)
    return out


def anthropic_to_openai(req):
    """Anthropic /v1/messages request -> (messages, tools) in OpenAI form."""
    msgs = []
    sysp = req.get("system")
    if sysp:
        msgs.append({"role": "system", "content": _text_of(sysp) if not isinstance(sysp, str) else sysp})
    for m in req.get("messages", []):
        role, content = m.get("role"), m.get("content")
        if isinstance(content, str):
            msgs.append({"role": role, "content": content})
            continue
        texts, calls, results = [], [], []
        for b in content or []:
            t = b.get("type")
            if t == "text":
                texts.append(b.get("text", ""))
            elif t == "tool_use":
                calls.append({"id": b.get("id"), "type": "function",
                              "function": {"name": b.get("name"), "arguments": b.get("input", {})}})
            elif t == "tool_result":
                c = b.get("content")
                results.append({"role": "tool", "tool_call_id": b.get("tool_use_id"),
                                "content": _text_of(c) if not isinstance(c, str) else c})
            elif t == "image":
                texts.append("[image omitted: this model reads text only]")
        if role == "assistant":
            o = {"role": "assistant", "content": "".join(texts)}
            if calls:
                o["tool_calls"] = calls
            msgs.append(o)
        else:
            msgs.extend(results)
            if texts:
                msgs.append({"role": "user", "content": "".join(texts)})
    tools = [{"type": "function", "function": {"name": t["name"], "description": t.get("description", ""),
                                               "parameters": t.get("input_schema", {"type": "object"})}}
             for t in req.get("tools", []) or [] if "name" in t]
    return openai_messages(msgs), tools


# ---- HTTP server ----------------------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # bodies end when the connection closes (simple for streams)
    server_version = "ps4proxy/1.0"

    def log_message(self, fmt, *a):
        if CFG.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _sse_start(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def _sse(self, data, event=None):
        s = (f"event: {event}\n" if event else "") + "data: " + (data if isinstance(data, str) else json.dumps(data)) + "\n\n"
        self.wfile.write(s.encode())
        self.wfile.flush()

    # No CORS headers: agents are not browsers, and a web page must not use (or read) this API. The Host check stops
    # DNS rebinding (a page whose name resolves to 127.0.0.1) while the proxy listens on this computer only.
    def _host_ok(self):
        if CFG.host not in ("127.0.0.1", "localhost", "::1"):
            return True   # (listening on the network on purpose)
        h = (self.headers.get("Host") or "").strip().lower()
        name = h[1:h.index("]")] if h.startswith("[") and "]" in h else h.rsplit(":", 1)[0]
        if name in ("127.0.0.1", "localhost", "::1"):
            return True
        self._json(403, {"error": {"message": "forbidden host"}})
        return False

    def do_GET(self):
        if not self._host_ok():
            return
        self.m = current_model()
        p = self.path.split("?")[0]
        if p in ("/v1/models", "/models"):
            self._json(200, {"object": "list", "data": [{"id": self.m.name, "object": "model", "created": 0,
                                                         "owned_by": "ps4"}]})
        elif p in ("/health", "/"):
            ok = True
            try:
                c = http.client.HTTPConnection(PS4B.host, PS4B.port, timeout=5)
                c.request("GET", "/health")
                ok = c.getresponse().status == 200
                c.close()
            except OSError:
                ok = False
            self._json(200 if ok else 503, {"status": "ok" if ok else "ps4 unreachable", "model": self.m.name,
                                            "ps4": f"{PS4B.host}:{PS4B.port}"})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self._host_ok():
            return
        self.m = current_model() if not CFG.selftest else MODEL
        p = self.path.split("?")[0]
        cl = (self.headers.get("Content-Length") or "0").strip()
        if not cl.isdigit() or int(cl) > 256 << 20:
            return self._json(400, {"error": {"message": "bad Content-Length"}})
        n = int(cl)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._json(400, {"error": {"message": "invalid JSON"}})
        try:
            if p in ("/v1/chat/completions", "/chat/completions"):
                return self.openai_chat(req)
            if p in ("/v1/messages", "/messages"):
                return self.anthropic(req)
            if p in ("/v1/messages/count_tokens", "/messages/count_tokens"):
                msgs, tools = anthropic_to_openai(req)
                return self._json(200, {"input_tokens": len(self.m.encode(self.m.render(msgs, tools)))})
            return self._json(404, {"error": {"message": "not found"}})
        except jinja2.TemplateError as e:
            return self._json(400, {"error": {"message": f"chat template: {e}"}})
        except BrokenPipeError:
            return

    # one generation, shared by both dialects: yields events ("reasoning"|"content", text) and returns the result
    def run(self, messages, tools, req, emit):
        think = bool(req.get("enable_thinking", CFG.think))
        if isinstance(req.get("thinking"), dict):   # Anthropic {"thinking": {"type": "enabled"}}
            think = req["thinking"].get("type") == "enabled"
        text = self.m.render(messages, tools, think)
        max_new = int(req.get("max_tokens") or req.get("max_completion_tokens") or CFG.max_tokens)
        max_new = max(1, min(max_new, CFG.max_tokens))
        temperature = req.get("temperature")
        temperature = CFG.temperature if temperature is None else float(temperature)
        seed = int(req.get("seed") or time.time_ns())
        stop_strs = req.get("stop") or req.get("stop_sequences") or []
        if isinstance(stop_strs, str):
            stop_strs = [stop_strs]
        tail = text.rstrip()
        if tail.endswith("<think>"):          # the template opened the reasoning (Maple): the reply starts inside it
            split = Splitter(True)
        elif tail.endswith("</think>"):       # reasoning closed by the template (thinking off)
            split = Splitter(False)
        elif "enable_thinking" not in self.m.template_src:
            split = Splitter(None)            # the reply decides
        else:
            split = Splitter(think)
        gen, shown = [], [""]
        state = {"stopped": False, "text": ""}

        def on_tokens(toks):
            gen.extend(toks)
            if gen and gen[-1] in self.m.stop_ids:
                full = self.m.decode(gen[:-1])
            else:
                full = self.m.decode(gen)
            if full.endswith("�"):   # half of a character: wait for the rest
                return
            for s in stop_strs:
                i = full.find(s)
                if s and i >= 0:
                    full = full[:i]
                    state["stopped"] = True
            delta = full[len(shown[0]):]
            shown[0] = full
            r, c = split.feed(delta)
            if r:
                emit("reasoning", r)
            if c:
                emit("content", c)

        with PS4B.lock:
            PS4B.model = self.m
            stats = PS4B.generate(text, max_new, temperature, seed, on_tokens, cancelled=lambda: state["stopped"])
        r, c = split.feed("", final=True)
        if r:
            emit("reasoning", r)
        if c:
            emit("content", c)
        calls = parse_tool_calls(split.tool_text, tools) if split.tool_text else []
        if state["stopped"]:
            stats["finish"] = "stop"
        sys.stderr.write(f"[ps4] prompt {stats['prompt']} ({stats['cached']} cached, read in {stats['prefill_s']:.1f}s), "
                         f"{stats['generated']} new in {stats['decode_s']:.1f}s"
                         f"{' = %.1f tok/s' % (stats['generated'] / stats['decode_s']) if stats['decode_s'] else ''}, "
                         f"{stats['finish']}{', %d tool call(s)' % len(calls) if calls else ''}"
                         f"{', ERROR ' + stats['error'] if stats['error'] else ''}\n")
        return stats, calls

    def openai_chat(self, req):
        messages = openai_messages(req.get("messages", []))
        tools = req.get("tools") or None
        stream = bool(req.get("stream"))
        cid, created = "chatcmpl-" + uuid.uuid4().hex[:24], int(time.time())
        parts = {"reasoning": [], "content": []}

        def chunk(delta, finish=None, usage=None):
            o = {"id": cid, "object": "chat.completion.chunk", "created": created, "model": self.m.name,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage:
                o["usage"] = usage
            return o

        if stream:
            self._sse_start()
            self._sse(chunk({"role": "assistant", "content": ""}))

        def emit(kind, text):
            parts[kind].append(text)
            if stream:
                self._sse(chunk({"reasoning_content": text} if kind == "reasoning" else {"content": text}))

        stats, calls = self.run(messages, tools, req, emit)
        if stats["error"] and not parts["content"]:
            if stream:
                self._sse({"error": {"message": stats["error"], "type": "server_error"}})
                return
            return self._json(502, {"error": {"message": stats["error"], "type": "server_error"}})
        tool_calls = [{"id": "call_" + uuid.uuid4().hex[:24], "type": "function", "index": i,
                       "function": {"name": n, "arguments": json.dumps(a, ensure_ascii=False)}}
                      for i, (n, a) in enumerate(calls)]
        finish = "tool_calls" if tool_calls else ("length" if stats["finish"] == "length" else "stop")
        usage = {"prompt_tokens": stats["prompt"], "completion_tokens": stats["generated"],
                 "total_tokens": stats["prompt"] + stats["generated"],
                 "prompt_tokens_details": {"cached_tokens": stats["cached"]}}
        if stream:
            if tool_calls:
                self._sse(chunk({"tool_calls": tool_calls}))
            self._sse(chunk({}, finish, usage))
            self._sse("[DONE]")
            return
        msg = {"role": "assistant", "content": "".join(parts["content"]) or (None if tool_calls else "")}
        if parts["reasoning"]:
            msg["reasoning_content"] = "".join(parts["reasoning"])
        if tool_calls:
            msg["tool_calls"] = [{k: v for k, v in tc.items() if k != "index"} for tc in tool_calls]
        self._json(200, {"id": cid, "object": "chat.completion", "created": created, "model": self.m.name,
                         "choices": [{"index": 0, "message": msg, "finish_reason": finish}], "usage": usage})

    def anthropic(self, req):
        messages, tools = anthropic_to_openai(req)
        stream = bool(req.get("stream"))
        mid = "msg_" + uuid.uuid4().hex[:24]
        blocks = []   # [type, text]
        cur = {"idx": -1, "kind": None}

        def open_block(kind):
            cur["idx"] += 1
            cur["kind"] = kind
            blocks.append([kind, ""])
            if stream:
                cb = {"type": "thinking", "thinking": ""} if kind == "thinking" else {"type": "text", "text": ""}
                self._sse({"type": "content_block_start", "index": cur["idx"], "content_block": cb},
                          "content_block_start")

        def close_block():
            if cur["kind"] and stream:
                self._sse({"type": "content_block_stop", "index": cur["idx"]}, "content_block_stop")
            cur["kind"] = None

        if stream:
            self._sse_start()
            self._sse({"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant",
                       "model": req.get("model") or self.m.name, "content": [], "stop_reason": None,
                       "stop_sequence": None, "usage": {"input_tokens": 0, "output_tokens": 0}}}, "message_start")

        def emit(kind, text):
            k = "thinking" if kind == "reasoning" else "text"
            if cur["kind"] != k:
                close_block()
                open_block(k)
            blocks[-1][1] += text
            if stream:
                d = {"type": "thinking_delta", "thinking": text} if k == "thinking" else {"type": "text_delta",
                                                                                         "text": text}
                self._sse({"type": "content_block_delta", "index": cur["idx"], "delta": d}, "content_block_delta")

        stats, calls = self.run(messages, tools, req, emit)
        if stats["error"] and not blocks:
            err = {"type": "error", "error": {"type": "api_error", "message": stats["error"]}}
            if stream:
                self._sse(err, "error")
                return
            return self._json(502, err)
        close_block()
        uses = []
        for name, args in calls:
            uid = "toolu_" + uuid.uuid4().hex[:24]
            uses.append({"type": "tool_use", "id": uid, "name": name, "input": args})
            if stream:
                cur["idx"] += 1
                self._sse({"type": "content_block_start", "index": cur["idx"],
                           "content_block": {"type": "tool_use", "id": uid, "name": name, "input": {}}},
                          "content_block_start")
                self._sse({"type": "content_block_delta", "index": cur["idx"],
                           "delta": {"type": "input_json_delta", "partial_json": json.dumps(args, ensure_ascii=False)}},
                          "content_block_delta")
                self._sse({"type": "content_block_stop", "index": cur["idx"]}, "content_block_stop")
        stop = "tool_use" if uses else ("max_tokens" if stats["finish"] == "length" else "end_turn")
        usage = {"input_tokens": stats["prompt"] - stats["cached"], "cache_read_input_tokens": stats["cached"],
                 "output_tokens": stats["generated"]}
        if stream:
            self._sse({"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                       "usage": usage}, "message_delta")
            self._sse({"type": "message_stop"}, "message_stop")
            return
        content = [{"type": "thinking", "thinking": t, "signature": ""} if k == "thinking" else {"type": "text", "text": t}
                   for k, t in blocks if t] + uses
        self._json(200, {"id": mid, "type": "message", "role": "assistant", "model": req.get("model") or self.m.name,
                         "content": content, "stop_reason": stop, "stop_sequence": None, "usage": usage})


# ---- self-test (no PS4 needed) --------------------------------------------------------------------------------------

def selftest():
    tools = [{"type": "function", "function": {"name": "read_file", "description": "Read a file",
              "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "limit": {"type": "integer"}},
                             "required": ["path"]}}}]
    msgs = openai_messages([
        {"role": "system", "content": "You are a coding agent."},
        {"role": "user", "content": "Show me main.py"},
        {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function",
         "function": {"name": "read_file", "arguments": "{\"path\": \"main.py\", \"limit\": 50}"}}]},
        {"role": "tool", "tool_call_id": "c1", "content": "print('hi')"},
    ])
    text = MODEL.render(msgs, tools)
    print("---- rendered prompt (tail) ----\n" + text[-700:])
    ids = MODEL.encode(text)
    print(f"---- {len(ids)} tokens; round trip ok: {MODEL.decode(ids) == text}")
    out = ("I'll look at it.\n\n<tool_call>\n<function=read_file>\n<parameter=path>\nmain.py\n</parameter>\n"
           "<parameter=limit>\n50\n</parameter>\n</function>\n</tool_call>")
    sp = Splitter(False)
    r1, c1 = sp.feed(out[:20])
    r2, c2 = sp.feed(out[20:], final=True)
    print("content:", repr(c1 + c2), "| tool calls:", parse_tool_calls(sp.tool_text, tools))
    am, at = anthropic_to_openai({"system": "sys", "tools": [{"name": "read_file", "input_schema": {"type": "object"}}],
                                  "messages": [{"role": "user", "content": [{"type": "text", "text": "hi"}]},
                                               {"role": "assistant", "content": [{"type": "tool_use", "id": "t1",
                                                "name": "read_file", "input": {"path": "a"}}]},
                                               {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1",
                                                                             "content": "data"}]}]})
    print("anthropic ->", json.dumps(am)[:300], "| tools:", [t["function"]["name"] for t in at])
    print("anthropic prompt renders:", len(MODEL.encode(MODEL.render(am, at))), "tokens")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ps4", default="auto", help="Garlic Server on the console (default: find it)")
    ap.add_argument("--model-dir", default=str(TOKENIZERS / "qwen3.5-9b"), help="tokenizer.json + chat template")
    ap.add_argument("--model-name", default="ps4-qwen3.5-9b")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--max-tokens", type=int, default=4096, help="cap on new tokens per request")
    ap.add_argument("--temperature", type=float, default=0.6)
    ap.add_argument("--think", action="store_true", help="reasoning on by default (slower)")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    CFG = ap.parse_args()
    MODEL = Model(CFG.model_dir, CFG.model_name)
    if CFG.selftest:
        selftest()
        sys.exit(0)
    auto = CFG.ps4 == "auto"
    PS4B = PS4("http://0.0.0.0:8080" if auto else CFG.ps4, MODEL)
    if auto:
        threading.Thread(target=beacon_listener, daemon=True).start()
        scan_for_ps4()
    srv = ThreadingHTTPServer((CFG.host, CFG.port), Handler)
    print(f"ps4proxy: {MODEL.name} on the PS4 at {'(finding it: UDP 8099 / scan)' if auto else CFG.ps4}\n"
          f"  OpenAI:    http://{CFG.host}:{CFG.port}/v1\n  Anthropic: http://{CFG.host}:{CFG.port}", flush=True)
    srv.serve_forever()
