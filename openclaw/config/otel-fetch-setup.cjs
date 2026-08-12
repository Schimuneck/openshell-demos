// Instruments OpenClaw LLM calls via fetch() and exports OTel traces to MLflow.
//
// Why this exists: OpenClaw's diagnostics-otel plugin doesn't start its OTel SDK
// in --local agent mode. And even if it did, the OTel HTTP transport uses
// http.request() which bypasses the sandbox's transparent proxy (DNS fails).
// This preload sets up the OTel SDK using fetch() (which is proxy-aware via
// undici's EnvHttpProxyAgent) and instruments outbound Vertex AI calls.
//
// Usage: NODE_OPTIONS="--require /sandbox/otel-fetch-setup.cjs"

const OTEL_BASE = "/sandbox/.openclaw/npm/projects/openclaw-diagnostics-otel-67638bd2bf/node_modules/@openclaw/diagnostics-otel/node_modules";

const api = require(`${OTEL_BASE}/@opentelemetry/api`);
const { BasicTracerProvider, BatchSpanProcessor } = require(`${OTEL_BASE}/@opentelemetry/sdk-trace-base`);
const { resourceFromAttributes } = require(`${OTEL_BASE}/@opentelemetry/resources`);
const { ProtobufTraceSerializer } = require(`${OTEL_BASE}/@opentelemetry/otlp-transformer/build/src/trace/protobuf`);

const ENDPOINT = process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT;
const TOKEN = process.env.MLFLOW_TRACKING_TOKEN;
const VERTEX_HOST = "us-east5-aiplatform.googleapis.com";

class FetchOTLPExporter {
  constructor(fetchFn) {
    this._shutdown = false;
    this._fetch = fetchFn;
  }
  export(spans, resultCallback) {
    if (this._shutdown || !ENDPOINT) { resultCallback({ code: 0 }); return; }
    try {
      const body = ProtobufTraceSerializer.serializeRequest(spans);
      this._fetch(ENDPOINT, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-protobuf",
          "Authorization": "Bearer " + TOKEN,
          "X-MLflow-Workspace": "default",
          "x-mlflow-experiment-id": process.env.MLFLOW_EXPERIMENT_ID || "3"
        },
        body
      }).then(r => resultCallback({ code: r.ok ? 0 : 1 }))
        .catch(() => resultCallback({ code: 1 }));
    } catch { resultCallback({ code: 1 }); }
  }
  shutdown() { this._shutdown = true; return Promise.resolve(); }
  forceFlush() { return Promise.resolve(); }
}

if (ENDPOINT) {
  const realFetch = globalThis.fetch.bind(globalThis);

  const exporter = new FetchOTLPExporter(realFetch);
  const provider = new BasicTracerProvider({
    resource: resourceFromAttributes({
      "service.name": process.env.OTEL_SERVICE_NAME || "openclaw-sandbox"
    }),
    spanProcessors: [new BatchSpanProcessor(exporter, { scheduledDelayMillis: 2000 })]
  });
  api.trace.setGlobalTracerProvider(provider);

  const tracer = api.trace.getTracer("openclaw-sandbox");

  globalThis.fetch = async function instrumentedFetch(input, init) {
    const url = typeof input === "string" ? input
      : input instanceof URL ? input.href
      : (input?.url || "");
    const method = init?.method
      || (typeof input === "object" && !(input instanceof URL) ? input?.method : null)
      || "GET";

    if (url.includes(VERTEX_HOST) && method === "POST") {
      const model = (url.match(/models\/([^:?]+)/) || [])[1];
      const span = tracer.startSpan("gen_ai.chat", {
        kind: api.SpanKind.CLIENT,
        attributes: {
          "gen_ai.system": "vertex_ai",
          "gen_ai.request.model": model || "claude-opus-4-6",
          "server.address": VERTEX_HOST,
          "http.request.method": method,
          "url.full": url.replace(/\?.*$/, "")
        }
      });

      try {
        const response = await realFetch(input, init);
        span.setAttribute("http.response.status_code", response.status);
        if (response.ok) {
          const cloned = response.clone();
          cloned.json().then(data => {
            if (data.usageMetadata) {
              span.setAttribute("gen_ai.usage.input_tokens", data.usageMetadata.promptTokenCount || 0);
              span.setAttribute("gen_ai.usage.output_tokens", data.usageMetadata.candidatesTokenCount || 0);
            }
            if (data.modelVersion) span.setAttribute("gen_ai.response.model", data.modelVersion);
            span.setStatus({ code: api.SpanStatusCode.OK });
            span.end();
          }).catch(() => { span.setStatus({ code: api.SpanStatusCode.OK }); span.end(); });
        } else {
          span.setStatus({ code: api.SpanStatusCode.ERROR, message: "HTTP " + response.status });
          span.end();
        }
        return response;
      } catch (err) {
        span.setStatus({ code: api.SpanStatusCode.ERROR, message: err.message });
        span.end();
        throw err;
      }
    }

    return realFetch(input, init);
  };
  globalThis.fetch.__original = realFetch;

  let shuttingDown = false;
  const cleanup = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    try { await provider.forceFlush(); await provider.shutdown(); } catch {}
  };
  process.on("beforeExit", cleanup);
  process.once("SIGTERM", async () => { await cleanup(); process.exit(0); });
  process.once("SIGINT", async () => { await cleanup(); process.exit(0); });
}
