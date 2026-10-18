// Checks, and the thresholds that make them binding.
//
// THE fact this file exists to pin down: a check records a result and does not
// fail the run. The exit status belongs to the thresholds. A scenario full of
// checks and no thresholds exits zero with every assertion in it failing, and
// a regression gate reading that exit status reports the release as clean.
//
// Three further properties are asserted below because each one turns a broken
// assertion into a PASSING one rather than into an error:
//
//   a threshold whose selector matches nothing passes, so a check name that
//   cannot be selected is unfailable;
//
//   an unscoped latency percentile IMPROVES when a target starts failing
//   fast, because a rejection costs a connection and a header rather than the
//   work, so the gate passes a release that broke the service;
//
//   a run-level error-rate threshold tolerates a complete outage lasting the
//   run length multiplied by the permitted rate, which makes a longer run a
//   weaker assertion rather than a stronger one.

import test from 'node:test';
import assert from 'node:assert/strict';

import { recorded, resetRecorder } from './support/k6-module.mjs';
import {
  CheckSuiteError,
  SUMMARY_TREND_STATS,
  assertSelectable,
  blindOutageSeconds,
  bodyContains,
  headerPresent,
  jsonFieldEquals,
  jsonFieldPresent,
  latencyUnder,
  statusIn,
  statusIs,
  suite,
  thresholdFindings,
  thresholds,
} from '../../scenarios/lib/checks.js';
import { stagePlan } from '../../scenarios/lib/stages.js';

const PLAN = stagePlan({ profileName: 'steady', ratePerWorker: 100, latencyCeilingMs: 250 });
const SPIKE_PLAN = stagePlan({ profileName: 'spike', ratePerWorker: 100, latencyCeilingMs: 250 });

/** A response good enough for every predicate in the module to pass. */
function response(overrides = {}) {
  const base = {
    status: 200,
    body: '{"items":[1],"id":"abc","state":"ready"}',
    headers: { 'Content-Type': 'application/json', 'X-Request-Id': 'q7' },
    timings: { duration: 10 },
  };
  const merged = { ...base, ...overrides };
  merged.json = () => JSON.parse(merged.body);
  return merged;
}

test('the upper percentiles are in the summary, because an objective is written in them', () => {
  for (const wanted of ['p(95)', 'p(99)', 'count']) {
    assert.ok(SUMMARY_TREND_STATS.includes(wanted), `the summary omits ${wanted}`);
  }
});

test('a check name that cannot be selected is refused before the run', () => {
  assert.equal(assertSelectable('status is 200'), 'status is 200');

  // Each of these produces a threshold that matches no samples, and a
  // threshold that matches no samples PASSES - so the assertion would be
  // unfailable rather than broken.
  const unselectable = [
    ['', 'empty'],
    ['   ', 'blank'],
    [' leading space', 'untrimmed'],
    ['trailing space ', 'untrimmed'],
    ['status:200', 'colon ends a selector'],
    ['read{fast}', 'brace ends a selector'],
    ['read,write', 'comma ends a selector'],
    ['item deadbeef', 'carries a value from the response'],
    [42, 'not a string'],
  ];
  for (const [name, why] of unselectable) {
    assert.throws(() => assertSelectable(name), CheckSuiteError, `accepted ${JSON.stringify(name)} (${why})`);
  }
});

test('a name built from an identifier is refused, because it grows the result set per request', () => {
  assert.throws(() => assertSelectable('order 0a1b2c3d4e'), (error) => {
    assert.match(error.message, /once per request/);
    return true;
  });
});

