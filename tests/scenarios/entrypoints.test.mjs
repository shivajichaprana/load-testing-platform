// The committed scenarios, exercised end to end against stand-ins.
//
// The library tests above prove the arithmetic. This file proves the WIRING,
// which is a separate claim and the one that actually breaks: a scenario can
// use a correct library perfectly and still emit requests with no phase tag,
// in which case every phase-scoped threshold selects nothing, every one of
// them passes, and the run reports a clean result having asserted nothing.
//
// So each scenario is imported with a valid contract in place, its options are
// read back, and one iteration of its body is run against a client that
// records rather than requests. What is asserted is what the result set would
// be keyed by.

import test from 'node:test';
import assert from 'node:assert/strict';

import { contractEnv } from './support/contract.mjs';
import { recorded, resetRecorder } from './support/k6-module.mjs';
import { requests, resetClient } from './support/k6-http.mjs';
import { resetExecution, state } from './support/k6-execution.mjs';
import { recordedMetrics, resetMetrics } from './support/k6-metrics.mjs';
import { PROFILES } from '../../scenarios/lib/stages.js';

const TARGET = 'https://target.example.invalid';
const METADATA = 'http://metadata.invalid/v4/self';
// A placeholder account id and a synthetic task id: nothing here identifies a
// real deployment, and the value is only ever split on its last separator.
const TASK_ARN = 'arn:aws:ecs:us-east-2:123456789012:task/load-fleet/7c1b9a4e2f6d8b03';

const ITEMS_BODY = '{"items":[{"id":"i1"}],"id":"i1"}';
const ITEMS_RESPONSE = Object.freeze({
  status: 200,
  body: ITEMS_BODY,
  headers: { 'Content-Type': 'application/json' },
  timings: { duration: 18 },
});

/** Put the clock inside the judged phase of the steady profile. */
function placeInSteadyPhase() {
  resetExecution({ scenarioStartTime: Date.now() - 300_000 });
}

/** Phase tags seen on recorded requests, excluding untagged ones. */
function requestPhases() {
  return requests.map((request) => request.params?.tags?.phase);
}

function thresholdPhases(options) {
  return new Set(
    Object.keys(options.thresholds)
      .map((key) => /phase:([a-z]+)/.exec(key))
      .filter(Boolean)
      .map((match) => match[1]),
  );
}

let readPath;
let writePath;
let journey;

test('the open-model scenarios build their options from the contract', async () => {
  globalThis.__ENV = contractEnv({
    ECS_CONTAINER_METADATA_URI_V4: METADATA,
    PROFILE: 'steady',
  });
  readPath = await import('../../scenarios/http-read.js');
  writePath = await import('../../scenarios/http-write.js');

  for (const [name, module] of [['read', readPath], ['write', writePath]]) {
    const { options } = module;
    assert.equal(options.scenarios.load.executor, 'ramping-arrival-rate', name);
    assert.equal(options.discardResponseBodies, true, name);
    assert.equal(options.tags.load_model, 'open', name);
    assert.ok(options.systemTags.includes('expected_response'), name);
    // Present and at zero: a run that dropped iterations did not offer the
    // rate it reports, so its latency figures describe a smaller run.
    assert.deepEqual(options.thresholds.dropped_iterations, ['count<1'], name);
  }
});

test('no committed scenario scopes a threshold to a phase its plan does not contain', async () => {
  globalThis.__ENV = contractEnv({ RUNNER_LOAD_MODEL: 'closed' });
  journey = await import('../../scenarios/user-journey.js');

  const expected = new Set(PROFILES.steady.thresholdPhases);
  const present = new Set(PROFILES.steady.stages.map((stage) => stage.phase));
  for (const phase of expected) {
    assert.ok(present.has(phase), `the profile judges the absent phase ${phase}`);
  }

  for (const [name, module] of [['read', readPath], ['write', writePath], ['journey', journey]]) {
    // Every scenario defaults to the steady profile, so each one's gates must
    // be scoped to exactly the phases that profile is willing to be judged on.
    // A threshold scoped to a sub-metric with no samples PASSES, so a phase
    // that is named but never entered switches its own gate off and reports
    // green.
    assert.deepEqual([...thresholdPhases(module.options)].sort(), [...expected].sort(), name);
  }

  // The closed-model journey thresholds no drops, because its executor cannot
  // drop an iteration: the rate falling is the model's own behaviour.
  assert.ok(!Object.prototype.hasOwnProperty.call(journey.options.thresholds, 'dropped_iterations'));
  assert.equal(journey.options.scenarios.journey.executor, 'ramping-vus');
});

test('the read scenario tags its request with the phase it was made in', () => {
  resetRecorder();
  resetClient({ ...ITEMS_RESPONSE });
  placeInSteadyPhase();

  readPath.default();

  assert.equal(requests.length, 1);
  const [request] = requests;
  assert.equal(request.method, 'GET');
  assert.equal(request.url, `${TARGET}/items?limit=25`);
  // A static name, so every page of the listing shares one sub-metric: tagging
  // by URL would produce a metric per distinct parameter value and leave no
  // name a threshold could be written against.
  assert.equal(request.params.tags.name, 'read listing');
  assert.equal(request.params.tags.phase, 'steady');
  // The sizing ceiling, not a timeout of the scenario's own.
  assert.equal(request.params.timeout, '250ms');
  // The suite reads a JSON field, so it asks for the body even though the
  // options discard bodies globally.
  assert.equal(request.params.responseType, 'text');

  assert.equal(recorded.checks.length, 1);
  assert.equal(recorded.checks[0].passed, true);
  assert.equal(recorded.checks[0].tags.phase, 'steady');
  assert.equal(recorded.checks[0].tags.suite, 'read path');
});

