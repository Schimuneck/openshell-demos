#!/usr/bin/env bash
set -euo pipefail

# Resets the cluster to pre-demo state:
# - Deletes the sandbox
# - Clears all MLflow traces from the experiment
# - Leaves infrastructure intact (OpenShell, MLflow, RHOAI)

export PATH="$HOME/bin:$PATH"

MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
OC_TOKEN=$(oc whoami -t)
MLFLOW_API="https://$MLFLOW_ROUTE"
EXPERIMENT_ID=3

echo "=== Deleting sandbox ==="
openshell sandbox delete opencode-demo 2>/dev/null && echo "Sandbox deleted" || echo "No sandbox to delete"

echo ""
echo "=== Cleaning MLflow traces ==="

# Fetch all trace request IDs
TRACE_IDS=$(curl -sk "$MLFLOW_API/api/2.0/mlflow/traces?experiment_ids=$EXPERIMENT_ID&max_results=100" \
  -H "Authorization: Bearer $OC_TOKEN" \
  -H "X-MLflow-Workspace: default" \
  | python3 -c "import json,sys; [print(t['request_id']) for t in json.load(sys.stdin).get('traces',[])]" 2>/dev/null)

if [ -n "$TRACE_IDS" ]; then
  # Build JSON array of request IDs
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

echo ""
echo "=== Infrastructure check ==="
echo "OpenShell pods:"
oc -n openshell get pods --no-headers 2>&1 | grep -v Error || true
echo "MLflow:"
oc -n redhat-ods-applications get pods --no-headers 2>&1 | grep mlflow
echo "Gateway:"
openshell gateway list 2>&1

echo ""
echo "=== Ready for demo ==="