test('each predicate answers the question it is named for', () => {
  assert.equal(statusIs(200).predicate(response()), true);
  assert.equal(statusIs(200).predicate(response({ status: 503 })), false);

  assert.equal(statusIn([200, 201, 202]).predicate(response({ status: 202 })), true);
  assert.equal(statusIn([200, 201, 202]).predicate(response({ status: 204 })), false);
  assert.throws(() => statusIn([]), CheckSuiteError);

  // A status check alone is not a success check: an error document returned
  // with a success status passes every status check ever written.
  assert.equal(bodyContains('"state":"ready"').predicate(response()), true);
  assert.equal(bodyContains('"state":"ready"').predicate(response({ body: '{"state":"failed"}' })), false);
  assert.throws(() => bodyContains(''), CheckSuiteError);

  assert.equal(jsonFieldPresent('items').predicate(response()), true);
  assert.equal(jsonFieldPresent('items').predicate(response({ body: '{"items":null}' })), false);
  assert.equal(jsonFieldPresent('missing').predicate(response()), false);
  assert.equal(jsonFieldEquals('state', 'ready').predicate(response()), true);
  assert.equal(jsonFieldEquals('state', 'ready').predicate(response({ body: '{"state":"busy"}' })), false);

  // A body that is not JSON is a failed check rather than a thrown error: the
  // generator would count the throw as an iteration error and the result would
  // describe the generator rather than the target.
  assert.equal(jsonFieldPresent('items').predicate(response({ body: 'not json' })), false);

  assert.equal(headerPresent('content-type').predicate(response()), true);
  assert.equal(headerPresent('X-Missing').predicate(response()), false);

  assert.equal(latencyUnder(250).predicate(response({ timings: { duration: 10 } })), true);
  assert.equal(latencyUnder(250).predicate(response({ timings: { duration: 900 } })), false);
});

test('a JSON path is walked rather than evaluated', () => {
  // A path expression that can call anything turns a response body into
  // executable input.
  const nested = response({ body: '{"page":{"total":7}}' });
  assert.equal(jsonFieldEquals('page.total', 7).predicate(nested), true);
  assert.equal(jsonFieldEquals('page.total', 8).predicate(nested), false);
  assert.equal(jsonFieldPresent('page.total.deeper').predicate(nested), false);
  assert.equal(jsonFieldPresent('constructor').predicate(nested), false);
  assert.equal(jsonFieldPresent('__proto__.polluted').predicate(nested), false);
});

test('a suite refuses two checks under one name', () => {
  // Two checks under one name share a sub-metric, so one threshold covers
  // both and neither result can be read on its own.
  assert.throws(
    () => suite('read path', [statusIs(200), statusIs(200)]),
    (error) => {
      assert.match(error.message, /twice/);
      assert.match(error.message, /share a sub-metric/);
      return true;
    },
  );
});

test('a suite refuses to be empty or to hold something that is not a check', () => {
  assert.throws(() => suite('read path', []), CheckSuiteError);
  assert.throws(() => suite('read path', [{ name: 'x' }]), CheckSuiteError);
  assert.throws(() => suite('read,path', [statusIs(200)]), CheckSuiteError);
});

test('a suite asks for the response body only when one of its checks reads it', () => {
  const statusOnly = suite('status only', [statusIs(200), latencyUnder(250)]);
  assert.equal(statusOnly.readsBody, false);
  assert.equal(statusOnly.params().responseType, 'none');

  // Derived rather than declared: with bodies discarded a body-reading
  // predicate can never pass, so the suite carries the parameters its own
  // predicates require instead of leaving an author to remember them.
  const readsBody = suite('read path', [statusIs(200), jsonFieldPresent('items')]);
  assert.equal(readsBody.readsBody, true);
  assert.equal(readsBody.params().responseType, 'text');
});

test('suite parameters carry the suite tag and keep what the caller passed', () => {
  const checks = suite('read path', [statusIs(200)]);
  const params = checks.params({ timeout: '250ms', tags: { name: 'read listing', phase: 'steady' } });
  assert.equal(params.timeout, '250ms');
  assert.equal(params.responseType, 'none');
  assert.deepEqual(params.tags, { suite: 'read path', name: 'read listing', phase: 'steady' });
});

