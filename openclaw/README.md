# OpenClaw-in-OpenShell demo on OpenShift

Live demo: OpenClaw (AI agent runtime with a web UI) running inside an OpenShell sandbox on OpenShift, with Vertex AI inference (Claude Opus), Jira MCP integration, MLflow tracing via RHOAI, and a browser-accessible Control UI protected by OpenShift OAuth.

Tested on: `mschimun-dev` ROSA cluster (OpenShift 4.19), OpenShell v0.0.97, RHOAI 3.4.2, MLflow 3.10.1, OpenClaw 2026.6.34.

> **Parallel operation:** This demo runs alongside the OpenCode demo on the same OpenShell gateway. Each agent gets its own sandbox (`opencode-demo` and `openclaw-demo`) with independent policies. No conflicts.

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  OpenShift (ROSA)                                                  │
│                                                                    │
│  ┌─────────────────┐   ┌──────────────────────────────────┐        │
│  │ OpenShell       │   │ OpenShell Sandbox (openclaw-demo) │        │
│  │ Gateway         │──▶│  ┌────────────┐  ┌────────────┐  │        │
│  │ (control plane) │   │  │ OpenClaw   │  │ Jira MCP   │  │        │
│  └────────┬────────┘   │  │ (Node.js)  │  │ (Python)   │  │        │
│           │            │  │            │  └──────┬─────┘  │        │
│  ┌────────▼────────┐   │  │  Gateway   │         │        │        │
│  │ OAuth Proxy     │   │  │  daemon    │  Network policies│        │
│  │ + nginx sidecar │──▶│  │  :19001    │  control access  │        │
│  │ (openclaw-ui)   │   │  └──────┬─────┘         │        │        │
│  └─────────────────┘   └─────────┼───────────────┼────────┘        │
│                                  │               │                 │
│  ┌─────────────────┐             │               │                 │
│  │ RHOAI           │◀── OTel ────┘               │                 │
│  │ ├ MLflow        │                             │                 │
│  │ └ Dashboard     │                             │                 │
│  └─────────────────┘                             │                 │
│                                                  │                 │
└──────────────────────────────────────────────────┼─────────────────┘
                                                   │
                                  ┌────────────────┼──────────┐
                                  │                │          │
                         ┌────────▼──┐    ┌────────▼───┐  ┌───▼──┐
                         │ Vertex AI │    │ Jira       │  │ PyPI │
                         │ (Claude)  │    │ (Atlassian)│  │      │
                         └───────────┘    └────────────┘  └──────┘
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `oc` | 4.19+ | `brew install openshift-cli` |
| `openshell` | 0.0.97 | [GitHub release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.97) |
| `node` / `npm` | 22+ | `brew install node` |

Credentials needed:

- OpenShift cluster-admin token
- GCP project `itpc-gcp-ai-eng-claude` with Vertex AI API enabled
- `gcloud auth application-default login` completed
- Jira API token for `redhat.atlassian.net`

Cluster must be demo-ready (OpenShell + RHOAI + MLflow deployed). See [`../opencode/docs/cluster-prep.md`](../opencode/docs/cluster-prep.md) for the full cluster setup procedure.

## Pre-build: create the OpenClaw sandbox bundle

OpenClaw and its plugins are bundled into a tarball that gets uploaded to the sandbox. Build it once on your laptop:

```shell
mkdir -p /tmp/openclaw-full-bundle && cd /tmp/openclaw-full-bundle
npm init -y > /dev/null
npm install openclaw@latest

# Install plugins via OpenClaw's plugin manager
npx openclaw plugins install @openclaw/anthropic-vertex-provider
npx openclaw plugins install @openclaw/diagnostics-otel

# Create peer-dependency symlinks for sandbox resolution.
# Plugins need to find the main `openclaw` package at runtime.
VERTEX_DIR=$(ls -d ~/.openclaw/npm/projects/openclaw-anthropic-vertex-provider-*/node_modules/@openclaw/anthropic-vertex-provider/node_modules 2>/dev/null | head -1)
OTEL_DIR=$(ls -d ~/.openclaw/npm/projects/openclaw-diagnostics-otel-*/node_modules/@openclaw/diagnostics-otel/node_modules 2>/dev/null | head -1)
mkdir -p "$VERTEX_DIR/openclaw" "$OTEL_DIR/openclaw"

# Symlinks point to where openclaw will be inside the sandbox
ln -sf /sandbox/node_modules/openclaw/dist "$VERTEX_DIR/openclaw/dist"
ln -sf /sandbox/node_modules/openclaw/package.json "$VERTEX_DIR/openclaw/package.json"
ln -sf /sandbox/node_modules/openclaw/dist "$OTEL_DIR/openclaw/dist"
ln -sf /sandbox/node_modules/openclaw/package.json "$OTEL_DIR/openclaw/package.json"

# Bundle everything
cd /tmp
tar czf openclaw-sandbox-bundle.tar.gz \
  -C /tmp/openclaw-full-bundle node_modules \
  -C ~ .openclaw/npm .openclaw/openclaw.json

echo "Bundle at /tmp/openclaw-sandbox-bundle.tar.gz ($(du -h /tmp/openclaw-sandbox-bundle.tar.gz | cut -f1))"
```

