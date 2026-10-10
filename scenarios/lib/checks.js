// Shared checks, and the thresholds that make them mean something.
//
// THE fact this module is built around: a check records a result and does not
// fail the run. The generator's exit status is decided by THRESHOLDS. A
// scenario full of checks and no thresholds exits zero with every assertion in
// it failing, and a regression gate reading that exit status reports the
// release as clean. So a check is never returned on its own here — a suite
// hands back both the predicates and the thresholds that make them binding,
// because the two are one statement and separating them is how the statement
// gets lost.
//
// Three more properties of the measurement follow from the same idea.
//
//   A latency threshold must be scoped to the responses the target MEANT to
//   send. An error response is usually faster than a successful one — a
//   rejection costs a connection and a header, not the work — so a target
//   that starts failing fast makes the unscoped response-time percentile
//   BETTER. The figure improves while the service degrades, and a gate on it
//   passes a release that broke the service. Scoping to expected responses is
//   not a refinement of that threshold; it is the difference between it
//   measuring the service and measuring the share of requests the service
//   refused to do any work for.
//
//   A threshold scoped to something that produced no samples PASSES. That is
//   the behaviour, and it makes every mis-typed selector a threshold that can
//   never fail. So each check name is validated against the selector syntax
//   before it can be used, and each scoped threshold names a phase the plan
//   actually contains.
//
//   An error rate over a whole run dilutes a short total outage. At a steady
//   arrival rate, a run of length T passes a threshold of "error rate below e"
//   through a complete outage lasting up to T x e: 36 seconds of a one-hour
//   run against a one-percent threshold, and two and a half minutes of a
//   four-hour soak. The figure is computed and published rather than left for
//   a reader to be surprised by, and the remedy is a tighter threshold on a
//   phase rather than a longer run.

import { check as recordCheck } from 'k6';

export class CheckSuiteError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CheckSuiteError';
  }
}

// The default end-of-run summary omits the upper percentiles, which are the
// ones a latency objective is written in.
export const SUMMARY_TREND_STATS = Object.freeze([
  'avg',
  'min',
  'med',
  'p(90)',
  'p(95)',
  'p(99)',
  'max',
  'count',
]);

// Characters that terminate a tag selector. A name containing one of these
// cannot be selected, and the threshold that tries silently matches nothing.
const SELECTOR_BREAKING = /[{},:]/;

/**
 * Refuse a check name that cannot be referred to from a threshold.
 *
 * This is the one validation in the module that has to happen before the run
 * rather than during it: the consequence of getting it wrong is not an error
 * but a pass.
 */
export function assertSelectable(name) {
  if (typeof name !== 'string' || name.trim() === '') {
    throw new CheckSuiteError('a check name must be a non-empty string.');
  }
  if (name !== name.trim()) {
    throw new CheckSuiteError(
      `the check name ${JSON.stringify(name)} has leading or trailing space. The selector is ` +
        'matched exactly, so the threshold would refer to a name nothing emits.',
    );
  }
  if (SELECTOR_BREAKING.test(name)) {
    throw new CheckSuiteError(
      `the check name ${JSON.stringify(name)} contains one of { } , : which end a tag selector. ` +
        'A threshold naming it would match no samples, and a threshold that matches no samples ' +
        'passes — so the assertion would be unfailable rather than broken.',
    );
  }
  if (/[0-9a-f]{8,}/i.test(name)) {
    throw new CheckSuiteError(
      `the check name ${JSON.stringify(name)} looks like it carries a value from the response. ` +
        'Every distinct name becomes its own sub-metric, so a name built from an identifier grows ' +
        'the result set once per request and no threshold can be written against any of them.',
    );
  }
  return name;
}

function readJsonPath(response, path) {
  // The generator's own JSON accessor is not available on a plain object, so
  // the path is walked here. Walked rather than evaluated: a path expression
  // that can call anything turns a response body into executable input.
  let value;
  try {
    value = typeof response.json === 'function' ? response.json() : JSON.parse(response.body);
  } catch {
    return { ok: false, value: undefined };
  }
  let cursor = value;
  for (const segment of path.split('.')) {
    if (cursor === null || typeof cursor !== 'object' || !(segment in cursor)) {
      return { ok: false, value: undefined };
    }
    cursor = cursor[segment];
  }
  return { ok: true, value: cursor };
}

/** Status equals one code. */
export function statusIs(code) {
  return Object.freeze({
    name: `status is ${code}`,
    readsBody: false,
    predicate: (response) => response.status === code,
  });
}

/** Status is one of a set, for an endpoint with more than one success shape. */
export function statusIn(codes) {
  if (!Array.isArray(codes) || codes.length === 0) {
    throw new CheckSuiteError('statusIn needs at least one status code.');
  }
  const accepted = new Set(codes);
  return Object.freeze({
    name: `status in ${codes.join('/')}`,
    readsBody: false,
    predicate: (response) => accepted.has(response.status),
  });
}

