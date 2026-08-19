# SAW + OpenClaw demo on OpenShift

Live demo: OpenClaw running inside a SAW (Secure Agent Workspace) sandbox on OpenShift, with KubeVirt VM-level isolation, Gemini inference via Google AI API, and egress-controlled networking.

SAW wraps OpenShell in a full VM boundary — the gateway and sandbox containers run inside a KubeVirt virtual machine, adding hardware-level isolation on top of OpenShell's container sandbox model.

Tested on: bare-metal OpenShift 4.22 from demo.redhat.com, SAW `validatedpatterns-sandbox/secure-agent-workspace` (Aug 2026), OpenClaw 2026.6.34, Gemini 3.6 Flash.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  OpenShift (bare metal, KubeVirt enabled)                               │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  KubeVirt VM (Fedora)                                            │    │
│  │                                                                  │    │
│  │  ┌──────────────┐   ┌──────────────────────────────────────┐     │    │
│  │  │ OpenShell    │   │ Sandbox container (openclaw-test)     │     │    │
│  │  │ Gateway      │──▶│  ┌──────────┐                        │     │    │
│  │  │ (supervisor) │   │  │ OpenClaw │  Egress proxy controls │     │    │
│  │  └──────────────┘   │  │ (Node.js)│  per-binary access     │     │    │
│  │                     │  └────┬─────┘                        │     │    │
│  │  Keycloak (RHBK)    │       │                              │     │    │
│  │  OIDC IdP for       └───────┼──────────────────────────────┘     │    │
│  │  workspace auth             │                                    │    │
│  └─────────────────────────────┼────────────────────────────────────┘    │
│                                │                                         │
└────────────────────────────────┼─────────────────────────────────────────┘
                                 │
                    ┌────────────▼──────────┐
                    │ Google AI API         │
                    │ (Gemini 3.6 Flash)    │
                    │ generativelanguage.   │
                    │ googleapis.com        │
                    └───────────────────────┘
```

**Key difference from the standard OpenClaw demo:** SAW adds a KubeVirt VM layer around the gateway and sandboxes. The agent container runs inside a VM, not directly as a pod. This gives hardware-level isolation (separate kernel, memory, filesystem) in addition to the container-level sandbox.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `oc` | 4.22+ | `brew install openshift-cli` |
| `virtctl` | Matches cluster KubeVirt | Download from `ConsoleCLIDownload` resource (see below) |
| `helm` | 3.x | `brew install helm` |

**Cluster requirements:**

- **Bare-metal** OpenShift 4.22+ — ROSA does not support KubeVirt (no nested virtualization). Order from [demo.redhat.com](https://catalog.demo.redhat.com/catalog/all?search=Red+Hat+OpenShift+Container+Platform+Cluster+%28Multi-Cloud%29&item=babylon-catalog-prod%2Fpublished.ocp4-cluster.prod): OCP 4.22, multi-node, 2 workers, 8 CPU, 32 GB memory.
- **KubeVirt / OpenShift Virtualization** installed (SAW depends on it).
- **RHBK (Red Hat Build of Keycloak)** operator installed (SAW deploys a Keycloak realm for OIDC).

Credentials needed:

- Cluster admin access
- Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey) — Red Hat employees have access through Google Workspace integration

Install `virtctl` from the cluster:

```bash
VKC_URL=$(oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged \
  -o jsonpath='{range .spec.links[*]}{.href}{"\n"}{end}' | grep darwin-amd64)
