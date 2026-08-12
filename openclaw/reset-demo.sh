#!/usr/bin/env bash
set -euo pipefail

echo "=== OpenClaw Demo Reset ==="

# 1. Delete sandbox
echo ""
echo "--- Deleting sandbox ---"
openshell sandbox delete openclaw-demo 2>/dev/null && echo "Sandbox deleted" || echo "No sandbox to delete"

# 2. Clean MLflow traces
echo ""
echo "--- Cleaning MLflow traces ---"
OC_TOKEN=$(oc whoami -t 2>/dev/null) || { echo "Not logged in to OpenShift — skipping MLflow cleanup"; exit 0; }
MLFLOW_API="https://$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')"
EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-3}"

TRACE_IDS=$(curl -sk "$MLFLOW_API/api/2.0/mlflow/traces?experiment_ids=$EXPERIMENT_ID&max_results=100" \
  -H "Authorization: Bearer $OC_TOKEN" \
  -H "X-MLflow-Workspace: default" \
  | python3 -c "import json,sys; [print(t['request_id']) for t in json.load(sys.stdin).get('traces',[])]" 2>/dev/null)

if [ -n "$TRACE_IDS" ]; then
  IDS_JSON=$(echo "$TRACE_IDS" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  DELETED=$(curl -sk "$MLFLOW_API/api/2.0/mlflow/traces/delete-traces" \
    -H "Authorization: Bearer $OC_TOKEN" \
    -H "X-MLflow-Workspace: default" \
    -H "Content-Type: application/json" \
    -d "{\"experiment_id\":\"$EXPERIMENT_ID\",\"request_ids\":$IDS_JSON}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('traces_deleted',0))" 2>/dev/null)
  echo "Deleted $DELETED traces"
else
  echo "No traces to delete"
fi

# 3. Remove OAuth proxy resources (if deployed)
echo ""
echo "--- Cleaning OAuth proxy resources ---"
oc -n openshell delete route openclaw-ui 2>/dev/null && echo "Route deleted" || echo "No route"
oc -n openshell delete deployment openclaw-oauth-proxy 2>/dev/null && echo "Deployment deleted" || echo "No deployment"
oc -n openshell delete svc openclaw-oauth-proxy 2>/dev/null && echo "Service deleted" || echo "No service"
oc -n openshell delete sa openclaw-oauth-proxy 2>/dev/null && echo "ServiceAccount deleted" || echo "No SA"
oc -n openshell delete configmap openclaw-nginx-config 2>/dev/null && echo "ConfigMap deleted" || echo "No configmap"
oc -n openshell delete secret openclaw-oauth-proxy-tls 2>/dev/null && echo "Secret deleted" || echo "No secret"

echo ""
echo "=== Reset complete ==="
