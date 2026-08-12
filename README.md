# OpenShell demos

Live demos of AI agents running inside OpenShell sandboxes on OpenShift with progressive network policy enforcement, Vertex AI inference, Jira MCP integration, and MLflow tracing.

Each demo runs in its own sandbox on the same OpenShell gateway — both can operate in parallel without conflicts.

## Demos

| Demo | Agent | What it shows |
|------|-------|---------------|
| [**OpenCode**](opencode/) | OpenCode (TypeScript coding agent) | Interactive terminal agent with Vertex AI, Jira MCP, MLflow tracing |
| [**OpenClaw**](openclaw/) | OpenClaw (AI agent runtime with web UI) | Headless agent exec + browser-accessible Control UI via OpenShift OAuth |

## Shared infrastructure

Both demos share:

- **OpenShell gateway** — deployed once via Helm on OpenShift
- **RHOAI / MLflow** — single MLflow instance for trace collection
- **Vertex AI** — same GCP project and ADC credentials
- **Jira MCP** — same Atlassian API token

See [`opencode/docs/cluster-prep.md`](opencode/docs/cluster-prep.md) for the full cluster setup procedure.

## Running both in parallel

Both sandboxes (`opencode-demo` and `openclaw-demo`) can run simultaneously on the same OpenShell gateway. Each has its own:

- Network policies (independent per-sandbox)
- Filesystem (isolated containers)
- Process namespace (separate enforcement)

```bash
openshell sandbox list   # shows both sandboxes
oc -n openshell get pods # shows both sandbox pods + gateway + postgresql
```

## Quick start

1. Prepare the cluster: follow [`opencode/docs/cluster-prep.md`](opencode/docs/cluster-prep.md)
2. Pick a demo and follow its README
3. To reset: run `./reset-demo.sh` inside the demo directory

## Repo structure

```
├── README.md                  # This file
├── .env.example               # Shared credential template
├── opencode/
│   ├── README.md              # OpenCode demo runbook
│   ├── config/                # OpenCode config files
│   ├── policies/              # Network policies (3 acts)
│   ├── docs/                  # Cluster prep, troubleshooting, concepts
│   ├── create-sandbox.sh      # Script-based sandbox creation
│   └── reset-demo.sh          # Reset for this demo
└── openclaw/
    ├── README.md              # OpenClaw demo runbook
    ├── config/                # OpenClaw config + OTel preload
    ├── policies/              # Network policies (3 acts)
    ├── k8s/                   # OAuth proxy manifests
    ├── start-gateway.sh       # Gateway startup (uploaded to sandbox)
    └── reset-demo.sh          # Reset for this demo
```