curl -sL "$VKC_URL" | tar xz -C /usr/local/bin virtctl
```

## Demo runbook

Four-act progression: **deploy SAW VM → configure inference (workaround) → verify OpenClaw → enable Control UI**, followed by a teardown.

Total demo time: ~25 minutes (VM startup takes ~5 min).

---

### Before starting

1. Log into the cluster:

```bash
oc login --server="$OCP_API" -u "$OCP_USER" -p "$OCP_PASSWORD"
```

2. Clone the SAW repo:

```bash
git clone https://github.com/validatedpatterns-sandbox/secure-agent-workspace.git
cd secure-agent-workspace
```

3. Copy `.env.example` from this demo directory and fill in values:

```bash
cp saw-openclaw/.env.example saw-openclaw/.env
source saw-openclaw/.env
```

---

### Act 1: Deploy the SAW sandbox VM

**Say:** "SAW provisions isolated agent environments as KubeVirt VMs. Each VM runs its own OpenShell gateway and sandbox containers inside a full virtual machine — separate kernel, memory, network stack."

Run SAW's prerequisite checks:

```bash
cd secure-agent-workspace
make check-prereqs
```

Copy required images to the OpenShift internal registry and set up the Keycloak OIDC issuer:

```bash
make copy-images
make keycloak-issuer
```

Generate SSH keys for VM access:

```bash
ssh-keygen -t ed25519 -f /tmp/saw-demo-key -N '' -C saw-demo
```

Create the `values-secret.yaml` that SAW needs:

```bash
cat > ~/values-secret.yaml << 'EOF'
secrets:
  - name: ssh-keys
    fields:
    - name: ssh_pub_key
      path: /tmp/saw-demo-key.pub
    - name: ssh_priv_key
      path: /tmp/saw-demo-key
  - name: inference
    fields:
    - name: provider
      value: gemini
    - name: model
      value: gemini-3.6-flash
    - name: api_key
      value: YOUR_GEMINI_API_KEY
EOF
```

Deploy the sandbox VM with governance disabled (the governance interceptor is not yet available for standalone SAW deployments, and the gateway crashes on startup with `fail_closed` if it can't connect):

```bash
make openshell-saw-create OWNER=alice GOVERNANCE_ENABLED=false
```

Wait for the VM to become ready (~5 minutes):

```bash
oc -n "$SAW_NAMESPACE" get vm -w
```

Once the VM shows `Running`, verify SSH access:

```bash
SSH_KEY="/tmp/saw-demo-key"
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell sandbox list"
```

You should see a sandbox (e.g., `openclaw-test`) in `Ready` or `Creating` state.

**Talking point:** "The VM is running, the gateway started, and our sandbox container is live. All of this — gateway, sandbox, container runtime — lives inside a single KubeVirt VM. That VM is the trust boundary."

---

### Act 2: Configure inference (workaround)

**Say:** "SAW normally configures inference automatically via `nemoclaw onboard`, but the current release has a dependency issue — it tries to install a version of the `openshell` CLI that doesn't exist on PyPI. We'll do the setup manually."

The `configure-inference.sh` script performs the steps that `nemoclaw onboard` would do:

1. Gets an OIDC token from the SAW-deployed Keycloak (user `alice`/`alice`)
2. Grants workspace access to the `openshell-client` service
3. Updates the sandbox network policy to allow `generativelanguage.googleapis.com:443`
4. Writes the OpenClaw model configuration to use Gemini directly

```bash
cd /path/to/openshell-demos
source saw-openclaw/.env
./saw-openclaw/configure-inference.sh
```

Verify the sandbox policy was updated:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell pol get $SAW_SANDBOX_NAME"
```

You should see `generativelanguage.googleapis.com:443` in the allowed endpoints for the `/usr/bin/node` binary.

**Talking point:** "We added exactly one egress rule — only Node.js can reach the Gemini API endpoint. Everything else stays blocked. SAW's egress proxy enforces this at the network layer per binary."

---

### Act 3: Verify OpenClaw inference

**Say:** "Now let's verify that OpenClaw can reason inside the SAW sandbox — it's running in a container, inside a VM, with egress locked down to a single API endpoint."

Run a simple Q&A test:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \
    openclaw infer model run \
      --model google/$GEMINI_MODEL \
      --prompt 'What is the capital of France? Answer in one sentence.' \
      --no-color"
```

**Expected:** Gemini responds with the correct answer.

Run a code generation test:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \
    openclaw infer model run \
      --model google/$GEMINI_MODEL \
      --prompt 'Write a Python function that checks if a number is prime. Return only the code.' \
      --no-color"
```

