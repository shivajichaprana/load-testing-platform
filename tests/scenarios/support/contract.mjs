// A valid launch contract, and the knobs a test needs to break one.
//
// Written as a complete environment rather than as a partial override, because
// every value here is REQUIRED by the contract and the suite's job includes
// proving that each one is required. A fixture that omitted the optional ones
// would leave the tests unable to tell a value that is absent by design from
// one that was forgotten.

/** The figures the rest of the suite's arithmetic is quoted against. */
export const CONTRACT = Object.freeze({
  runId: 'r-2f9c41',
  startEpoch: 1760000000,
  workerCount: 8,
  ratePerWorker: 100,
  latencyCeilingMs: 250,
  stopTimeoutSeconds: 120,
  tupleBudget: 64,
});

/**
 * The environment a worker is handed.
 *
 * `overrides` replaces a value; a value set to `undefined` is REMOVED, which
 * is how a test asserts that the contract refuses an absent one.
 */
export function contractEnv(overrides = {}) {
  const env = {
    RUNNER_RUN_ID: CONTRACT.runId,
    RUNNER_START_EPOCH: String(CONTRACT.startEpoch),
    RUNNER_WORKER_COUNT: String(CONTRACT.workerCount),
    RUNNER_RATE_SHARE: String(CONTRACT.ratePerWorker),
    RUNNER_LOAD_MODEL: 'open',
    RUNNER_CONNECTION_REUSE: 'true',
    RUNNER_STOP_TIMEOUT_SECONDS: String(CONTRACT.stopTimeoutSeconds),
    RUNNER_LATENCY_CEILING_MS: String(CONTRACT.latencyCeilingMs),
    RUNNER_TUPLE_BUDGET: String(CONTRACT.tupleBudget),
    RUNNER_METRIC_NAMESPACE: 'LoadTesting/Runs',
    RUNNER_PARAMETER_PREFIX: '/load-testing/example',
    RUNNER_ARTIFACT_BUCKET: 'example-run-artifacts',
    RUNNER_ARTIFACT_PREFIX: 'runs',
    TARGET_BASE_URL: 'https://target.example.invalid',
  };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  return env;
}

/** A logger that keeps what it was told instead of printing it. */
export function recordingLogger() {
  const lines = { warn: [], error: [], log: [] };
  return {
    lines,
    warn: (line) => lines.warn.push(line),
    error: (line) => lines.error.push(line),
    log: (line) => lines.log.push(line),
    /** Finding codes seen, in the order they were reported. */
    codes: () =>
      [...lines.error, ...lines.warn]
        .map((line) => /^\[([A-Z][0-9]+)\]/.exec(line))
        .filter(Boolean)
        .map((match) => match[1]),
  };
}
