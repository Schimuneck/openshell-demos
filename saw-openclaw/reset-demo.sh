#!/usr/bin/env bash
set -euo pipefail
: "${SAW_NAMESPACE:=openshell-agents}"

echo "=== Teardown: saw-openclaw ==="

# Delete all VMs
for vm in $(oc get vm -n "$SAW_NAMESPACE" -o name 2>/dev/null); do
  echo "Deleting $vm..."
  oc delete "$vm" -n "$SAW_NAMESPACE" --wait=false || true
done

# Delete DataVolumes
for dv in $(oc get dv -n "$SAW_NAMESPACE" -o name 2>/dev/null); do
  echo "Deleting $dv..."
  oc delete "$dv" -n "$SAW_NAMESPACE" --wait=false || true
done

# Uninstall Helm releases
for release in $(helm list -n "$SAW_NAMESPACE" -q 2>/dev/null); do
  echo "Uninstalling Helm release '$release'..."
  helm uninstall "$release" -n "$SAW_NAMESPACE" || true
done

# Delete Keycloak resources
oc delete keycloak --all -n "$SAW_NAMESPACE" 2>/dev/null || true
oc delete keycloakrealmimport --all -n "$SAW_NAMESPACE" 2>/dev/null || true

# Delete namespace
if oc get ns "$SAW_NAMESPACE" &>/dev/null; then
  echo "Deleting namespace $SAW_NAMESPACE..."
  oc delete ns "$SAW_NAMESPACE"
fi

echo ""
echo "Teardown complete."
