# OpenShell concepts cheatsheet

Quick reference for explaining OpenShell concepts during customer demos.

## TUI panels

### Gateway

The gateway is OpenShell's control plane. It manages sandbox lifecycle, policy enforcement, and credential routing. It runs as a server (pod on OpenShift, container on Docker/Podman, or a local process) and exposes a gRPC API that the CLI talks to.

- `local` type means the CLI connects via port-forward or direct endpoint.
- `user` source means a human registered it (vs. automation or operator-provisioned).
- `Healthy` means the gateway is running and accepting commands.

### Providers

Providers are centrally managed LLM credential backends. Instead of injecting raw API keys into sandboxes, you register a provider (OpenAI, Anthropic, Vertex AI, Azure, RHOAI vLLM, etc.) and OpenShell handles credential injection and rotation. Sandboxes reference providers by name — they never see raw keys.

### Sandboxes

Sandboxes are isolated containers where agents run. Each sandbox gets its own filesystem, network namespace, and policy enforcement layer. They start completely locked down (default-deny networking) and you selectively grant access to specific endpoints for specific binaries.

## Gateway vs. Operator

| | Gateway | Operator |
|---|---------|----------|
| **What it is** | A running server (control plane) that manages sandboxes | A Kubernetes controller that manages gateway lifecycle |
| **Scope** | One gateway manages sandboxes on its compute backend | The operator deploys and reconciles gateway instances |
| **Analogy** | The database server | The DBA who installs and upgrades database servers |
| **When you interact** | Every time you create/delete sandboxes, set policies | Only during install, upgrade, or cluster configuration |

The operator watches `Gateway` CRDs and ensures the gateway pods are running, configured, and healthy. You don't interact with the operator during normal sandbox operations.

### Why multiple gateways?

- **Team isolation** — each team gets its own gateway with separate sandboxes, policies, and provider credentials.
- **Environment separation** — dev, staging, and production gateways on the same cluster or across clusters.
- **Compute backend diversity** — one gateway on Kubernetes (for production workloads), another on Docker (for local development), a third using VM isolation (for untrusted code).
- **Geographic distribution** — gateways in different regions closer to the LLM endpoints they use.

The CLI can register multiple gateways and switch between them with `openshell gateway select <name>`.

## ADC (Application Default Credentials)

Google Cloud's standard way for applications to authenticate without hardcoding API keys.

1. You run `gcloud auth application-default login` on your laptop — saves a credential file at `~/.config/gcloud/application_default_credentials.json`.
2. We upload that file into the sandbox at `/sandbox/.gcloud/adc.json`.
3. The `GOOGLE_APPLICATION_CREDENTIALS` env var tells the Google AI SDK where to find it.
4. When OpenCode calls Vertex AI, the SDK reads that file, exchanges it for a short-lived access token via `oauth2.googleapis.com`, then calls `aiplatform.googleapis.com` with that token.

That's why the network policy needs both `aiplatform.googleapis.com` (LLM inference) and `oauth2.googleapis.com` (token exchange).

**If the customer asks:** "We use Google's standard Application Default Credentials. The sandbox has a credential file that gets exchanged for short-lived tokens automatically — the agent never handles raw API keys for the LLM."

## Common CLI examples

### Add a provider

```bash
# Register an OpenAI provider
openshell provider create openai \
  --type openai \
  --credential-key OPENAI_API_KEY

# Register a Vertex AI provider
openshell provider create vertex \
  --type google-vertex \
  --credential-key GOOGLE_APPLICATION_CREDENTIALS

# Register a local vLLM/RHOAI model server
openshell provider create rhoai-llama \
  --type openai-compatible \
  --base-url https://llama-serving.apps.cluster.example.com/v1 \
  --credential-key RHOAI_TOKEN
```

After registering, sandboxes can reference the provider by name instead of managing raw credentials.

## How providers protect credentials

Providers don't just swap placeholder keys for real ones — they keep the real key **outside the sandbox entirely**.

1. The real API key is stored on the **gateway** (control plane), never inside the sandbox.
2. The agent makes LLM requests with no credentials (or a placeholder).
3. OpenShell's **network supervisor** intercepts the outbound request at the proxy layer and injects the real credential before forwarding to the LLM endpoint.
4. The agent never sees the real key — not in the filesystem, not in env vars, not in process memory.

Even if the agent is compromised or tries to exfiltrate credentials, there's nothing to steal.

### What about MCP and other service tokens?

Today, providers handle **LLM inference credentials** only. Non-LLM service tokens (Jira, GitHub, Slack, etc.) are passed as environment variables directly into the sandbox, which means the agent can see them.

In our demo, that's why we pass `JIRA_API_TOKEN` as an `--env` flag — there's no provider abstraction for MCP credentials yet. Extending the provider model to arbitrary service credentials is a natural evolution of the platform.
