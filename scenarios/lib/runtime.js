// The launch contract: the values a worker is given, what each one means, and
// what it may not be used for.
//
// Every value arrives as text through a container environment variable. Two of
// them are the reason this module exists rather than each scenario reading the
// environment for itself.
//
//   RATE_SHARE is THIS worker's share of the offered rate, not the fleet's
//   target. A scenario that uses the fleet target as its own arrival rate
//   offers the whole objective from every worker, so a fleet of N offers N
//   times what the run reports having asked for. Nothing in the result says
//   so: the target's metrics show a load it was never asked to serve, and the
//   generator's show every request it made succeeding.
//
//   LATENCY_CEILING_MS is the figure the fleet was sized with. A scenario that
//   states its own ceiling can disagree with it, and the disagreement has a
//   direction: a scenario willing to wait longer than the sizing ceiling makes
//   its worker hold four-tuples for longer than the socket budget was divided
//   by, so the worker runs out of sockets before the latency assertion fires.
//   The run then ends in address-unavailable errors with a passing latency
//   figure attached.
//
// Both are therefore read from the contract and are not scenario inputs.

export class LaunchContractError extends Error {
  constructor(message) {
    super(message);
    this.name = 'LaunchContractError';
  }
}

// Set on the task definition, so they are the same for every run.
export const DEFINITION_KEYS = Object.freeze([
  'RUNNER_METRIC_NAMESPACE',
  'RUNNER_PARAMETER_PREFIX',
  'RUNNER_ARTIFACT_BUCKET',
  'RUNNER_ARTIFACT_PREFIX',
  'RUNNER_LOAD_MODEL',
  'RUNNER_CONNECTION_REUSE',
  'RUNNER_STOP_TIMEOUT_SECONDS',
  'RUNNER_LATENCY_CEILING_MS',
  'RUNNER_TUPLE_BUDGET',
]);

// Supplied as launch overrides, so they belong to one run.
export const OVERRIDE_KEYS = Object.freeze([
  'RUNNER_RUN_ID',
  'RUNNER_START_EPOCH',
  'RUNNER_WORKER_COUNT',
  'RUNNER_RATE_SHARE',
  'RUNNER_LOAD_MODEL',
]);

/**
 * The environment this process was given.
 *
 * Under the generator the variables arrive on a global rather than on a
 * process object, so the source is resolved rather than assumed. Passing one
 * explicitly is what makes everything below testable without a container.
 */
export function defaultEnv() {
  if (typeof globalThis.__ENV === 'object' && globalThis.__ENV !== null) {
    return globalThis.__ENV;
  }
  if (typeof globalThis.process === 'object' && globalThis.process !== null) {
    return globalThis.process.env || {};
  }
  return {};
}

/**
 * Whether a contract value was actually supplied.
 *
 * An unset variable is absent, and so is an empty one: the task definition
 * sends an empty string for an optional value it has nothing to put in, which
 * means "absent" and would otherwise read as a configured empty name.
 */
export function present(value) {
  return typeof value === 'string' && value.trim() !== '';
}

function requireText(env, key) {
  const value = env[key];
  if (!present(value)) {
    throw new LaunchContractError(
      `${key} is not set. It is supplied by the task definition or by the launch ` +
        'override, so an unset value means the scenario is running outside the fleet.',
    );
  }
  return value.trim();
}

function requireNumber(env, key, { min, max, integer = false } = {}) {
  const text = requireText(env, key);
  // Number() rather than parseFloat(): parseFloat reads a leading number out of
  // any string and discards the rest, so "40,000" would arrive as 40 and
  // "250ms" as 250. A contract value is either a number or a fault.
  const value = Number(text);
  if (!Number.isFinite(value)) {
    throw new LaunchContractError(`${key} must be a number; received ${JSON.stringify(text)}.`);
  }
  if (integer && !Number.isInteger(value)) {
    throw new LaunchContractError(`${key} must be a whole number; received ${text}.`);
  }
  if (min !== undefined && value < min) {
    throw new LaunchContractError(`${key} must be at least ${min}; received ${text}.`);
  }
  if (max !== undefined && value > max) {
    throw new LaunchContractError(`${key} must be at most ${max}; received ${text}.`);
  }
  return value;
}

function requireBoolean(env, key) {
  // Compared exactly, with no case folding. The only producer of this value
  // renders it lowercase, so anything else is a hand-edit — and a hand-edit
  // that reads as permissive here changes how many connections a worker may
  // hold, which is a sizing input rather than a preference.
  const text = requireText(env, key);
  if (text === 'true') return true;
  if (text === 'false') return false;
  throw new LaunchContractError(
    `${key} must be exactly "true" or "false"; received ${JSON.stringify(text)}. ` +
      'Anything else is refused rather than read as false, because the permissive ' +
      'reading of a typo here changes how many connections a worker may hold.',
  );
}