test('recording a suite records a result and does not throw on failure', () => {
  resetRecorder();
  const checks = suite('read path', [statusIs(200), jsonFieldPresent('items')]);

  assert.equal(checks.run(response(), { phase: 'steady' }), true);
  // The whole point: a failing check leaves the run running. The exit status
  // belongs to the thresholds, which is why the suite hands back both.
  assert.equal(checks.run(response({ status: 500, body: '{}' }), { phase: 'steady' }), false);

  assert.equal(recorded.checks.length, 2);
  assert.deepEqual(recorded.checks[1].tags, { suite: 'read path', phase: 'steady' });
  assert.deepEqual(recorded.checks[1].results, { 'status is 200': false, 'field items is present': false });
});

test('the outage a run-level error-rate threshold tolerates is the run length times the rate', () => {
  // It does not depend on the arrival rate, which is why a longer run is a
  // weaker assertion: 36 seconds of a one-hour run against a one-percent
  // threshold, and two and a half minutes of a four-hour soak.
  assert.equal(blindOutageSeconds(3600, 0.01), 36);
  assert.equal(blindOutageSeconds(14_400, 0.01), 144);
  assert.equal(blindOutageSeconds(600, 0), 0);
  assert.ok(blindOutageSeconds(7200, 0.01) > blindOutageSeconds(600, 0.01));

  assert.throws(() => blindOutageSeconds(0, 0.01), CheckSuiteError);
  assert.throws(() => blindOutageSeconds(600, 1), CheckSuiteError);
  assert.throws(() => blindOutageSeconds(600, -0.1), CheckSuiteError);
});

test('the latency threshold is scoped to the responses the target meant to send', () => {
  const checks = suite('read path', [statusIs(200)]);
  const built = thresholds({ suite: checks, plan: PLAN });

  // An error response is usually faster than a successful one, so a target
  // that starts failing fast makes an UNSCOPED percentile better. The figure
  // improves while the service degrades.
  const latencyKeys = Object.keys(built).filter((key) => key.startsWith('http_req_duration'));
  assert.deepEqual(latencyKeys, ['http_req_duration{expected_response:true,phase:steady}']);
  assert.deepEqual(built[latencyKeys[0]], ['p(95)<250']);
});

test('the latency ceiling in the threshold is the one the fleet was sized with', () => {
  const plan = stagePlan({ profileName: 'steady', ratePerWorker: 100, latencyCeilingMs: 400 });
  const built = thresholds({ suite: suite('read path', [statusIs(200)]), plan });
  // One number rather than two that agree today: a scenario willing to wait
  // longer than the sizing ceiling holds four-tuples past what the socket
  // budget was divided by.
  assert.deepEqual(built['http_req_duration{expected_response:true,phase:steady}'], ['p(95)<400']);
});

test('the error-rate abort is delayed by the ramp the plan actually has', () => {
  const checks = suite('read path', [statusIs(200)]);
  const built = thresholds({ suite: checks, plan: PLAN });
  const failed = built['http_req_failed{phase:steady}'];
  assert.equal(failed.length, 1);
  assert.equal(failed[0].threshold, 'rate<0.01');
  assert.equal(failed[0].abortOnFail, true);
  // Early in a run the sample is small enough that a handful of connection
  // errors exceed any rate, so an abort evaluated from the first second stops
  // runs that were about to be fine.
  assert.equal(failed[0].delayAbortEval, '130s');

  const spike = thresholds({ suite: checks, plan: SPIKE_PLAN });
  assert.equal(spike['http_req_failed{phase:baseline}'][0].delayAbortEval, '70s');
});

test('the abort can be turned off, and then carries no delay to misread', () => {
  const built = thresholds({
    suite: suite('read path', [statusIs(200)]),
    plan: PLAN,
    abortOnError: false,
  });
  assert.deepEqual(built['http_req_failed{phase:steady}'], [{ threshold: 'rate<0.01' }]);
});

test('every judged phase gets its own gates, and only the judged phases do', () => {
  const checks = suite('journey step', [statusIs(200), jsonFieldPresent('items')]);
  const built = thresholds({ suite: checks, plan: SPIKE_PLAN });
  const phases = new Set(
    Object.keys(built)
      .map((key) => /phase:([a-z]+)/.exec(key))
      .filter(Boolean)
      .map((match) => match[1]),
  );
  assert.deepEqual([...phases].sort(), ['baseline', 'recovery']);
  // Asserting a ceiling during the spike would make the profile unpassable by
  // construction, since the spike is the thing being provoked.
  assert.ok(!phases.has('spike'));
  assert.ok(!phases.has('ramp'));

  for (const phase of ['baseline', 'recovery']) {
    for (const name of checks.names) {
      assert.deepEqual(built[`checks{check:${name},phase:${phase}}`], ['rate>=0.99']);
    }
  }
});

