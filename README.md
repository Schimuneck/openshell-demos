# OpenCode-in-OpenShell demo on OpenShift

Live demo: OpenCode (AI coding agent) running inside an OpenShell sandbox on OpenShift, with Vertex AI inference, Jira MCP integration, and MLflow tracing via RHOAI.

Tested on: `mschimun-dev` ROSA cluster (OpenShift 4.19), OpenShell v0.0.97, RHOAI 3.4.2, MLflow 3.10.1.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  OpenShift (ROSA)                                            │
│                                                              │
│  ┌─────────────────┐   ┌──────────────────────────────────┐  │
│  │ OpenShell       │   │ OpenShell Sandbox                 │  │
│  │ Gateway         │──▶│  ┌────────────┐  ┌────────────┐  │  │
│  │ (control plane) │   │  │ OpenCode   │  │ Jira MCP   │  │  │
│  └─────────────────┘   │  │ (Node.js)  │  │ (Python)   │  │  │
│                        │  └──────┬─────┘  └──────┬─────┘  │  │
│  ┌─────────────────┐   │         │               │         │  │
│  │ RHOAI           │   │  Network policies control│        │  │
│  │ ├ MLflow        │◀──│  which binary can reach  │        │  │
│  │ ├ Dashboard     │   │  which endpoint          │        │  │
│  │ └ Gateway (OAuth│   │         │               │         │  │
│  └─────────────────┘   └─────────┼───────────────┼─────────┘  │
│                                  │               │            │
└──────────────────────────────────┼───────────────┼────────────┘
                                   │               │
                          ┌────────▼──┐    ┌───────▼────────┐
                          │ Vertex AI │    │ Jira           │
                          │ (Claude)  │    │ (Atlassian)    │
                          └───────────┘    └────────────────┘
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `oc` | 4.19+ | `brew install openshift-cli` |
| `openshell` | 0.0.97 | [GitHub release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.97) |
| `helm` | 3.x | `brew install helm` |
| `gcloud` | latest | `brew install google-cloud-sdk` |

Credentials needed:

- OpenShift cluster-admin token
- GCP project `itpc-gcp-ai-eng-claude` with Vertex AI API enabled
- `gcloud auth application-default login` completed
- Jira API token for `redhat.atlassian.net`

## Cluster preparation

See [docs/cluster-prep.md](docs/cluster-prep.md) for the full cluster setup procedure.

## Demo runbook

Five-act progression: **locked down → Vertex AI enabled → Jira blocked → Jira granted → fully traced**.

Total demo time: ~10 minutes.

---

### Before starting

1. Confirm the cluster is demo-ready (run the verification checklist in `docs/cluster-prep.md`).
2. Open two terminal windows side by side:
   - **Terminal 1** (left): OpenShell CLI commands
   - **Terminal 2** (right): will be the sandbox terminal
3. Have a browser tab ready for the MLflow UI (you'll open it in Act 5).
4. Start the port-forward in Terminal 1 (keep running throughout):

```bash
oc -n openshell port-forward svc/openshell 8080:8080 &
```

5. Set environment variables in Terminal 1:

```bash
export PATH="$HOME/bin:$PATH"
export MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
cd ~/projects/redhat/openshell-opencode-demo
```

6. Populate `.env` with your credentials (gitignored, never committed):

```bash
cp .env.example .env
# Edit .env with your Jira API token and experiment ID
```

7. Build the MLflow plugin bundle (if not already done):

```bash
cd /tmp && rm -rf mlflow-bundle && mkdir mlflow-bundle && cd mlflow-bundle
npm init -y > /dev/null
npm install @mlflow/opencode
tar czf /tmp/mlflow-node-modules.tar.gz node_modules/
```

---

### Act 1: Create the sandbox (show default-deny)

**Say:** "We're creating a sandboxed environment for our AI coding agent. Everything starts locked down — no network egress at all."

```bash
ENV_FLAGS=$(grep -v '^#' .env | grep '=' | sed 's/^/--env /' | tr '\n' ' ')
eval openshell sandbox create \
  --name opencode-demo \
  $ENV_FLAGS \
  --env "MLFLOW_TRACKING_URI=https://$MLFLOW_ROUTE" \
  --env "MLFLOW_TRACKING_TOKEN=$(oc whoami -t)" \
  --upload config/opencode.json:/sandbox/opencode.json \
  --upload ~/.config/gcloud/application_default_credentials.json:/sandbox/.gcloud/adc.json
```

Wait for `Ready`. Confirm with `openshell sandbox list`.

**Talking point:** "The sandbox is running but completely isolated. No process inside can reach any external service."

---

### Act 2: Grant Vertex AI access and launch OpenCode

**Say:** "Now we selectively open access to Vertex AI. Only the OpenCode process can reach these endpoints — nothing else."

**Terminal 1:**

```bash
openshell pol set --policy policies/act2-vertex.yaml opencode-demo
```

Point out the `binaries` field: only the OpenCode binary gets network access. Not curl, not wget, not any other process.

**Terminal 2 — connect and launch OpenCode:**

```bash
openshell sandbox connect opencode-demo
# Inside the sandbox:
opencode
```

Test with a simple prompt:

```
Say hello and tell me the current date
```

Claude responds via Vertex AI. The agent can reason, but it's the only external service it can reach.

---

### Act 3: Show Jira blocked (default-deny in action)

**Say:** "Let's ask the agent to query our Jira. Watch what happens."

Type in OpenCode:

```
What is AgentOps (RAG + Vector DB) team working on in Sprint 8 in RHAIENG in Jira?
```

**Expected:** The Jira MCP call **fails** with a connection error.

*Pause here for effect. This is the key demo moment.*

**Talking point:** "The agent tried to query Jira through MCP but was blocked. We gave it Vertex AI access for reasoning, but nothing else. The Jira endpoint isn't in the allowlist. This is default-deny — every endpoint must be explicitly granted."

---

### Act 4: Grant Jira access

**Say:** "Now we'll grant Jira access. Notice we specify the exact binary that needs it — the Python interpreter running mcp-atlassian."

**Terminal 1:**

```bash
openshell pol set --policy policies/act4-jira.yaml opencode-demo
```

Point out the diff: we added `jira` scoped to the Python binary, and `pypi` so uv can install mcp-atlassian. Node.js still can't reach Jira. Python can't reach Vertex AI.

**Back in OpenCode, ask the same question:**

```
What is AgentOps (RAG + Vector DB) team working on in Sprint 8 in RHAIENG in Jira?
```

**Expected:** Jira MCP call **succeeds**. The agent retrieves sprint items.

**Talking point:** "Same question, same agent, but now it works. We granted Jira access to the Python binary specifically. Each endpoint rule is scoped to the exact executable that needs it."

---

### Act 5: Add MLflow tracing (full observability)

**Say:** "The agent is working, but we have no visibility into what it's doing or what data it accessed. Let's add observability."

**Terminal 1:**

```bash
# Add MLflow network access
openshell pol set --policy policies/act5-mlflow.yaml opencode-demo

# Upload and extract MLflow plugin
openshell sandbox upload opencode-demo /tmp/mlflow-node-modules.tar.gz /sandbox/
openshell sandbox exec -n opencode-demo -- tar xzf /sandbox/mlflow-node-modules.tar.gz -C /sandbox/
```

**Terminal 2 — exit OpenCode (Ctrl+C) and restart with NODE_PATH:**

```bash
NODE_PATH=/sandbox/node_modules opencode
```

Ask a question to generate traces:

```
What is AgentOps (RAG + Vector DB) team working on in Sprint 8 in RHAIENG in Jira?
```

**Switch to the browser — open the MLflow UI:**

1. Navigate to `https://rh-ai.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com/mlflow/`
2. Log in with your OpenShift credentials when the RHOAI OAuth screen appears
3. Select the **default** workspace
4. Click **Experiments** → **opencode-demo**
5. Click **Traces** under Observability
6. Click a trace row to show the span breakdown: LLM calls, tool calls, token counts, timing

**Talking point:** "Every agent action is now traced end-to-end. You see the full reasoning chain: the query, the Jira tool call, the LLM response, and token usage. This gives operators complete visibility into what the agent did, what data it accessed, and how much compute it used."

---

### Cleanup (after demo)

```bash
openshell sandbox delete opencode-demo
```

Leave the cluster infrastructure running for re-runs.

---

## Recovery procedures

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Repo contents

```
├── README.md                  # This file (demo runbook)
├── .env.example               # Template for credentials (committed)
├── .env                       # Your credentials (gitignored)
├── config/
│   └── opencode.json          # OpenCode configuration
├── policies/
│   ├── act2-vertex.yaml       # Vertex AI only
│   ├── act4-jira.yaml         # + Jira + PyPI
│   └── act5-mlflow.yaml       # + MLflow tracing
└── docs/
    ├── cluster-prep.md        # Full cluster setup procedure
    └── troubleshooting.md     # Recovery and debugging
```