/**
 * The launch contract, validated.
 *
 * `fleetRate` is derived rather than delivered, and is for the run's record
 * only: it is what the fleet offers if every worker was placed, which the
 * launcher reconciles separately and which a scenario must not use as its own
 * arrival rate.
 */
export function launchContext(env = defaultEnv()) {
  const workerCount = requireNumber(env, 'RUNNER_WORKER_COUNT', { min: 1, integer: true });
  const ratePerWorker = requireNumber(env, 'RUNNER_RATE_SHARE', { min: 0 });
  const loadModel = requireText(env, 'RUNNER_LOAD_MODEL');
  if (loadModel !== 'open' && loadModel !== 'closed') {
    throw new LaunchContractError(
      `RUNNER_LOAD_MODEL must be "open" or "closed"; received ${JSON.stringify(loadModel)}.`,
    );
  }

  const bucket = env.RUNNER_ARTIFACT_BUCKET;

  return Object.freeze({
    runId: requireText(env, 'RUNNER_RUN_ID'),
    startEpoch: requireNumber(env, 'RUNNER_START_EPOCH', { min: 1, integer: true }),
    workerCount,
    ratePerWorker,
    fleetRate: ratePerWorker * workerCount,
    loadModel,
    connectionReuse: requireBoolean(env, 'RUNNER_CONNECTION_REUSE'),
    stopTimeoutSeconds: requireNumber(env, 'RUNNER_STOP_TIMEOUT_SECONDS', {
      min: 2,
      max: 120,
      integer: true,
    }),
    latencyCeilingMs: requireNumber(env, 'RUNNER_LATENCY_CEILING_MS', { min: 1 }),
    // Connections one worker may hold at once: the four-tuple budget the fleet
    // size was divided by. Delivered rather than recomputed here, because a
    // second derivation of it is a second number that agrees today.
    tupleBudget: requireNumber(env, 'RUNNER_TUPLE_BUDGET', { min: 1, integer: true }),
    metricNamespace: requireText(env, 'RUNNER_METRIC_NAMESPACE'),
    parameterPrefix: requireText(env, 'RUNNER_PARAMETER_PREFIX'),
    artifactPrefix: requireText(env, 'RUNNER_ARTIFACT_PREFIX'),
    // Optional by configuration, so absence is a value and not a fault.
    artifactBucket: present(bucket) ? bucket.trim() : null,
  });
}

/**
 * How long one request may take before it is abandoned.
 *
 * The sizing ceiling, exactly, and not a figure of its own. The ceiling is what
 * the worker's four-tuple budget was divided by, so a request allowed to run
 * longer than it occupies a socket for longer than the arithmetic assumed and
 * the worker runs out of sockets at a rate below the one it was sized for. A
 * timeout BELOW the ceiling is a different experiment — it abandons responses
 * the objective says are still being measured — so the two are one number.
 */
export function requestTimeout(ctx) {
  return `${Math.ceil(ctx.latencyCeilingMs)}ms`;
}

/**
 * Seconds between now and the instant every worker is waiting for.
 *
 * Negative means the instant has already passed, which is a measurement fact
 * and not an error: a worker placed late cannot join the ramp where its peers
 * are, and the run's record should say by how much rather than have one worker
 * silently run a shifted profile.
 */
export function startSkewSeconds(ctx, nowSeconds) {
  return ctx.startEpoch - nowSeconds;
}

/**
 * Hold this worker until the shared start instant.
 *
 * The generator's own per-scenario start offset cannot express this. That
 * offset is measured from the moment the process started, and the processes in
 * a fleet start whenever their tasks were placed — which is the skew the
 * synchronized instant exists to remove. So the barrier is wall-clock, it runs
 * once per worker, and it belongs in setup rather than in a virtual user: a
 * virtual user that sleeps has consumed an iteration to do it.
 *
 * `sleep` and `now` are injected because the generator supplies its own and a
 * test supplies neither.
 */
export function waitForStartInstant(ctx, { sleep, now, maxWaitSeconds = 900 } = {}) {
  if (typeof sleep !== 'function' || typeof now !== 'function') {
    throw new LaunchContractError('waitForStartInstant requires both a sleep and a now function.');
  }
  const skew = startSkewSeconds(ctx, now());
  if (skew > maxWaitSeconds) {
    throw new LaunchContractError(
      `the start instant is ${Math.round(skew)}s away, beyond the ${maxWaitSeconds}s this worker ` +
        'will wait. A barrier that long is a stale run identifier or a clock disagreement, and ' +
        'waiting it out would bill the whole fleet for the wait.',
    );
  }
  if (skew <= 0) {
    return Object.freeze({ waitedSeconds: 0, lateBySeconds: -skew, onTime: false });
  }
  sleep(skew);
  return Object.freeze({ waitedSeconds: skew, lateBySeconds: 0, onTime: true });
}

