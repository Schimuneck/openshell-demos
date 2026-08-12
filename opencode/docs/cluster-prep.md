# Cluster preparation

Step-by-step procedure to get the OpenShift cluster into a demo-ready state.

Tested on: `mschimun-dev` ROSA cluster (OpenShift 4.19), OpenShell v0.0.97, RHOAI 3.4.2, MLflow 3.10.1.

## Full cleanup (if restarting from scratch)

```bash
export PATH="$HOME/bin:$PATH"

pkill -f "port-forward svc/openshell" 2>/dev/null || true

oc -n openshell port-forward svc/openshell 8080:8080 &
sleep 3
openshell sandbox delete opencode-demo 2>/dev/null || true
kill %1 2>/dev/null

helm uninstall openshell -n openshell 2>/dev/null || true

oc -n openshell delete deployment/postgresql svc/postgresql pvc/postgres-pvc \
  secret/postgresql-credentials secret/pg-credentials 2>/dev/null || true

oc -n redhat-ods-applications delete route mlflow-api 2>/dev/null || true

oc adm policy remove-scc-from-user privileged -z openshell-sandbox -n openshell 2>/dev/null || true
oc delete ns openshell 2>/dev/null || true

kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox.yaml 2>/dev/null || true

openshell gateway remove openshift 2>/dev/null || true
```

## Step 1: Install Agent Sandbox CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox.yaml
oc -n agent-sandbox-system get pods   # wait for Running
```

## Step 2: Deploy PostgreSQL

```bash
oc create ns openshell
oc adm policy add-scc-to-user privileged -z openshell-sandbox -n openshell

cd /tmp && rm -rf agent-ops
git clone -b opencode-in-openshell-with-mlflow-on-openshift-demo \
  https://github.com/r3v5/agent-ops.git
cd agent-ops/demos/opencode-vertex-tracing

oc apply -f k8s/postgresql.yaml
oc -n openshell rollout status deployment/postgresql

kubectl create secret generic pg-credentials -n openshell \
  --from-literal=uri="postgresql://openshell:openshell@postgresql:5432/openshell"
```

## Step 3: Install OpenShell v0.0.97

```bash
helm install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.0.97 \
  --namespace openshell \
  --set workload.kind=deployment \
  --set server.externalDbSecret=pg-credentials \
  --set server.disableTls=true \
  --set podSecurityContext.fsGroup=null \
  --set securityContext.runAsUser=null \
  --set server.auth.allowUnauthenticatedUsers=true

oc -n openshell rollout status deployment/openshell
```

## Step 4: Register gateway

```bash
oc -n openshell port-forward svc/openshell 8080:8080 &
sleep 3
openshell gateway add http://127.0.0.1:8080 --local --name openshift
openshell gateway list   # verify "connected"
```

## Step 5: Install RHOAI and Service Mesh operators

The RHOAI dashboard requires the OpenShift Service Mesh operator (Istio) for the Data Science Gateway. Install both if not already present.

```bash
# Check current state
oc get csv --all-namespaces 2>&1 | grep rhods
oc get csv --all-namespaces 2>&1 | grep servicemesh

# If RHOAI is not installed, create subscription
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator (~60s)
watch 'oc get csv -n redhat-ods-operator | grep rhods'

# Verify Service Mesh is running (required for RHOAI dashboard gateway)
oc get csv -n openshift-operators | grep servicemesh
```

### Service Mesh operator stuck in UpgradePending

If the Service Mesh operator gets stuck in OLM's `replaces` chain (common when intermediate CSVs are missing), break the deadlock:

```bash
oc delete csv servicemeshoperator3.v3.1.0 -n openshift-operators 2>/dev/null
oc patch csv servicemeshoperator3.v3.3.6 -n openshift-operators \
  --type=json -p '[{"op":"remove","path":"/spec/replaces"}]'
watch 'oc get csv -n openshift-operators | grep servicemesh'
```

## Step 6: Deploy MLflow tracking server

```bash
# Create DataScienceCluster with MLflow operator AND dashboard.
# Dashboard + Data Science Gateway provide OAuth-authenticated browser access.
cat <<'EOF' | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    mlflowoperator:
      managementState: Managed
EOF

# Wait for DSC to be Ready
watch 'oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}"'

# Create MLflow tracking server.
# defaultArtifactRoot MUST be "mlflow-artifacts:/" (not "file:///").
# The @mlflow/core SDK interprets file:// URIs as local paths and tries to
# mkdir inside the sandbox, which fails because / is read-only.
cat <<'EOF' | oc apply -f -
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
  namespace: redhat-ods-applications