The bundle is ~70 MB and includes OpenClaw, the Vertex AI provider plugin, and the OTel diagnostics plugin.

## Demo runbook

Five-act progression: **locked down → Vertex AI enabled → Jira blocked → Jira granted → fully traced**, followed by a bonus Control UI section.

Total demo time: ~15 minutes.

---

### Before starting

1. Confirm the cluster is demo-ready (run the verification checklist in [`../opencode/docs/cluster-prep.md`](../opencode/docs/cluster-prep.md)).
2. Open two terminal windows side by side:
   - **Terminal 1** (left): OpenShell CLI commands
   - **Terminal 2** (right): sandbox exec commands and output
3. Have a browser tab ready for the MLflow UI and another for the OpenClaw Control UI.
4. Start the port-forward in Terminal 1 (keep running throughout):

```bash
oc -n openshell port-forward svc/openshell 8080:8080 &
openshell gateway list   # verify "openshift" is connected
```

If the port-forward dies mid-demo (commands hang or return "connection refused"), restart it:

```bash
pkill -f "port-forward svc/openshell"
oc -n openshell port-forward svc/openshell 8080:8080 &
```

5. Set environment variables in Terminal 1 (fish syntax shown; for bash use `export` and `$()`):

```fish
set -x PATH $HOME/bin $PATH
set MLFLOW_ROUTE (oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
set OC_TOKEN (oc whoami -t)
cd ~/projects/redhat/openshell-demos/openclaw
```

6. Set your Jira API token:

```fish
set -x JIRA_API_TOKEN "your-jira-api-token-here"
```

7. Verify the bundle exists:

```bash
ls -lh /tmp/openclaw-sandbox-bundle.tar.gz   # ~70 MB
```

---

### Act 1: Create the sandbox (show default-deny)

**Say:** "We're creating a sandboxed environment for our AI agent runtime — OpenClaw. Everything starts locked down — no network egress at all."

```fish
openshell sandbox create \
  --name openclaw-demo \
  --env GOOGLE_CLOUD_PROJECT=itpc-gcp-ai-eng-claude \
  --env GOOGLE_CLOUD_LOCATION=us-east5 \
  --env GOOGLE_APPLICATION_CREDENTIALS=/sandbox/.gcloud/adc.json \
  --env JIRA_URL=https://redhat.atlassian.net \
  --env JIRA_USERNAME=mschimun@redhat.com \
  --env "JIRA_API_TOKEN=$JIRA_API_TOKEN" \
  --env "MLFLOW_TRACKING_URI=https://$MLFLOW_ROUTE" \
  --env "MLFLOW_TRACKING_TOKEN=$OC_TOKEN" \
  --env MLFLOW_EXPERIMENT_ID=3 \
  --env MLFLOW_WORKSPACE=default \
  --env MLFLOW_TRACKING_INSECURE_TLS=true \
  --env "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://$MLFLOW_ROUTE/v1/traces" \
  --env "OTEL_EXPORTER_OTLP_TRACES_HEADERS=x-mlflow-experiment-id=3,Authorization=Bearer $OC_TOKEN,X-MLflow-Workspace=default" \
  --env OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf \
  --env NODE_TLS_REJECT_UNAUTHORIZED=0 \
  --upload ~/.config/gcloud/application_default_credentials.json:/sandbox/.gcloud/adc.json
```

Wait for `Ready`. Then confirm with `openshell sandbox list`.

Show the cluster:

```bash
oc -n openshell get pods
```

Both the `opencode-demo` and `openclaw-demo` sandbox pods are visible alongside the gateway and PostgreSQL pods.

**Talking point:** "The sandbox is running but completely isolated. No process inside can reach any external service. This is a different sandbox from the OpenCode one we saw earlier — both run on the same OpenShell gateway with independent policies."

---

### Act 2: Upload OpenClaw and show default-deny

Upload the pre-built bundle, config, and OTel preload script:

