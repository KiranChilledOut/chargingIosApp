#!/usr/bin/env bash
# Verifies your Nebius key and model choice using the exact request shape the
# app sends. Run this before building — it separates "my key or model is wrong"
# from "the app is broken", which is otherwise hard to tell apart from a
# failing Back Tap.
#
#   NEBIUS_API_KEY=... ./scripts/smoke-test.sh [text-model]

set -uo pipefail

BASE="${NEBIUS_BASE_URL:-https://api.tokenfactory.nebius.com/v1}"
MODEL="${1:-${NEBIUS_TEXT_MODEL:-Qwen/Qwen3-235B-A22B-Instruct-2507}}"

if [ -z "${NEBIUS_API_KEY:-}" ]; then
  echo "NEBIUS_API_KEY is not set." >&2
  exit 2
fi

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 2; }

pass() { printf '  \033[32mok\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

echo
echo "Endpoint: $BASE"
echo "Model:    $MODEL"
echo

# ---------------------------------------------------------------- 1. auth
echo "1. Authentication"
models_body=$(curl -sS -m 30 -w '\n%{http_code}' "$BASE/models" \
  -H "Authorization: Bearer $NEBIUS_API_KEY")
models_code=$(printf '%s' "$models_body" | tail -n1)
models_json=$(printf '%s' "$models_body" | sed '$d')

if [ "$models_code" != "200" ]; then
  fail "HTTP $models_code"
  info "$(printf '%s' "$models_json" | jq -r '.detail // .error.message // .' 2>/dev/null | head -3)"
  exit 1
fi
count=$(printf '%s' "$models_json" | jq '.data | length')
pass "key accepted, $count models available"

# ------------------------------------------------------------ 2. model id
echo
echo "2. Model availability"
if printf '%s' "$models_json" | jq -e --arg m "$MODEL" '.data[] | select(.id == $m)' >/dev/null; then
  pass "$MODEL is in the catalog"
else
  fail "$MODEL is NOT in the catalog"
  info "Close matches:"
  printf '%s' "$models_json" | jq -r '.data[].id' \
    | grep -iE "$(printf '%s' "$MODEL" | cut -d/ -f2 | cut -d- -f1)" | head -5 | sed 's/^/        /'
  info "Full list: curl -s $BASE/models -H \"Authorization: Bearer \$NEBIUS_API_KEY\" | jq -r '.data[].id'"
fi

# ----------------------------------------------- 3. translate, guided JSON
echo
echo "3. Translation with JSON Schema (the app's primary path)"
read -r -d '' SYSTEM <<'EOP'
You repair OCR output from Dutch mobile app screens and translate it to English.
Return ONLY a JSON array. One object per input run, with the same "id".
Each object has exactly: {"id": <int>, "nl": "<repaired Dutch>", "en": "<English>"}
EOP

payload=$(jq -n --arg model "$MODEL" --arg system "$SYSTEM" '{
  model: $model,
  temperature: 0.1,
  max_tokens: 512,
  messages: [
    {role: "system", content: $system},
    {role: "user", content: "Text runs from one Dutch app screen:\n[{\"id\":0,\"text\":\"Instellingen\"},{\"id\":1,\"text\":\"Betaling mislukt\"},{\"id\":2,\"text\":\"Rekening [[R1]]\"}]"}
  ],
  response_format: {
    type: "json_schema",
    json_schema: {
      type: "array",
      items: {
        type: "object",
        properties: {id: {type: "integer"}, nl: {type: "string"}, en: {type: "string"}},
        required: ["id", "nl", "en"],
        additionalProperties: false
      }
    }
  }
}')

resp=$(curl -sS -m 90 -w '\n%{http_code}' "$BASE/chat/completions" \
  -H "Authorization: Bearer $NEBIUS_API_KEY" \
  -H "Content-Type: application/json" -d "$payload")
code=$(printf '%s' "$resp" | tail -n1)
json=$(printf '%s' "$resp" | sed '$d')

schema_ok=0
if [ "$code" = "200" ]; then
  pass "schema-guided request accepted"
  schema_ok=1
else
  fail "HTTP $code with response_format"
  info "$(printf '%s' "$json" | jq -r '.detail // .error.message // .' 2>/dev/null | head -3)"
  info "Retrying without response_format (the app does this automatically)..."

  payload=$(printf '%s' "$payload" | jq 'del(.response_format)')
  resp=$(curl -sS -m 90 -w '\n%{http_code}' "$BASE/chat/completions" \
    -H "Authorization: Bearer $NEBIUS_API_KEY" \
    -H "Content-Type: application/json" -d "$payload")
  code=$(printf '%s' "$resp" | tail -n1)
  json=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" = "200" ]; then
    pass "unconstrained request accepted (fallback path works)"
  else
    fail "HTTP $code without response_format too"
    info "$(printf '%s' "$json" | jq -r '.detail // .error.message // .' 2>/dev/null | head -3)"
    exit 1
  fi
fi

content=$(printf '%s' "$json" | jq -r '.choices[0].message.content // empty')
if [ -z "$content" ]; then
  fail "empty completion"
  exit 1
fi

echo
echo "   Model returned:"
printf '%s\n' "$content" | sed 's/^/      /' | head -12

# ------------------------------------------------------- 4. output quality
echo
echo "4. Output checks"
cleaned=$(printf '%s' "$content" | sed -e 's/^```[a-z]*//' -e 's/```$//')
if printf '%s' "$cleaned" | jq -e 'type == "array"' >/dev/null 2>&1; then
  pass "parses as a JSON array"
  n=$(printf '%s' "$cleaned" | jq 'length')
  [ "$n" -eq 3 ] && pass "all 3 ids returned" || fail "expected 3 entries, got $n"

  if printf '%s' "$cleaned" | jq -e '.[] | select(.id == 2) | select(.en | contains("[[R1]]"))' >/dev/null 2>&1; then
    pass "redaction placeholder preserved verbatim"
  else
    fail "placeholder [[R1]] was altered — personal data would not restore"
    info "The app tolerates some reformatting, but this model needs watching."
  fi
else
  fail "not valid JSON even after stripping fences"
  info "The app's parser is more forgiving than this check; try another model."
fi

echo
if [ "$schema_ok" = "1" ]; then
  echo "Ready. Use this model id in NL Lens › Settings."
else
  echo "Usable, but this model ignores response_format — output will be less reliable."
fi
echo