spec:
  backendStoreUri: "sqlite:////mlflow/mlflow.db"
  defaultArtifactRoot: "mlflow-artifacts:/"
  serveArtifacts: true
  artifactsDestination: "file:///mlflow/artifacts"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
EOF

# Wait for MLflow pod (~30s)
oc get pods -n redhat-ods-applications -w
```

## Step 7: Expose MLflow API route

The RHOAI Data Science Gateway handles browser authentication via OpenShift OAuth automatically. You only need a direct API route for sandbox/CLI access.

```bash
oc get configmap -n openshift-service-ca signing-cabundle \
  -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/mlflow-ca.crt

oc -n redhat-ods-applications create route reencrypt mlflow-api \
  --service=mlflow \
  --port=8443 \
  --dest-ca-cert=/tmp/mlflow-ca.crt \
  --insecure-policy=Redirect

export MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
echo "MLflow API: https://$MLFLOW_ROUTE"

# Verify API access
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  -H "X-MLflow-Workspace: default" \
  "https://$MLFLOW_ROUTE/api/2.0/mlflow/experiments/search?max_results=10"

# Verify RHOAI gateway URL
RHOAI_GATEWAY=$(oc get routes -n openshift-ingress data-science-gateway -o jsonpath='{.spec.host}')
echo "MLflow UI (browser): https://$RHOAI_GATEWAY/mlflow/"
```

## Step 8: Create MLflow experiment

```bash
export MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
curl -sk -X POST -H "Authorization: Bearer $(oc whoami -t)" \
  -H "X-MLflow-Workspace: default" \
  -H "Content-Type: application/json" \
  "https://$MLFLOW_ROUTE/api/2.0/mlflow/experiments/create" \
  -d '{"name":"opencode-demo"}'
```

Note the returned `experiment_id`. Verify the artifact location uses `mlflow-artifacts:/`:

```bash
EXPERIMENT_ID=<returned-id>
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  -H "X-MLflow-Workspace: default" \
  "https://$MLFLOW_ROUTE/api/2.0/mlflow/experiments/get?experiment_id=$EXPERIMENT_ID"
# artifact_location MUST start with "mlflow-artifacts:/"
```

## Step 9: Build MLflow plugin bundle

```bash
cd /tmp && rm -rf mlflow-bundle && mkdir mlflow-bundle && cd mlflow-bundle
npm init -y > /dev/null
npm install @mlflow/opencode
tar czf /tmp/mlflow-node-modules.tar.gz node_modules/
ls -lh /tmp/mlflow-node-modules.tar.gz   # ~22 MB
```

## Step 10: Prepare Vertex AI credentials

```bash
gcloud auth application-default login
ls ~/.config/gcloud/application_default_credentials.json
```

## Verification checklist

```bash
# All pods healthy
oc -n openshell get pods                          # openshell + postgresql Running
oc -n agent-sandbox-system get pods               # controller Running
oc -n redhat-ods-applications get pods            # mlflow Running

# RHOAI dashboard and gateway
oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'   # True
oc get routes -n openshift-ingress data-science-gateway            # rh-ai route exists

# Gateway reachable
openshell gateway list                            # openshift connected

# MLflow API accessible
export MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  -H "X-MLflow-Workspace: default" \
  "https://$MLFLOW_ROUTE/api/2.0/mlflow/experiments/search?max_results=10"

# MLflow browser route (via RHOAI Data Science Gateway)
RHOAI_GATEWAY=$(oc get routes -n openshift-ingress data-science-gateway -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w "%{http_code}" "https://$RHOAI_GATEWAY/mlflow/"
# Returns 302 (redirect to OAuth login) — correct

# Plugin bundle ready
ls -lh /tmp/mlflow-node-modules.tar.gz

# ADC file present
ls ~/.config/gcloud/application_default_credentials.json
```

## Key values for this cluster

| Value | Content |
|-------|---------|
| OpenShift API | `https://api.mschimun-dev.dwzv.p3.openshiftapps.com:443` |
| MLflow API route (sandbox) | `mlflow-api-redhat-ods-applications.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com` |
| MLflow UI (browser) | `rh-ai.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com/mlflow/` (via RHOAI gateway) |
| MLflow experiment | `opencode-demo` (verify `artifact_location` starts with `mlflow-artifacts:/`) |
| GCP project | `itpc-gcp-ai-eng-claude` |
| Vertex AI region | `us-east5` |
| OpenShell Helm version | `0.0.97` |
| OpenCode provider | `google-vertex-anthropic` |
| OpenCode model ID | `google-vertex-anthropic/claude-opus-4-6@default` |
| Plugin extract location | `/sandbox/node_modules/@mlflow/` |
| NODE_PATH (for plugin) | `/sandbox/node_modules` |