```bash
openshell sandbox upload openclaw-demo /tmp/openclaw-sandbox-bundle.tar.gz /sandbox/
openshell sandbox upload openclaw-demo config/openclaw.json /sandbox/.openclaw/openclaw.json
openshell sandbox upload openclaw-demo config/otel-fetch-setup.cjs /sandbox/otel-fetch-setup.cjs
openshell sandbox upload openclaw-demo start-gateway.sh /sandbox/start-gateway.sh
```

Extract the bundle and install the Jira MCP server:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c 'cd /sandbox && tar xzf openclaw-sandbox-bundle.tar.gz && rm openclaw-sandbox-bundle.tar.gz'
openshell sandbox exec -n openclaw-demo -- bash -c 'chmod +x /sandbox/start-gateway.sh'
openshell sandbox exec -n openclaw-demo -- bash -c 'export PATH="/sandbox/.local/bin:$PATH"; uv tool install mcp-atlassian'
```

Clean stale session data from the bundle:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c 'rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/ /sandbox/.openclaw/devices/ /sandbox/.openclaw/identity/'
```

Try running OpenClaw — it fails because egress is blocked:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/sandbox/node_modules/.bin:/sandbox/.local/bin:$PATH"
  export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
  openclaw agent --local --agent main \
    --model anthropic-vertex/claude-opus-4-6 \
    --message "Say hello" --timeout 30 2>&1'
```

**Talking point:** "Default-deny in action. The agent tried to call Vertex AI but every outbound connection was blocked."

---

### Act 3: Grant Vertex AI access and run OpenClaw

**Say:** "Now we selectively open access to Vertex AI. Only the Node.js process — OpenClaw's runtime — can reach these endpoints."

**Terminal 1:**

```bash
openshell pol set --policy policies/act2-vertex.yaml openclaw-demo --wait
```

Point out:

1. The `binaries` field: only `/usr/bin/node` (OpenClaw's runtime) gets network access.
2. Two Google endpoints: `us-east5-aiplatform.googleapis.com` (Vertex AI) and `oauth2.googleapis.com` (ADC token exchange).
3. Also includes `registry.npmjs.org` and `opencode.ai` — required for OpenClaw's plugin system to resolve dependencies at startup.

**Terminal 2 — run OpenClaw:**

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/sandbox/node_modules/.bin:/sandbox/.local/bin:$PATH"
  export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
  rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/
  openclaw agent --local --agent main \
    --model anthropic-vertex/claude-opus-4-6 \
    --message "What is the capital of France? Answer in one sentence." \
    --timeout 60 2>&1'
```

Claude responds via Vertex AI. The agent can reason, but Jira and MLflow are still blocked.

---

### Act 4: Show Jira blocked, then grant access

**Say:** "Let's ask the agent to query Jira. Watch what happens — the Jira MCP server runs as a Python subprocess, and Python has no network access yet."

Run with a Jira query:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/sandbox/node_modules/.bin:/sandbox/.local/bin:$PATH"
  export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
  rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/
  openclaw agent --local --agent main \
    --model anthropic-vertex/claude-opus-4-6 \
    --message "Search Jira for the most recent issue in the OPENSHELL project and tell me its key and summary." \
    --timeout 120 2>&1'
