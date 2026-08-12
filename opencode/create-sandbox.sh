#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env
ENV_FLAGS=()
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  ENV_FLAGS+=(--env "$key=$value")
done < "$SCRIPT_DIR/.env"

# Dynamic values
MLFLOW_ROUTE=$(oc -n redhat-ods-applications get route mlflow-api -o jsonpath='{.spec.host}')
OC_TOKEN=$(oc whoami -t)

openshell sandbox create \
  --name opencode-demo \
  "${ENV_FLAGS[@]}" \
  --env "MLFLOW_TRACKING_URI=https://$MLFLOW_ROUTE" \
  --env "MLFLOW_TRACKING_TOKEN=$OC_TOKEN" \
  --upload "$HOME/.config/gcloud/application_default_credentials.json":/sandbox/.gcloud/adc.json

# Upload OpenCode config separately (--upload flag mishandles JSON file destinations)
openshell sandbox upload opencode-demo "$SCRIPT_DIR/config/opencode.json" /sandbox/