Run a reasoning test:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \
    openclaw infer model run \
      --model google/$GEMINI_MODEL \
      --prompt 'A farmer has 17 sheep. All but 9 die. How many are left? Show your reasoning.' \
      --no-color"
```

**Talking point:** "OpenClaw is running inference through Gemini inside a SAW sandbox — that's a container inside a VM inside OpenShift. Three layers of isolation, and the agent works exactly as expected."

---

### Act 4: Enable the OpenClaw Control UI

**Say:** "OpenClaw has a built-in web dashboard — the Control UI. We can expose it through the SAW route so users can interact with the agent from a browser."

The OpenClaw gateway needs additional egress endpoints during startup for plugin resolution and model registry checks:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="openshell policy update $SAW_SANDBOX_NAME \
    --add-endpoint 'raw.githubusercontent.com:443:read-write:rest:enforce' \
    --add-endpoint 'openrouter.ai:443:read-write:rest:enforce' \
    --add-endpoint 'registry.npmjs.org:443:read-write:rest:enforce' \
    --binary /usr/local/bin/node \
    --binary /usr/bin/node \
    --wait"
```

Configure the OpenClaw gateway with an auth token and the dashboard route as allowed origin, then start it:

```bash
DASHBOARD_ROUTE=$(oc get route ${SAW_VM_NAME}-dashboard -n "$SAW_NAMESPACE" \
  -o jsonpath='{.spec.host}')
OPENCLAW_TOKEN=$(openssl rand -hex 16)
echo "Dashboard URL: https://$DASHBOARD_ROUTE"
echo "Token: $OPENCLAW_TOKEN"

virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="
openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \
  node -e \"
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('/sandbox/.openclaw/openclaw.json', 'utf8'));
    if (!cfg.gateway) cfg.gateway = {};
    if (!cfg.gateway.auth) cfg.gateway.auth = {};
    cfg.gateway.auth.token = '$OPENCLAW_TOKEN';
    if (!cfg.gateway.controlUi) cfg.gateway.controlUi = {};
    cfg.gateway.controlUi.allowedOrigins = ['https://$DASHBOARD_ROUTE'];
    if (!cfg.models) cfg.models = {};
    cfg.models.mode = 'replace';
    fs.writeFileSync('/sandbox/.openclaw/openclaw.json', JSON.stringify(cfg, null, 2));
    console.log('Config updated');
  \"

openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- sh -c \
  'nohup openclaw gateway run --bind lan --port 18789 > /tmp/openclaw-gateway.log 2>&1 &'
"
```

Wait ~15 seconds for the gateway to start, then register the service with the OpenShell gateway and verify:

```bash
sleep 15
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="
openshell service expose $SAW_SANDBOX_NAME 18789 openclaw-dashboard
openshell sandbox exec -n $SAW_SANDBOX_NAME --no-tty -- \
  tail -5 /tmp/openclaw-gateway.log
"
```

You should see `[gateway] ready` in the log.

The sandbox port 18789 is in a nested network namespace — the route can't reach it directly. Install nginx on the VM as a reverse proxy:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command='
sudo dnf install -y nginx 2>&1 | tail -3

