#!/usr/bin/env bash
# Time-to-first-token check against a llama-server OpenAI endpoint. This is the
# user-visible number the NPU improves: run it once with the NPU backend on,
# once with it off, same prompt.
#
#   scripts/ttft-check.sh [BASE_URL] [PROMPT_TOKENS]
#     BASE_URL       default http://localhost:8080   (kubectl port-forward
#                    svc/llama-server 8080:8080 -n chat-rk1)
#     PROMPT_TOKENS  approximate prompt length to synthesize, default 2000 —
#                    prefill wins show at LONG prompts; short ones are noise.
#
# A/B procedure (see README "prove the NPU is working"). The env comes from
# the llama-server-config ConfigMap via envFrom; an explicit empty override
# disables it, and removing the override restores the ConfigMap value:
#   NPU on  : default deploy                          → run this script
#   NPU off : kubectl -n chat-rk1 set env deploy/llama-server GGML_BACKEND_PATH=""
#             kubectl -n chat-rk1 rollout status deploy/llama-server
#                                                     → run this script again
#   restore : kubectl -n chat-rk1 set env deploy/llama-server GGML_BACKEND_PATH-
# Note: send one short warmup request after each restart before measuring.
set -euo pipefail
BASE_URL="${1:-http://localhost:8080}"
PROMPT_TOKENS="${2:-2000}"

command -v jq >/dev/null || { echo "needs jq" >&2; exit 2; }
calc() { awk "BEGIN{printf \"%.2f\", $1}"; }

# Synthesize a ~N-token prompt (~17 tokens per repetition) + a question. The
# random prefix defeats llama-server's prompt cache so repeat runs measure a
# real prefill, not a KV-cache hit. The actual token count is reported from
# the response usage.
filler="Session ${RANDOM}${RANDOM}. $(awk -v n="$((PROMPT_TOKENS / 17 + 1))" \
  'BEGIN{for(i=0;i<n;i++) printf "The quick brown fox jumps over the lazy dog near the riverbank at dawn. "}')"
body="$(jq -n --arg p "$filler Summarize the text above in one sentence." \
  '{model:"default", stream:true, max_tokens:64,
    stream_options:{include_usage:true},
    messages:[{role:"user",content:$p}]}')"

echo "POST $BASE_URL/v1/chat/completions (~$PROMPT_TOKENS-token prompt, stream)"
t0=$(date +%s.%N)
first=""; ntok=0; nprompt="?"
while IFS= read -r line; do
  case "$line" in
    data:\ \[DONE\]) break ;;
    data:\ *)
      u="$(printf '%s' "${line#data: }" | jq -r '.usage.prompt_tokens // empty' 2>/dev/null)"
      [ -n "$u" ] && nprompt="$u"
      # count only chunks that carry content
      c="$(printf '%s' "${line#data: }" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
      [ -z "$c" ] && continue
      ntok=$((ntok + 1))
      if [ -z "$first" ]; then
        first=$(date +%s.%N)
        echo "TTFT: $(calc "$first - $t0") s"
      fi
      ;;
  esac
done < <(curl -sN --max-time 600 "$BASE_URL/v1/chat/completions" \
           -H 'Content-Type: application/json' -d "$body")
t1=$(date +%s.%N)
echo "prompt tokens (actual): $nprompt"

[ -z "$first" ] && { echo "no tokens received — is the server up?" >&2; exit 1; }
echo "decode: $ntok tokens in $(calc "$t1 - $first") s ($(calc "$ntok / ($t1 - $first)") tok/s)"
