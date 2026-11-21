# Garlic Server: the PS4 as a local inference box for coding agents

*This is part of the fork (see the README). It is not in the original Garlic LLM.*

Garlic Server is a build of Garlic LLM with no chat screen, no voice and no dictation. The console loads one model and serves it on the local network. A small companion on your computer (a native **Mac app**, or a **Python proxy** for any OS) turns it into a normal **OpenAI- and Anthropic-compatible API** on `127.0.0.1`. Coding agents and chat clients use that API as if it were a cloud model.

```
 coding agent ──HTTP──▶ Garlic.app / proxy.py ──LAN──▶ PS4: Garlic Server ──▶ GPU
  (OpenAI or             (chat template, tokenizer,    (binary /v1/raw:        (Maple or
   Anthropic API)         tool calls, streaming)        tokens in, tokens out)   Qwen3.5-9B)
```

## Models

| Model | Size | Speed on a base PS4 | Notes |
|---|---|---|---|
| **[Maple Preview](https://huggingface.co/deepgrove/maple-preview)** (deepgrove, MIT) | 20B parameters, 1B active (mixture of experts, ternary weights) | **~104 tokens/s** writing at the start of a conversation, ~80 at 14K tokens; reading a prompt ~200 tokens/s | New engine in this fork (`chat/engine_maple.inc`, `shaders/maple.cl`) |
| Qwen3.5-9B (Garlic's own) | 9B, 4-bit | 34–40 tokens/s | The original Garlic LLM model |

Context: 16,384 tokens (prompt plus reply).

## What the server adds

- **`POST /v1/raw`**: a small binary protocol. The client sends token ids, and the server streams back token ids. The text side (chat template, tokenizer, tool-call parsing) stays on the computer, so the console only does the maths.
- **Prompt cache**: the console keeps what it has read. A follow-up turn only reads its new tokens (usually under a second), and a new conversation that starts with the same system prompt reuses it (about 1 s instead of a minute for an 8K-token agent prompt).
- **Discovery**: the server announces itself on UDP port 8099 every 2 s (`GARLIC1 <port> <model>`), so the computer finds the console even when its IP address changes. No fixed IP is needed.
- **Model picker**: choose the model on the console at start. Install models over FTP or from a USB drive.
- **Status screen**: the TV shows the requests, speeds and cache hits.

## 1. Build or install the package

The package (`IV0000-PSAI00003_00-PS4LOCALAICHAT03.pkg`, title "Garlic Server") is built like Garlic LLM (see *Build from source* in the README):

```
python build_chat.py --server
```

`build.py` also builds on macOS (OpenOrbis `bin/macos`). Install the package with GoldHEN's Package Installer, from Debug Settings or from `/data/pkg`.

> **Wait until a package upload has finished before you install it.** Installing a half-uploaded package fails in confusing ways.

## 2. Convert Maple for the PS4

You need Python 3 with NumPy, and the toolchain from *Build from source* (for the GPU kernels).

```
mkdir -p models/maple
curl -L -o models/maple/maple-preview-TQ1_0-head-Q4_K.gguf \
  https://huggingface.co/deepgrove/maple-preview-GGUF/resolve/main/maple-preview-TQ1_0-head-Q4_K.gguf
tools/fetch_tokenizers.sh
cp models/tokenizers/maple/tokenizer.json models/maple/

python pc/maple/convert_maple.py --t1i models/maple/maple-preview-TQ1_0-head-Q4_K.gguf models/maple-ps4
python pc/maple/build_kernels.py models/maple-ps4/kernels.bin
python pc/maple/check_converted.py        # optional: compares the converted tensors with the GGUF
```

`models/maple-ps4` then holds `maple-ternary-t1i.bin` (4.3 GB, loaded into GPU memory), `maple-embed.bin` (0.6 GB, read from disk as needed), `model.idx`, `tokenizer.bin` and `kernels.bin`. Nothing is re-quantized: the ternary bits are the GGUF's own, only rearranged for the PS4's GPU.

`pc/maple/maple_ref.py` is a slow NumPy reference of the whole model, used to check the GPU's output.

## 3. Put the model on the console

**FTP** (GoldHEN's FTP server, port 2121): copy the folder to `/data/garlic/models/maple/`, and add a line `maple` to `/data/garlic/models.txt`.

**USB drive**: put the files in `garlic/models/maple/` on the drive and list them in `garlic/manifest.txt`, one `maple/<file>` per line. At start, the server copies whatever is missing to `/data`.

Start Garlic Server and pick the model. Once the TV shows the API address, it is ready. The first start after an install runs its GPU self-checks (about 50 s).

## 4. The companion on your computer

### Mac: Garlic.app (macOS 14+)

```
cd mac
./make_app.sh          # downloads the tokenizers if needed, builds, signs ad hoc, installs ~/Applications/Garlic.app
```

A menu bar app. It finds the console by its announcement (or a scan of the local network), shows the status, live tokens/s and the last request, and serves:

- **OpenAI API:** `http://127.0.0.1:8000/v1` (`/chat/completions`, `/models`)
- **Anthropic API:** `http://127.0.0.1:8000` (`/v1/messages`, `/v1/messages/count_tokens`)

It only accepts connections from the Mac itself. Optional settings:

```
defaults write local.garlic.mac port 8001               # another port
defaults write local.garlic.mac ps4 192.168.1.50        # a fixed console address instead of discovery
```

Log: `~/Library/Logs/Garlic.log`. Allow incoming connections when macOS asks, otherwise the app cannot hear the console's announcement. `swift run GarlicCheck` (in `mac/`) checks that the app renders prompts and token ids exactly like the Python proxy (`mac/tests/golden.json`).

### Any OS: proxy.py

```
tools/fetch_tokenizers.sh
python proxy/proxy.py            # finds the console; same API on 127.0.0.1:8000
python proxy/bench.py            # speed and cache benchmark through the proxy
```

## 5. Point an agent at it

Any client that takes an OpenAI-compatible base URL works. No API key is needed (send any string if the client insists). Use the model name the console reports (`GET /v1/models`).

Example for an agent with an OpenAI-compatible provider setting:

```json
{
  "providers": {
    "garlic": { "display_name": "Garlic (PS4)", "api": "openai-completions", "base_url": "http://127.0.0.1:8000/v1" }
  },
  "catalog": { "models": { "garlic": { "maple": { "limit": { "context": 16384 } } } } }
}
```

When a prompt does not fit the context, the companion answers HTTP 400 with the standard error (`context_length_exceeded`, or Anthropic's `prompt is too long`), so the agent can compact its history and retry.

## Be careful with agents

Maple is a small model (1B active parameters). With shell access it will sometimes run commands that make no sense. In testing, it uninstalled the very agent that was driving it (`brew uninstall`). Turn on your agent's command approval, work in a project folder, and give it narrow tasks.

## Security notes

- The companion API listens on `127.0.0.1` only, sends no CORS headers (a web page cannot use it), and refuses requests whose `Host` is not `127.0.0.1` or `localhost` (DNS rebinding).
- The console's port 8080 and its UDP announcement have **no authentication**: use them on a network you trust. Someone on the same network can talk to the console, or announce a fake one. While the current console answers, the companions ignore announcements from other addresses and log them. A newly found console is only used when the old one stops answering. To pin the address: `defaults write local.garlic.mac ps4 <ip>` or `proxy.py --ps4 http://<ip>:8080`.

## Performance notes (base PS4, Maple)

| | |
|---|---|
| Writing, short context | ~104 tokens/s (GPU 8.7 ms per token) |
| Writing at 8K / 14K tokens | ~80 / ~78–85 tokens/s (global attention grows with the context) |
| Reading a cold prompt | ~200 tokens/s at the start, ~125 at 14K |
| Follow-up turn | prompt read in 0.3–1 s (cache) |
| New conversation, same system prompt | ~1 s (system-prompt cache) |

The engine runs the batched prompt (128 tokens per pass, experts grouped by token), tile-interleaved ternary matrix kernels with lookup-table decoding, a two-stage sampler, and keeps recently used embedding rows in RAM. Details are in the comments of `chat/engine_maple.inc` and `shaders/maple.cl`.

Known limits:
- 16K context. Going further needs an 8-bit attention cache (the PS4's 4.5 GB is nearly full).
- Base PS4 tested. PS4 Pro untested.