sudo tee /etc/nginx/conf.d/openclaw-gateway.conf > /dev/null << NGEOF
server {
    listen 18789;
    server_name _;
    location / {
        proxy_pass https://127.0.0.1:17670;
        proxy_set_header Host default--'"$SAW_SANDBOX_NAME"'--openclaw-dashboard.openshell.localhost;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
NGEOF

sudo nginx -t && sudo nginx
ss -tlnp | grep 18789
'
```

Open `https://<dashboard-route>` in your browser and enter the gateway token when prompted.

**Talking point:** "The Control UI is served from inside the sandbox, through the OpenShell gateway's service proxy, through an nginx reverse proxy on the VM, through the OpenShift route. Every layer enforces its own access controls."

---

### Reset (after demo or before re-run)

```bash
source saw-openclaw/.env
./saw-openclaw/reset-demo.sh
```

Deletes all VMs, DataVolumes, Helm releases, Keycloak resources, and the namespace.

---

## Known issues and workarounds

### `nemoclaw onboard` fails — openshell CLI not on PyPI

The SAW setup job tries `pip install openshell==0.0.99+rhaiv.0` which does not exist on PyPI. The `configure-inference.sh` script works around this by manually performing the onboard steps.

**Impact:** Requires manual configuration after sandbox creation.

### Gateway crash-loop with governance enabled

The gateway expects a `governance-interceptor` sidecar. If it's not deployed and `GOVERNANCE_ENABLED=true` (the default), the gateway crashes with `fail_closed`.

**Workaround:** Deploy with `GOVERNANCE_ENABLED=false`.

### `gemini-2.5-flash` deprecated

Google deprecated the `gemini-2.5-flash` model. Requests return HTTP 404 with a deprecation notice.

**Fix:** Use `gemini-3.6-flash` (or later). The `.env.example` and `models.json` default to this.

### VM user is `cloud-user`, not `fedora`

The SAW VM image uses `cloud-user` as the default SSH user, not `fedora` as in some KubeVirt documentation.

### Image pull authentication

If the sandbox container fails to start with image pull errors, Docker inside the VM needs re-authentication to the OpenShift internal registry:

```bash
virtctl -n "$SAW_NAMESPACE" ssh \
  --identity-file="$SSH_KEY" \
  "cloud-user@vm/$SAW_VM_NAME" \
  --local-ssh-opts="-oStrictHostKeyChecking=no" \
  --command="docker login -u kubeadmin -p \$(oc whoami -t) \
    default-route-openshift-image-registry.apps.\$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')"
```

### OpenClaw gateway needs extra egress endpoints

The OpenClaw gateway tries to reach `raw.githubusercontent.com` and `openrouter.ai` on startup for plugin resolution and model registry checks. Without these egress rules, the gateway hangs at 100% CPU and never binds to its port.

**Fix:** Add egress rules for `raw.githubusercontent.com:443`, `openrouter.ai:443`, and `registry.npmjs.org:443` before starting the gateway (included in Act 4).

### Sandbox port 18789 not directly reachable from the VM

The sandbox runs in a nested network namespace inside a Docker container on a bridge network. Port 18789 (OpenClaw Control UI) is not accessible from the VM host even though `ss -tlnp` inside the sandbox shows it listening on `0.0.0.0:18789`.

**Fix:** Use `openshell service expose` to register the port, then run nginx on the VM as a reverse proxy that forwards through the OpenShell gateway's service proxy with the correct Host header (included in Act 4).

### TLS `UnknownIssuer` on sandbox auto-connect

The supervisor inside the sandbox uses self-signed certificates. `openshell sandbox exec` may log a TLS warning on first connection. This does not prevent command execution.

### OIDC token expiration

Keycloak tokens expire after a short TTL. If `openshell sandbox list` returns "ExpiredSignature", re-run the OIDC authentication step from `configure-inference.sh` or manually get a fresh token from Keycloak.

## Repo contents

```
├── README.md                  # This file (demo runbook)
├── .env.example               # Credential template
├── configure-inference.sh     # Manual inference setup (workaround)
├── reset-demo.sh              # Full teardown
└── config/
    └── models.json            # Gemini model configuration template
```

## References

- [SAW repository](https://github.com/validatedpatterns-sandbox/secure-agent-workspace/)
- [SAW deployment guide](https://github.com/validatedpatterns-sandbox/secure-agent-workspace/blob/main/docs/deployment.md)
- [demo.redhat.com bare-metal clusters](https://catalog.demo.redhat.com/)
- [Google AI Studio API keys](https://aistudio.google.com/apikey)
- [Jira Epic RHAIENG-7044](https://redhat.atlassian.net/browse/RHAIENG-7044)