/**
 * Where this worker's own identity can be read.
 *
 * It cannot be read from the virtual user number. Each worker is a separate
 * generator process and each numbers its virtual users from one, so every
 * worker in the fleet holds a user number 1. A scenario that partitions its
 * data by that number gives every worker the same partition: the run touches
 * one slice of the data N times over and reports having covered all of it.
 *
 * It also cannot be a launch override, because one launch request places
 * identical tasks and every task in the request receives the same overrides.
 * The task's own metadata is the only per-worker fact available inside the
 * container.
 */
export function metadataEndpoint(env = defaultEnv()) {
  const uri = env.ECS_CONTAINER_METADATA_URI_V4 || env.ECS_CONTAINER_METADATA_URI;
  return present(uri) ? `${uri.trim().replace(/\/+$/, '')}/task` : null;
}

/**
 * This worker's partition, from an identity the caller has already fetched.
 *
 * Refused rather than defaulted when the identity is unavailable. A default of
 * zero is the worst available answer: it is silent, it is the same on every
 * worker, and it produces exactly the run described above.
 */
export function partitionIndex(identity, partitions) {
  if (!Number.isInteger(partitions) || partitions < 1) {
    throw new LaunchContractError('the partition count must be a positive whole number.');
  }
  if (!identity || !present(identity.taskId)) {
    throw new LaunchContractError(
      'this worker has no readable task identity, so it cannot be assigned a data partition. ' +
        'A partitioning scenario is refused rather than defaulted: every worker would take the ' +
        'same partition and the run would report having covered data it never touched.',
    );
  }
  return stableIndex(identity.taskId, partitions);
}

/**
 * A partition from an opaque identifier.
 *
 * The identifier is a hexadecimal task id rather than a counter, so the index
 * is a hash and the distribution is only approximately uniform. For a fleet of
 * a few dozen that is a real imbalance and is reported as such, rather than
 * described as even.
 */
export function stableIndex(text, buckets) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    // 16777619, as repeated shifts: the multiply would lose precision once the
    // product passes the exactly-representable integer range.
    hash = (hash + (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24)) >>> 0;
  }
  return hash % buckets;
}

/**
 * Join a path onto the target's base address.
 *
 * The platform's URL resolver is a resolver and not a joiner: an absolute path
 * replaces the whole path, and a leading double slash is read as a host. Either
 * one silently points the run at a different place and every result is then
 * reported under this target's name. The origin is therefore compared rather
 * than trusted.
 */
export function endpoint(baseUrl, path = '') {
  let base;
  try {
    base = new URL(baseUrl);
  } catch {
    throw new LaunchContractError(`the target base address ${JSON.stringify(baseUrl)} is not a URL.`);
  }
  if (base.protocol !== 'http:' && base.protocol !== 'https:') {
    throw new LaunchContractError(`the target base address must be http or https; received ${base.protocol}`);
  }
  if (path === '') return base.toString();
  // A backslash counts as a slash here, because the resolver treats the two
  // alike under http and https. So "/\\host/x" against a base with no path of
  // its own resolves to HOST rather than to a path - the run then measures a
  // different site and reports it under this target's name.
  if (!path.startsWith('/') || /^[/\\]/.test(path.slice(1))) {
    throw new LaunchContractError(
      `the path ${JSON.stringify(path)} must begin with a single slash and not a second slash or ` +
        'backslash; a relative path resolves against the base path, and a doubled separator is ' +
        'read as a host.',
    );
  }
  // The origin is compared after resolving, and that comparison is not
  // redundant with the guard above. The parser REMOVES tab, newline and
  // carriage return from its input before parsing, so a path whose second
  // character is one of those becomes a doubled separator - and therefore a
  // host - after the guard has already looked at it and seen whitespace.
  // Enumerating the characters the parser strips is a losing game; comparing
  // the result is not.
  const joined = new URL(base.pathname.replace(/\/+$/, '') + path, base);
  if (joined.origin !== base.origin) {
    throw new LaunchContractError(
      `the path ${JSON.stringify(path)} resolves to ${joined.origin}, not to ${base.origin}.`,
    );
  }
  return joined.toString();
}

/**
 * The target address for a scenario, validated.
 *
 * Required: a default would make a scenario runnable against nothing and the
 * run would report every request failing to connect, which reads as the target
 * being down.
 */
export function requireTargetBaseUrl(env = defaultEnv(), key = 'TARGET_BASE_URL') {
  const value = requireText(env, key);
  endpoint(value, '');
  return value.replace(/\/+$/, '');
}

/** An optional scenario input, with the same absent-when-empty rule. */
export function optionalText(env, key, fallback = null) {
  const value = env[key];
  return present(value) ? value.trim() : fallback;
}

/** An optional numeric scenario input. */
export function optionalNumber(env, key, fallback) {
  if (!present(env[key])) return fallback;
  const value = Number(env[key].trim());
  if (!Number.isFinite(value)) {
    throw new LaunchContractError(`${key} must be a number; received ${JSON.stringify(env[key])}.`);
  }
  return value;
}