test('dropped iterations are a count gate at zero, and are omitted rather than loosened', () => {
  const checks = suite('read path', [statusIs(200)]);

  // A run that dropped iterations did not offer the rate it reports, so the
  // comparison it was launched for is void regardless of what the target did.
  assert.deepEqual(thresholds({ suite: checks, plan: PLAN }).dropped_iterations, ['count<1']);
  assert.deepEqual(
    thresholds({ suite: checks, plan: PLAN, maxDropShare: 0.005 }).dropped_iterations,
    ['rate<0.005'],
  );

  // Omitted entirely where the executor cannot drop an iteration at all. A
  // threshold nothing can breach reads, to anyone auditing the run, exactly
  // like one that was checked.
  const closed = thresholds({ suite: checks, plan: PLAN, maxDropShare: null });
  assert.ok(!Object.prototype.hasOwnProperty.call(closed, 'dropped_iterations'));
});

test('a statistic the generator cannot parse is refused at build time', () => {
  // An unparseable statistic is rejected at startup rather than ignored, which
  // is the one good outcome available here - so it is caught earlier still.
  for (const bad of ['p95', '95', 'p(95', 'avg', 'p(ninety)']) {
    assert.throws(
      () => thresholds({ suite: suite('read path', [statusIs(200)]), plan: PLAN, latencyPercentile: bad }),
      CheckSuiteError,
      `accepted ${bad}`,
    );
  }
  assert.ok(thresholds({ suite: suite('read path', [statusIs(200)]), plan: PLAN, latencyPercentile: 'p(99.9)' }));
});

test('thresholds refuse a plan that judges nothing and a missing suite', () => {
  const noPhases = { ...PLAN, thresholdPhases: [] };
  assert.throws(() => thresholds({ suite: suite('read path', [statusIs(200)]), plan: noPhases }), CheckSuiteError);
  assert.throws(() => thresholds({ plan: PLAN }), CheckSuiteError);
});

test('the blind-outage window is published as a finding with its arithmetic', () => {
  const checks = suite('read path', [statusIs(200)]);
  const findings = thresholdFindings({ plan: PLAN, maxErrorRate: 0.01, suite: checks });
  const outage = findings.find((finding) => finding.code === 'C101');
  assert.ok(outage, 'the blind-outage window was not reported');
  // 600 seconds of judged time at one percent: six seconds of total outage
  // passes the gate.
  assert.match(outage.message, /6\.0s/);
  assert.equal(outage.severity, 'note');

  // A soak holds the objective for two hours, so the same permitted rate
  // tolerates 72 seconds of complete outage - which is why this is a warning
  // on a long run and a note on a short one.
  const soak = stagePlan({ profileName: 'soak', ratePerWorker: 100, latencyCeilingMs: 250 });
  const soakFindings = thresholdFindings({ plan: soak, maxErrorRate: 0.01, suite: checks });
  assert.equal(soakFindings.find((finding) => finding.code === 'C101').severity, 'warn');
});

test('a suite that reads bodies is noted, and no suite at all is an error', () => {
  const readsBody = suite('read path', [statusIs(200), jsonFieldPresent('items')]);
  const noted = thresholdFindings({ plan: PLAN, suite: readsBody });
  assert.ok(noted.some((finding) => finding.code === 'C102'));

  // Per-check thresholds over no checks cover nothing, and the run would
  // report a pass having asserted nothing per-check.
  const none = thresholdFindings({ plan: PLAN, suite: undefined });
  const missing = none.find((finding) => finding.code === 'C103');
  assert.ok(missing);
  assert.equal(missing.severity, 'error');
});