```

**Expected:** The Jira MCP call fails with a connection error.

*Pause for effect.* This is the key demo moment.

**Talking point:** "The agent tried to query Jira through MCP but was blocked. We gave it Vertex AI access, but nothing else. The Python binary running the Jira MCP server has no network permissions. Default-deny applies per-binary."

Now grant Jira access:

**Terminal 1:**

```bash
openshell pol set --policy policies/act4-jira.yaml openclaw-demo --wait
```

Point out the diff: we added `jira` scoped to the Python binary (`/sandbox/.uv/python/**`), and `pypi` so `uv` can install `mcp-atlassian` dependencies. Node.js still can't reach Jira. Python can't reach Vertex AI.

**Run the same question again:**

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/sandbox/node_modules/.bin:/sandbox/.local/bin:$PATH"
  export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
  rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/
  openclaw agent --local --agent main \
    --model anthropic-vertex/claude-opus-4-6 \
    --message "Search Jira for the most recent issue in the OPENSHELL project and tell me its key and summary." \
    --timeout 120 2>&1'
```

**Expected:** Jira MCP call succeeds. The agent retrieves issue data.

**Talking point:** "Same question, same agent, but now it works. Each endpoint rule is scoped to the exact executable that needs it."

---

### Act 5: Add MLflow tracing (full observability)

**Say:** "The agent is working, but we have no visibility into what it's doing. Let's add observability."

**Terminal 1:**

```bash
openshell pol set --policy policies/act5-mlflow.yaml openclaw-demo --wait
```

**Terminal 2 — run OpenClaw with a question:**

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/sandbox/node_modules/.bin:/sandbox/.local/bin:$PATH"
  export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
  rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/
  openclaw agent --local --agent main \
    --model anthropic-vertex/claude-opus-4-6 \
    --message "What are the top 3 programming languages in 2026?" \
    --timeout 60 2>&1'
```

**Switch to browser — open the MLflow UI:**

1. Navigate to `https://rh-ai.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com/mlflow/`
2. Log in with your OpenShift credentials when the RHOAI OAuth screen appears
3. Select the **default** workspace
4. Click **Experiments** → **opencode-demo** (both demos share the same experiment)
5. Click **Traces** under Observability
6. Click a trace row to show the span breakdown: LLM calls, model name, token counts, timing

Or verify via API:

```bash
curl -sk "https://$MLFLOW_ROUTE/api/2.0/mlflow/traces?experiment_ids=3&max_results=10" \
  -H "Authorization: Bearer $OC_TOKEN" \
  -H "X-MLflow-Workspace: default"
```

**Talking point:** "Every agent action is traced end-to-end. You see the Vertex AI calls with model, token usage, and latency. The traces come from both OpenCode and OpenClaw sandboxes into the same MLflow experiment — same observability plane for different agent runtimes."

---

### Bonus: OpenClaw Control UI with OpenShift OAuth

**Say:** "OpenClaw also has a built-in web dashboard. We can expose it through OpenShift's OAuth, so users authenticate with the same identity they use for the console."

#### Step 1: Start the OpenClaw gateway daemon

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  nohup /sandbox/start-gateway.sh > /sandbox/gw.log 2>&1 &
  echo "Gateway PID: $!"'

# Wait ~10s for startup, then verify
openshell sandbox exec -n openclaw-demo -- tail -3 /sandbox/gw.log
```

You should see `[gateway] ready` in the log.

#### Step 2: Register the service with OpenShell

```bash
openshell service expose openclaw-demo 19001 openclaw-ui
```

This tells the OpenShell gateway to route traffic for the `openclaw-ui` service name to port 19001 inside the sandbox.

#### Step 3: Deploy the OAuth proxy

```bash
oc apply -f k8s/openclaw-oauth-proxy.yaml
oc -n openshell rollout status deployment/openclaw-oauth-proxy
```

This creates:
- A **ServiceAccount** configured as an OpenShift OAuth client
- An **nginx sidecar** that rewrites the `Host` header for OpenShell's internal routing
- An **OAuth proxy** that authenticates users via the OpenShift IdP
- A **Route** at `openclaw-ui-openshell.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com`

#### Step 4: First-time device pairing

Open the URL in a browser:

```
https://openclaw-ui-openshell.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com
```

1. You'll be redirected to the OpenShift login page. Log in with your cluster credentials.
2. The OpenClaw Control UI loads. Enter the password `demo` and click **Connect**.
3. On first connection, OpenClaw requires device pairing approval. Note the request ID shown in the UI.
4. Approve the device from inside the sandbox:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  export PATH="/usr/bin:/sandbox/node_modules/.bin:$PATH"
  python3 -c "
import json, time
with open(\"/sandbox/.openclaw/devices/pending.json\") as f:
    pending = json.load(f)
with open(\"/sandbox/.openclaw/devices/paired.json\") as f:
    paired = json.load(f)
now_ms = int(time.time() * 1000)
scopes = [\"operator.admin\",\"operator.read\",\"operator.write\",\"operator.approvals\",\"operator.pairing\"]
for rid, req in list(pending.items()):
    did = req[\"deviceId\"]
    paired[did] = {\"deviceId\":did,\"publicKey\":req[\"publicKey\"],\"platform\":req[\"platform\"],
        \"clientId\":req[\"clientId\"],\"clientMode\":req[\"clientMode\"],\"role\":\"operator\",
        \"roles\":[\"operator\"],\"scopes\":scopes,\"approvedScopes\":scopes,
        \"approvedAtMs\":now_ms,\"createdAtMs\":now_ms,\"lastSeenAtMs\":now_ms,
        \"lastSeenReason\":\"connect\",\"tokens\":{\"operator\":{\"role\":\"operator\",\"scopes\":scopes,\"createdAtMs\":now_ms}}}
    print(f\"Approved: {req['clientId']}\")
pending.clear()
with open(\"/sandbox/.openclaw/devices/paired.json\",\"w\") as f:
    json.dump(paired, f, indent=2)
with open(\"/sandbox/.openclaw/devices/pending.json\",\"w\") as f:
    json.dump(pending, f)
"'
```

5. Restart the gateway to load the approved devices:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c '
  killall node 2>/dev/null; sleep 3
  rm -f /sandbox/.openclaw/gateway.lock
  nohup /sandbox/start-gateway.sh > /sandbox/gw.log 2>&1 &
  echo "Restarted. PID: $!"'
```

6. Click **Connect** again in the browser. The dashboard connects without re-pairing.

After the first pairing, the device stays approved across gateway restarts — the pairing state is persisted in `/sandbox/.openclaw/devices/paired.json`.

#### How the proxy chain works

```
Browser → OpenShift Route (TLS)
  → OAuth Proxy (authenticates via OpenShift IdP)
    → nginx sidecar (rewrites Host header)
      → OpenShell Gateway (port 8080, in-cluster)
        → OpenShell service proxy → OpenClaw gateway (sandbox port 19001)
```

The nginx sidecar rewrites the `Host` header from the external route hostname to `default--openclaw-demo--openclaw-ui.openshell.localhost`, which the OpenShell gateway uses to route traffic to the correct sandbox service. WebSocket connections (used by the Control UI) are fully supported.

---

### Reset (after demo or before re-run)

```bash
./reset-demo.sh
```

Deletes the sandbox, clears MLflow traces, and removes OAuth proxy resources. Infrastructure stays intact.

---

## How the tracing works

OpenClaw's built-in `diagnostics-otel` plugin doesn't start its OTel SDK in `--local` agent mode. To work around this, we use a Node.js preload script (`config/otel-fetch-setup.cjs`) loaded via `NODE_OPTIONS="--require ..."`:

1. Creates an OTel `BasicTracerProvider` with a custom exporter
2. The custom exporter serializes spans as protobuf and sends them via `fetch()` (proxy-aware in the sandbox, unlike `http.request()` which fails at DNS)
3. Wraps `globalThis.fetch()` to detect Vertex AI API calls and create `gen_ai.chat` spans with model, token usage, and latency attributes
4. Registers a `beforeExit` handler to flush remaining spans

The preload uses OTel libraries already installed by the `diagnostics-otel` plugin — no extra dependencies needed.

## Recovery procedures

See [`../opencode/docs/troubleshooting.md`](../opencode/docs/troubleshooting.md) for common issues (port-forward drops, token expiration, MLflow access).

### OpenClaw-specific issues

**OpenClaw `EACCES: permission denied, mkdir '/private'`**: Stale session data from macOS bundle creation. Clean it:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c 'rm -rf /sandbox/.openclaw/agents/ /sandbox/.openclaw/workspace/ /sandbox/.openclaw/workspace-attestations/ /sandbox/.openclaw/state/'
```

**Jira MCP `DNS resolution error`**: The `mcp-atlassian` Python process can't resolve external hostnames directly. The proxy environment variables in `openclaw.json` route traffic through the sandbox's transparent proxy. If you see this, verify the `mcp.servers.jira.env` block includes `HTTP_PROXY` and `HTTPS_PROXY` set to `http://10.200.0.1:3128`.

**Gateway port conflict**: If the gateway won't start because port 19001 is in use, kill the old process:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c 'killall node 2>/dev/null; sleep 3; rm -f /sandbox/.openclaw/gateway.lock'
```

**Device pairing loop**: If the UI keeps asking for device approval after restart, delete device state and restart:

```bash
openshell sandbox exec -n openclaw-demo -- bash -c 'rm -rf /sandbox/.openclaw/devices/ /sandbox/.openclaw/identity/'
```

Then restart the gateway and re-approve from the UI.

## Repo contents

```
├── README.md                       # This file (demo runbook)
├── reset-demo.sh                   # Deletes sandbox + OAuth proxy + clears traces
├── start-gateway.sh                # Gateway startup script (uploaded to sandbox)
├── .env.example                    # Template for credentials (committed)
├── config/
│   ├── openclaw.json               # OpenClaw config (plugins, MCP, gateway auth)
│   └── otel-fetch-setup.cjs        # Node.js preload for fetch-based OTel export
├── policies/
│   ├── act2-vertex.yaml            # Vertex AI only
│   ├── act4-jira.yaml              # + Jira + PyPI
│   └── act5-mlflow.yaml            # + MLflow tracing
└── k8s/
    └── openclaw-oauth-proxy.yaml   # OAuth proxy + nginx + Route manifests
```
