#!/usr/bin/env bash
set -euo pipefail
# Workaround: manually configure inference when nemoclaw onboard fails.
#
# The SAW setup job tries to pip install openshell==0.0.99+rhaiv.0 which does
# not exist on PyPI, causing the nemoclaw onboard step to fail. This script
# replicates the onboard steps: OIDC auth, workspace access, network policy,
# and OpenClaw model configuration.

: "${SAW_NAMESPACE:=openshell-agents}"
: "${SAW_SANDBOX_NAME:=openclaw-test}"
: "${SAW_VM_NAME:=mschimun-test}"
: "${GEMINI_API_KEY:?set GEMINI_API_KEY}"
: "${GEMINI_MODEL:=gemini-3.6-flash}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve SSH key from cluster secret
SSH_KEY="/tmp/saw-ssh-key-$$"
oc get secret openshell-aap-ssh -n "$SAW_NAMESPACE" \
  -o jsonpath='{.data.key}' | base64 -d > "$SSH_KEY"
chmod 600 "$SSH_KEY"
trap "rm -f '$SSH_KEY'" EXIT

ssh_vm() {
  virtctl -n "$SAW_NAMESPACE" ssh \
    --identity-file="$SSH_KEY" \
    "cloud-user@vm/$SAW_VM_NAME" \
    --local-ssh-opts="-oStrictHostKeyChecking=no" \
    --local-ssh-opts="-oUserKnownHostsFile=/dev/null" \
    --command="$1"
}

# --- Step 1: Get OIDC token from Keycloak ---
echo "==> Getting OIDC token from Keycloak..."
KC_HOST=$(oc get route -n "$SAW_NAMESPACE" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' \
  | grep keycloak | head -1)

if [[ -z "$KC_HOST" ]]; then
  echo "ERROR: Could not find Keycloak route in namespace $SAW_NAMESPACE" >&2
  exit 1
fi

ISSUER="https://${KC_HOST}/realms/openshell"
OIDC_TOKEN=$(curl -sk -X POST "${ISSUER}/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=openshell-cli" \
  -d "username=alice" \
  -d "password=alice" \
  -d "scope=openid" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "  Token obtained (${#OIDC_TOKEN} chars)"

# --- Step 2: Grant workspace access ---
echo "==> Granting workspace access..."
ssh_vm "
OIDC_TOKEN_PATH=\${HOME}/.config/openshell/gateways/openshell/oidc_token.json
mkdir -p \$(dirname \${OIDC_TOKEN_PATH})
chmod 700 \$(dirname \${OIDC_TOKEN_PATH})
printf '{\"access_token\":\"%s\",\"issuer\":\"%s\",\"client_id\":\"openshell-cli\"}' \
  '${OIDC_TOKEN}' '${ISSUER}' > \${OIDC_TOKEN_PATH}
chmod 600 \${OIDC_TOKEN_PATH}
openshell workspace member add --workspace default --subject openshell-client --role admin 2>&1 || \
  echo '(already a member)'
"

# --- Step 3: Update sandbox network policy ---
echo "==> Updating sandbox network policy..."
ssh_vm "
openshell policy update ${SAW_SANDBOX_NAME} \
  --add-endpoint 'generativelanguage.googleapis.com:443:read-write:rest:enforce' \
  --binary /usr/local/bin/node \
  --binary /usr/bin/node \
  --binary /usr/bin/curl \
  --wait
"

# --- Step 4: Configure OpenClaw for Gemini ---
echo "==> Configuring OpenClaw..."

# Prepare models.json with the actual API key
MODELS_JSON=$(sed "s|__GEMINI_API_KEY__|${GEMINI_API_KEY}|g" "$SCRIPT_DIR/config/models.json")

ssh_vm "
openshell sandbox exec -n ${SAW_SANDBOX_NAME} --no-tty -- sh -c 'cat > /sandbox/.openclaw/agents/main/agent/models.json << MODEOF
${MODELS_JSON}
MODEOF'

openshell sandbox exec -n ${SAW_SANDBOX_NAME} --no-tty -- node -e \"
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync('/sandbox/.openclaw/openclaw.json', 'utf8'));
cfg.agents.defaults.model.primary = 'google/${GEMINI_MODEL}';
cfg.models.mode = 'replace';
cfg.models.providers = JSON.parse(fs.readFileSync('/sandbox/.openclaw/agents/main/agent/models.json', 'utf8')).providers;
fs.writeFileSync('/sandbox/.openclaw/openclaw.json', JSON.stringify(cfg, null, 2));
console.log('Primary model: google/${GEMINI_MODEL}');
\"
"

echo ""
echo "Done. Run a quick test:"
echo "  virtctl -n $SAW_NAMESPACE ssh --identity-file=\$SSH_KEY cloud-user@vm/$SAW_VM_NAME \\"
echo "    --command=\"openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \\"
echo "      openclaw infer model run --model google/$GEMINI_MODEL --prompt 'Hello' --no-color\""
