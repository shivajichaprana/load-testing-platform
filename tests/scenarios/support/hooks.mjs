// Resolution of the generator's built-in module names.
//
// The scenario library imports `k6`, `k6/http`, `k6/execution` and
// `k6/metrics`. Those are built into the generator's runtime: there is no
// package to install, so under a plain runtime they do not resolve at all and
// nothing in the library can be imported for test.
//
// A resolver hook is used rather than an installed shim package because the
// shims are test fixtures. Vendoring them under a dependency directory would
// put them on the resolution path of the scenarios themselves, where a
// mistaken import of a fixture would run in a real fleet and succeed.
//
// Only these four names are intercepted. Everything else falls through, so a
// typo in a library import is still a resolution failure rather than silently
// becoming a stand-in.

const SUBSTITUTES = new Map([
  ['k6', new URL('./k6-module.mjs', import.meta.url).href],
  ['k6/http', new URL('./k6-http.mjs', import.meta.url).href],
  ['k6/execution', new URL('./k6-execution.mjs', import.meta.url).href],
  ['k6/metrics', new URL('./k6-metrics.mjs', import.meta.url).href],
]);

export async function resolve(specifier, context, nextResolve) {
  const substitute = SUBSTITUTES.get(specifier);
  if (substitute !== undefined) {
    return { url: substitute, format: 'module', shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
