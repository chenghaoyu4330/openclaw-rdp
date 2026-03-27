#!/usr/bin/env bash
set -euo pipefail

# ── 1. Prepare openclaw config directory ────────────────────────────────────
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/home/node/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/home/node/.openclaw/workspace}"

mkdir -p \
    "$OPENCLAW_CONFIG_DIR" \
    "$OPENCLAW_WORKSPACE_DIR" \
    "$OPENCLAW_CONFIG_DIR/identity" \
    "$OPENCLAW_CONFIG_DIR/agents/main/agent" \
    "$OPENCLAW_CONFIG_DIR/agents/main/sessions"

chown -R node:node "$OPENCLAW_CONFIG_DIR" 2>/dev/null || true

# ── 2. Resolve gateway token (needed by both onboard and the patch) ─────────
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"

BASE_URL="${MAAS_BASE_URL:-https://chat.noc.pku.edu.cn}"
BASE_URL="${BASE_URL%/}"

# ── 3. Run onboard to initialize identity + agent config (first run only) ───
IDENTITY_DIR="$OPENCLAW_CONFIG_DIR/identity"
if [[ -z "$(ls -A "$IDENTITY_DIR" 2>/dev/null)" ]]; then
    echo "[entrypoint] Running onboard (first-time setup)..."
    su -s /bin/bash node -c \
        "node /app/dist/index.js onboard \
            --mode local \
            --non-interactive \
            --accept-risk \
            --no-install-daemon \
            --skip-channels \
            --skip-search \
            --skip-skills \
            --skip-health \
            --auth-choice skip \
            --gateway-token '${GATEWAY_TOKEN}' \
            --gateway-bind lan" \
        || echo "[entrypoint] WARNING: onboard exited non-zero, continuing..."
    echo "[entrypoint] Onboard complete."
else
    echo "[entrypoint] Identity already initialized, skipping onboard."
fi

# ── 4. Patch openclaw.json with env-driven values ───────────────────────────
# Onboard already wrote a complete openclaw.json. We only overwrite the fields
# that come from env vars; all other fields (hooks, plugins, tools, etc.) are
# left exactly as onboard (or a previous run) set them.
OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"

python3 - <<PYEOF
import json, os, sys

path   = os.environ["OPENCLAW_JSON"]       = "$OPENCLAW_JSON"
token  = "$GATEWAY_TOKEN"
api_key = os.environ.get("MAAS_API_KEY", "")
base_url = "${BASE_URL}"

try:
    with open(path, "r") as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

gw = cfg.setdefault("gateway", {})
gw["mode"] = "local"
gw["bind"] = "lan"
gw.setdefault("auth", {})["token"] = token
gw.setdefault("controlUi", {})["allowedOrigins"] = [
    "http://localhost:18789", "http://127.0.0.1:18789"
]

# ── models.providers: add/replace MaaS providers only if key is provided ──
if api_key:
    providers = cfg.setdefault("models", {}).setdefault("providers", {})
    cfg["models"]["mode"] = "merge"
    providers["MaaS-openai"] = {
        "baseUrl": base_url + "/v1",
        "apiKey": api_key,
        "api": "openai-completions",
        "models": providers.get("MaaS-openai", {}).get("models", [])
    }
    providers["MaaS-anthrpc"] = {
        "baseUrl": base_url,
        "apiKey": api_key,
        "api": "anthropic-messages",
        "models": providers.get("MaaS-anthrpc", {}).get("models", [
            {
                "id": "claude-sonnet-4-6",
                "name": "Claude Sonnet 4.6 (MaaS)",
                "reasoning": False,
                "input": ["text", "image"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 200000,
                "maxTokens": 16000
            }
        ])
    }
    providers["MaaS-google"] = {
        "baseUrl": base_url + "/v1beta",
        "apiKey": api_key,
        "api": "google-generative-ai",
        "models": providers.get("MaaS-google", {}).get("models", [
            {
                "id": "gemini-3.1-pro-preview",
                "name": "Gemini 3.1 Pro Preview (MaaS)",
                "reasoning": False,
                "input": ["text", "image"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 1000000,
                "maxTokens": 8192
            }
        ])
    }
    # ── agents.defaults.model.primary: only set on first run (no existing primary) ──
    agents_def = cfg.setdefault("agents", {}).setdefault("defaults", {})
    if not agents_def.get("model", {}).get("primary"):
        agents_def.setdefault("model", {})["primary"] = "MaaS-anthrpc/claude-sonnet-4-6"

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"[entrypoint] Patched openclaw.json (token: {token})")
PYEOF

chown node:node "$OPENCLAW_JSON"

# ── 5. Set RDP login password for the 'node' user ───────────────────────────
# Default password is 'openclaw' — override via OPENCLAW_RDP_PASSWORD env var.
RDP_PASSWORD="${OPENCLAW_RDP_PASSWORD:-openclaw}"
echo "node:${RDP_PASSWORD}" | chpasswd
echo "[entrypoint] RDP user: node  password: ${RDP_PASSWORD}"

# ── 6. Ensure dbus and xrdp runtime dirs exist ──────────────────────────────
mkdir -p /var/run/xrdp /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
chmod 755 /var/run/xrdp

# ── 7. Start supervisord ─────────────────────────────────────────────────────
echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
