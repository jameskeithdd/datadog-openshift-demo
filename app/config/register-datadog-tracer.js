// SPDX-License-Identifier: Apache-2.0
//
// Preloaded into the frontend (node --require). The frontend's code records
// span details through the vendor-neutral OpenTelemetry API; this registers
// the Datadog tracer (injected by Single Step Instrumentation) as that API's
// provider, so those calls land on Datadog spans.
//
// dd-trace-js needs this explicit step. If the tracer isn't present, this
// does nothing.
const tracer = global._ddtrace;
if (tracer && typeof tracer.TracerProvider === 'function') {
  new tracer.TracerProvider().register();
}
