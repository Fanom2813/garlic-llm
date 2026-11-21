#!/bin/sh
# Downloads the tokenizer files the Mac app and the Python proxy need (tokenizer.json, tokenizer_config.json,
# chat_template.jinja) from Hugging Face into models/tokenizers/<name>. Only the text side: no weights.
#   tools/fetch_tokenizers.sh
set -e
cd "$(dirname "$0")/.."
fetch() {   # repo name
  mkdir -p "models/tokenizers/$2"
  for f in tokenizer.json tokenizer_config.json chat_template.jinja; do
    [ -s "models/tokenizers/$2/$f" ] && continue
    echo "$1/$f"
    curl -fsSL "https://huggingface.co/$1/resolve/main/$f" -o "models/tokenizers/$2/$f"
  done
}
fetch deepgrove/maple-preview maple        # Maple Preview (MIT)
fetch Qwen/Qwen3.5-9B qwen3.5-9b           # Qwen3.5 9B (Apache-2.0), Garlic's own chat model
echo "tokenizers in models/tokenizers"