/**
 * A status check alone is not a success check.
 *
 * An error document returned with a success status passes every status check
 * ever written, and an endpoint that does it is not unusual. This check exists
 * so that the body is looked at at least once.
 */
export function bodyContains(fragment) {
  if (typeof fragment !== 'string' || fragment === '') {
    throw new CheckSuiteError('bodyContains needs a non-empty fragment.');
  }
  return Object.freeze({
    name: 'body carries the expected content',
    readsBody: true,
    predicate: (response) => typeof response.body === 'string' && response.body.includes(fragment),
  });
}

/** A named field in a JSON body equals a value. */
export function jsonFieldEquals(path, expected) {
  return Object.freeze({
    name: `field ${path} is as expected`,
    readsBody: true,
    predicate: (response) => {
      const read = readJsonPath(response, path);
      return read.ok && read.value === expected;
    },
  });
}

/** A named field in a JSON body is present and not empty. */
export function jsonFieldPresent(path) {
  return Object.freeze({
    name: `field ${path} is present`,
    readsBody: true,
    predicate: (response) => {
      const read = readJsonPath(response, path);
      return read.ok && read.value !== null && read.value !== '' && read.value !== undefined;
    },
  });
}

/** A response header is present. */
export function headerPresent(headerName) {
  const wanted = headerName.toLowerCase();
  return Object.freeze({
    name: `header ${headerName} is present`,
    readsBody: false,
    predicate: (response) => {
      const headers = response.headers || {};
      return Object.keys(headers).some((key) => key.toLowerCase() === wanted);
    },
  });
}

/**
 * A per-response latency check, which is NOT the latency threshold.
 *
 * The threshold answers "was the percentile within the ceiling". This answers
 * "what share of responses were over it", which is a different quantity and
 * the one that tells you whether a percentile was missed by a little
 * everywhere or by a lot in one place. Both are kept because neither implies
 * the other.
 */
export function latencyUnder(ms) {
  return Object.freeze({
    name: `response within the ceiling`,
    readsBody: false,
    predicate: (response) => typeof response.timings === 'object' && response.timings.duration < ms,
  });
}

/**
 * A named group of checks.
 *
 * `readsBody` is derived rather than declared: with bodies discarded a
 * body-reading predicate can never pass, so the suite carries the request
 * parameters its own predicates require instead of leaving an author to
 * remember them.
 */
export function suite(name, checks) {
  assertSelectable(name);
  if (!Array.isArray(checks) || checks.length === 0) {
    throw new CheckSuiteError(`check suite ${name} must contain at least one check.`);
  }
  const seen = new Set();
  for (const item of checks) {
    if (!item || typeof item.predicate !== 'function') {
      throw new CheckSuiteError(`check suite ${name} contains something that is not a check.`);
    }
    assertSelectable(item.name);
    if (seen.has(item.name)) {
      throw new CheckSuiteError(
        `check suite ${name} uses the name ${JSON.stringify(item.name)} twice. Two checks under ` +
          'one name share a sub-metric, so one threshold covers both and neither result can be ' +
          'read on its own.',
      );
    }
    seen.add(item.name);
  }

  const readsBody = checks.some((item) => item.readsBody);

  return Object.freeze({
    name,
    checks: Object.freeze([...checks]),
    names: Object.freeze(checks.map((item) => item.name)),
    readsBody,

    /** The predicate map in the form the generator's check function takes. */
    map() {
      const map = {};
      for (const item of this.checks) map[item.name] = item.predicate;
      return map;
    },

    /**
     * Request parameters this suite needs.
     *
     * A body-reading suite asks for the body explicitly, so that a scenario
     * can discard bodies globally — which is what keeps a large population
     * inside its memory allocation — without silently disabling its own
     * assertions.
     */
    params(extra = {}) {
      const tags = Object.assign({ suite: this.name }, extra.tags || {});
      return Object.assign({}, extra, {
        responseType: this.readsBody ? 'text' : 'none',
        tags,
      });
    },

    /** Record this suite against a response. Returns whether all passed. */
    run(response, tags = {}) {
      return recordCheck(response, this.map(), Object.assign({ suite: this.name }, tags));
    },
  });
}

/**
 * The longest complete outage a run-level error-rate threshold tolerates.
 *
 * At a steady arrival rate the share of failed requests is the share of the
 * run that failed, so the arithmetic is the run length multiplied by the
 * permitted rate. It does not depend on the rate, which is why a longer run is
 * a weaker assertion rather than a stronger one.
 */
export function blindOutageSeconds(runDurationSeconds, maxErrorRate) {
  if (!Number.isFinite(runDurationSeconds) || runDurationSeconds <= 0) {
    throw new CheckSuiteError('the run duration must be greater than zero.');
  }
  if (!Number.isFinite(maxErrorRate) || maxErrorRate < 0 || maxErrorRate >= 1) {
    throw new CheckSuiteError('the permitted error rate must be at least zero and below one.');
  }
  return runDurationSeconds * maxErrorRate;
}

function selector(metric, tags) {
  const parts = Object.entries(tags)
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([key, value]) => `${key}:${value}`);
  return parts.length === 0 ? metric : `${metric}{${parts.join(',')}}`;
}

