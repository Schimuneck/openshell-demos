#!/bin/sh
# Runs inside the sandbox. Uploaded to /sandbox/start-gateway.sh
export PATH="/usr/bin:/sandbox/node_modules/.bin:$PATH"
export NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"
rm -f /sandbox/.openclaw/gateway.lock 2>/dev/null
exec openclaw gateway run --force
