#!/data/data/com.termux/files/usr/bin/bash

API_KEY="sk-xt-96220ecdefddcbeaa2d9761996fbd74da51f7fecde3e84dc"
BASE_URL="https://api.xkiro.com/v1"
MODELS_FILE="$HOME/xkiro_models.json"
CONFIG_FILE="$HOME/.pi/agent/models.json"

echo "📥 Descargando lista de modelos desde $BASE_URL/models ..."

HTTP_CODE=$(curl -sS -L -o "$MODELS_FILE" -w "%{http_code}" \
  --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
  -H "Authorization: Bearer $API_KEY" \
  -H "Accept: application/json" \
  "$BASE_URL/models")

if [ "$HTTP_CODE" != "200" ] || [ ! -s "$MODELS_FILE" ]; then
  echo "❌ Error: respuesta vacía o HTTP $HTTP_CODE"
  [ -f "$MODELS_FILE" ] && head -c 300 "$MODELS_FILE" && echo
  rm -f "$MODELS_FILE"
  exit 1
fi

echo "✅ Lista descargada ($(wc -c < "$MODELS_FILE") bytes)"

python3 > "$CONFIG_FILE" << 'PYEOF'
import json, sys
api_key = "sk-xt-96220ecdefddcbeaa2d9761996fbd74da51f7fecde3e84dc"
base_url = "https://api.xkiro.com/v1"
import os
src = os.path.expanduser("~/xkiro_models.json")
try:
    with open(src, "r", encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    print("❌ No se encontró " + src, file=sys.stderr); sys.exit(1)
except json.JSONDecodeError as e:
    print("❌ JSON inválido: " + str(e), file=sys.stderr); sys.exit(1)

def _name(d):
    s = d.strip()
    return s if s.lower().endswith("(free)") else s + " (Free)"

free = [m for m in data.get("data", []) if m.get("access_tier") == "free"]
out = []
for m in free:
    caps = m.get("capabilities", {}) or {}
    out.append({
        "id": m["id"],
        "name": _name(m.get("display_name") or m["id"]),
        "contextWindow": m.get("context_length", 128000),
        "maxTokens": m.get("max_output_tokens", 16384),
        "reasoning": bool(caps.get("reasoning", False)),
        "input": ["text", "image"] if caps.get("vision") else ["text"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    })

print(json.dumps({"providers": {"xkiro": {
    "baseUrl": base_url, "api": "openai-completions",
    "apiKey": api_key, "models": out
}}}, indent=2, ensure_ascii=False))
PYEOF

if [ ! -s "$CONFIG_FILE" ]; then
  echo "❌ Error creando $CONFIG_FILE"
  exit 1
fi

FREE_COUNT=$(grep -c '"id":' "$CONFIG_FILE")
echo "✅ $CONFIG_FILE actualizado con $FREE_COUNT modelos gratuitos"
echo ""
echo "═══ MODELOS GRATUITOS ═══"
grep '"name":' "$CONFIG_FILE"
