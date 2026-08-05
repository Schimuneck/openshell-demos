# Troubleshooting

## Port-forward drops

Restart in Terminal 1:

```bash
oc -n openshell port-forward svc/openshell 8080:8080 &
sleep 3
```

## OC token expires

Re-login and recreate the sandbox (the token is baked into the sandbox env):

```bash
oc login --token=<your-token> --server=https://api.mschimun-dev.dwzv.p3.openshiftapps.com:443
openshell sandbox delete opencode-demo
# Re-create with the Act 1 command from the README
```

## OpenCode fails to connect to Vertex AI

Check the policy and verify the binary path:

```bash
openshell pol get opencode-demo
```

The OpenCode binary path in v0.0.97 is `/usr/lib/node_modules/opencode-ai/bin/.opencode`. Both this and `/usr/bin/node` must be in the policy.

## MLflow traces not appearing

1. Check MLflow route accessibility:
   ```bash
   curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
     -H "X-MLflow-Workspace: default" \
     "https://$MLFLOW_ROUTE/api/2.0/mlflow/experiments/search?max_results=10"
   ```

2. Verify the plugin loaded (must set NODE_PATH):
   ```bash
   openshell sandbox exec -n opencode-demo --env NODE_PATH=/sandbox/node_modules -- \
     node -e 'require("@mlflow/opencode"); console.log("OK")'
   ```

3. Check env vars are set:
   ```bash
   openshell sandbox exec -n opencode-demo -- \
     bash -c 'echo $MLFLOW_TRACKING_URI; echo $MLFLOW_EXPERIMENT_ID'
   ```

4. Test network connectivity from sandbox:
   ```bash
   openshell sandbox exec -n opencode-demo -- node -e "
   const https = require('https');
   const url = process.env.MLFLOW_TRACKING_URI + '/api/2.0/mlflow/experiments/search?max_results=10';
   https.get(url, {
     headers: {
       'Authorization': 'Bearer ' + process.env.MLFLOW_TRACKING_TOKEN,
       'X-MLflow-Workspace': 'default'
     },
     rejectUnauthorized: false
   }, r => {
     let d='';
     r.on('data', c => d+=c);
     r.on('end', () => console.log('HTTP', r.statusCode, d.substring(0,200)));
   }).on('error', e => console.error('ERR:', e.message));"
   ```
   If connection is refused, both `/usr/bin/node` AND `.opencode` must be in the MLflow network policy.

5. If you see `EACCES: permission denied, mkdir '/mlflow'`, the experiment's `artifact_location` uses `file://` instead of `mlflow-artifacts://`. Fix the MLflow CR:
   ```bash
   oc patch mlflow mlflow -n redhat-ods-applications --type=merge \
     -p '{"spec":{"defaultArtifactRoot":"mlflow-artifacts:/"}}'
   ```
   Then delete and recreate the experiment (existing experiments keep their original `artifact_location`).

6. Verify traces via API:
   ```bash
   curl -sk "https://$MLFLOW_ROUTE/api/2.0/mlflow/traces?experiment_ids=<id>&max_results=10" \
     -H "Authorization: Bearer $(oc whoami -t)" \
     -H "X-MLflow-Workspace: default"
   ```

## MLflow UI shows "We couldn't load your workspaces"

The browser is not authenticated. Use the RHOAI Data Science Gateway URL (not the direct API route):

- Browser: `https://rh-ai.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com/mlflow/`
- API/sandbox: `https://mlflow-api-redhat-ods-applications.apps.rosa.mschimun-dev.dwzv.p3.openshiftapps.com`

If the RHOAI dashboard isn't deployed, verify `DataScienceCluster` has `dashboard: managementState: Managed` and the Service Mesh operator is installed.

## Model not available in Vertex AI

If `claude-opus-4-6` is unavailable in `us-east5`, change the region in `config/opencode.json` or select a different model from OpenCode's model picker.

## Vertex AI returns "billing not enabled"

The GCP project must have Vertex AI API enabled with billing. Use `itpc-gcp-ai-eng-claude`:

```bash
gcloud services list --project=itpc-gcp-ai-eng-claude --filter=aiplatform
```

## OpenCode ProviderModelNotFoundError

1. Provider must be `google-vertex-anthropic` (not `google-vertex`)
2. Model ID needs the `@default` suffix: `google-vertex-anthropic/claude-opus-4-6@default`

## MLflow plugin not found

The plugin must be extracted to `/sandbox/node_modules/` (writable), not `/usr/lib/...` (read-only). Set `NODE_PATH=/sandbox/node_modules` when launching OpenCode.