test('a failing response is recorded and does not stop the iteration', () => {
  resetRecorder();
  resetClient({ status: 503, body: '{}', headers: {}, timings: { duration: 4 } });
  placeInSteadyPhase();

  // The exit status belongs to the thresholds. An iteration that threw would
  // be counted as a generator error, and the result would then describe the
  // generator rather than the target.
  assert.doesNotThrow(() => readPath.default());
  assert.equal(recorded.checks[0].passed, false);
  assert.equal(recorded.checks[0].results['status is 200'], false);
});

test('the read scenario tags a request made during the ramp as the ramp', () => {
  resetRecorder();
  resetClient({ ...ITEMS_RESPONSE });
  resetExecution({ scenarioStartTime: Date.now() - 1_000 });

  readPath.default();
  // Tagged honestly rather than excluded: the ramp's latency is a property of
  // the ramp shape, so it is kept out of the judged percentile by the
  // threshold's scope and not by discarding the sample.
  assert.equal(requestPhases()[0], 'ramp');
  assert.ok(!thresholdPhases(readPath.options).has('ramp'));
});

test('the write scenario refuses to run without a readable task identity', () => {
  resetRecorder();
  // The metadata probe answers, but with nothing a task id can be taken from.
  resetClient({ status: 500, body: '', headers: {}, timings: { duration: 2 } });

  // A fallback index is the same on every worker, so the run would succeed,
  // report full coverage of the key space, and have contended on one partition
  // of it the whole time.
  assert.throws(() => writePath.setup(), (error) => {
    assert.match(error.message, /refused rather than defaulted/);
    return true;
  });
});

test('the write scenario partitions by task identity and writes into its own slice', () => {
  resetRecorder();
  resetClient({
    status: 200,
    body: JSON.stringify({ TaskARN: TASK_ARN }),
    headers: { 'Content-Type': 'application/json' },
    timings: { duration: 3 },
  });

  const data = writePath.setup();
  assert.ok(Number.isInteger(data.partition));
  assert.ok(data.partition >= 0 && data.partition < 8, 'the partition must be inside the fleet');
  assert.equal(data.keyBase, data.partition * 100_000);

  // The metadata probe carries no phase tag on purpose: a probe of the
  // container's own metadata is not part of the measurement and must not be
  // able to fail the run's gates.
  const probe = requests[requests.length - 1];
  assert.equal(probe.url, `${METADATA}/task`);
  assert.equal(probe.params.tags.phase, undefined);

  resetClient({ ...ITEMS_RESPONSE });
  placeInSteadyPhase();
  state.iterationInInstance = 7;

  writePath.default(data);

  const [write] = requests;
  assert.equal(write.method, 'POST');
  assert.equal(write.url, `${TARGET}/items`);
  assert.equal(write.params.tags.name, 'write item');
  assert.equal(write.params.tags.phase, 'steady');
  // A retry that reaches the target twice must not create two records, or the
  // error rate and the record count disagree - and the record count is the one
  // a reader trusts.
  assert.equal(write.params.headers['Idempotency-Key'], `${data.runId}-${data.keyBase + 7}`);
  assert.equal(JSON.parse(write.body).key, `item-${data.keyBase + 7}`);
});

test('the journey records every step by name and measures its own circuit', () => {
  resetRecorder();
  resetMetrics();
  resetClient({ ...ITEMS_RESPONSE });
  placeInSteadyPhase();

  journey.default();

  assert.deepEqual(recorded.groups, ['browse', 'search', 'view']);
  assert.deepEqual(requestPhases(), ['steady', 'steady', 'steady']);
  // Each step carries its own name rather than being judged only through the
  // group: a failed step does not stop the circuit, so a user continues into a
  // step whose precondition the previous one failed to establish.
  assert.deepEqual(
    recorded.checks.map((entry) => entry.tags.step),
    ['browse listing', 'search items', 'view item'],
  );

  // The circuit time is what the model's throughput is divided by, so it is
  // measured rather than assumed - and the think time is part of it, because
  // excluding it would make the measured circuit disagree with the published
  // implied rate.
  const circuit = recordedMetrics().filter((entry) => entry.name === 'journey_circuit_duration');
  assert.equal(circuit.length, 1);
  assert.equal(circuit[0].tags.phase, 'steady');
  assert.deepEqual(recorded.sleeps, [2, 2, 2]);
});

test('the journey setup publishes the rate the population will offer', () => {
  resetRecorder();
  const data = journey.setup();
  assert.equal(data.users, 50);
  // Reported so the run's record does not leave a reader assuming the
  // population was the rate: 50 users on a 250ms ceiling plus 2s of think time
  // offer about 22 iterations per second, not 50.
  assert.ok(data.impliedRateAtCeiling > 0);
  assert.ok(data.impliedRateAtCeiling < 50);
});