/**
 * Every threshold this suite's claims imply.
 *
 * `plan` supplies the phases a threshold may be scoped to and the ceiling the
 * latency assertion is written against, so the ceiling the fleet was sized
 * with and the ceiling the run is judged by are one number rather than two
 * that agree today.
 */
export function thresholds({
  suite: checkSuite,
  plan,
  maxErrorRate = 0.01,
  latencyPercentile = 'p(95)',
  minCheckPassRate = 0.99,
  maxDropShare = 0,
  abortOnError = true,
}) {
  if (!checkSuite || typeof checkSuite.map !== 'function') {
    throw new CheckSuiteError('thresholds needs a check suite.');
  }
  if (!plan || !Array.isArray(plan.thresholdPhases) || plan.thresholdPhases.length === 0) {
    throw new CheckSuiteError('thresholds needs a plan that names at least one phase to judge.');
  }
  if (!/^p\(([0-9]{1,2}(\.[0-9]+)?)\)$/.test(latencyPercentile)) {
    throw new CheckSuiteError(
      `${JSON.stringify(latencyPercentile)} is not a percentile the generator will parse; write ` +
        'it as p(95). An unparseable statistic is rejected at startup rather than ignored, which ' +
        'is the one good outcome available here.',
    );
  }

  const out = {};

  // The whole-run gate on checks, which is the coarse one. Present because a
  // check outside every judged phase still has to count for something.
  out.checks = [`rate>=${minCheckPassRate}`];

  // Generator confession: iterations the generator could not start. A run that
  // dropped them did not offer the rate it reports, so the comparison it was
  // launched for is void regardless of what the target did.
  //
  // Omitted entirely rather than set to something permissive when the executor
  // cannot drop an iteration at all. A threshold nothing can breach reads, to
  // anyone auditing the run, exactly like one that was checked.
  if (maxDropShare !== null) {
    out.dropped_iterations = maxDropShare === 0 ? ['count<1'] : [`rate<${maxDropShare}`];
  }

  for (const phase of plan.thresholdPhases) {
    // Latency, on responses the target meant to send, in the phase being
    // judged. Both tags matter and for different reasons: the phase keeps the
    // ramp out of the percentile, the expected-response tag keeps fast
    // rejections out of it.
    out[selector('http_req_duration', { expected_response: 'true', phase })] = [
      `${latencyPercentile}<${plan.latencyCeilingMs}`,
    ];

    const failureThreshold = { threshold: `rate<${maxErrorRate}` };
    if (abortOnError) {
      failureThreshold.abortOnFail = true;
      // Not evaluated during the ramp. Early in a run the sample is small
      // enough that a handful of connection errors exceed any rate, so an
      // abort evaluated from the first second stops runs that were about to
      // be fine. The delay is the ramp the plan actually has.
      failureThreshold.delayAbortEval = `${Math.ceil((plan.phaseDurations.ramp || 0) / 1000) + 10}s`;
    }
    out[selector('http_req_failed', { phase })] = [failureThreshold];

    // Per-check gates, scoped to the same phase, so that a named assertion
    // failing is attributable rather than averaged into one pass rate.
    for (const checkName of checkSuite.names) {
      out[selector('checks', { check: checkName, phase })] = [`rate>=${minCheckPassRate}`];
    }
  }

  return out;
}

/** Findings about the thresholds, with the figures they rest on. */
export function thresholdFindings({ plan, maxErrorRate = 0.01, suite: checkSuite }) {
  const findings = [];
  const judgedSeconds = plan.thresholdPhases.reduce(
    (total, phase) => total + (plan.phaseDurations[phase] || 0) / 1000,
    0,
  );

  if (judgedSeconds > 0 && maxErrorRate > 0) {
    const blind = blindOutageSeconds(judgedSeconds, maxErrorRate);
    findings.push({
      code: 'C101',
      severity: blind > 60 ? 'warn' : 'note',
      message:
        `the error-rate threshold is evaluated over ${Math.round(judgedSeconds)}s of judged time at ` +
        `a permitted rate of ${maxErrorRate}, so a COMPLETE outage lasting up to ` +
        `${blind.toFixed(1)}s passes it. A longer run weakens this assertion rather than ` +
        'strengthening it; a shorter judged phase is the remedy, not a lower rate alone.',
    });
  }

  if (checkSuite && checkSuite.readsBody) {
    findings.push({
      code: 'C102',
      severity: 'note',
      message:
        `check suite ${checkSuite.name} reads response bodies, so its requests ask for the body ` +
        'even where the scenario discards bodies globally. Retained bodies are held per virtual ' +
        'user, so the memory this costs grows with the population and not with the rate.',
    });
  }

  if (!checkSuite || checkSuite.names.length === 0) {
    findings.push({
      code: 'C103',
      severity: 'error',
      message: 'no checks are recorded, so the per-check thresholds cover nothing.',
    });
  }

  return Object.freeze(findings);
}
