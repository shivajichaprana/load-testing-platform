// The launch contract: what a worker is given, and what it may not be used
// for.
//
// Two values in the contract are the reason the module exists at all, and both
// are asserted here. The rate share is THIS worker's share and not the fleet's
// objective, so a scenario that reads the objective as its own arrival rate
// makes a fleet of N offer N times the load the run reports asking for -
// and nothing in the result says so. The latency ceiling is the figure the
// fleet was SIZED with, so a scenario that states its own can hold four-tuples
// longer than the socket budget was divided by, and the run then ends in
// address-unavailable errors with a passing latency figure attached.

import test from 'node:test';
import assert from 'node:assert/strict';

import { CONTRACT, contractEnv } from './support/contract.mjs';
import {
  LaunchContractError,
  defaultEnv,
  endpoint,
  launchContext,
  metadataEndpoint,
  optionalNumber,
  optionalText,
  partitionIndex,
  present,
  requestTimeout,
  requireTargetBaseUrl,
  stableIndex,
  startSkewSeconds,
  waitForStartInstant,
} from '../../scenarios/lib/runtime.js';

const BASE = 'https://target.example.invalid';

test('a complete contract parses into the figures the plan is built from', () => {
  const ctx = launchContext(contractEnv());
  assert.equal(ctx.runId, CONTRACT.runId);
  assert.equal(ctx.workerCount, CONTRACT.workerCount);
  assert.equal(ctx.ratePerWorker, CONTRACT.ratePerWorker);
  assert.equal(ctx.latencyCeilingMs, CONTRACT.latencyCeilingMs);
  assert.equal(ctx.tupleBudget, CONTRACT.tupleBudget);
  assert.equal(ctx.connectionReuse, true);
  assert.equal(ctx.artifactBucket, 'example-run-artifacts');
  // Derived, and for the run's record only: it is what the fleet offers if
  // every worker was placed, which the launcher reconciles separately.
  assert.equal(ctx.fleetRate, CONTRACT.ratePerWorker * CONTRACT.workerCount);
  assert.ok(Object.isFrozen(ctx));
});

test('every required contract value is required', () => {
  const required = [
    'RUNNER_RUN_ID',
    'RUNNER_START_EPOCH',
    'RUNNER_WORKER_COUNT',
    'RUNNER_RATE_SHARE',
    'RUNNER_LOAD_MODEL',
    'RUNNER_CONNECTION_REUSE',
    'RUNNER_STOP_TIMEOUT_SECONDS',
    'RUNNER_LATENCY_CEILING_MS',
    'RUNNER_TUPLE_BUDGET',
    'RUNNER_METRIC_NAMESPACE',
    'RUNNER_PARAMETER_PREFIX',
    'RUNNER_ARTIFACT_PREFIX',
  ];
  for (const key of required) {
    assert.throws(
      () => launchContext(contractEnv({ [key]: undefined })),
      (error) => {
        assert.ok(error instanceof LaunchContractError);
        assert.match(error.message, new RegExp(key));
        return true;
      },
      `${key} was not required`,
    );
    // An empty string is the task definition's way of sending nothing, so it
    // is absent rather than a configured empty name.
    assert.throws(() => launchContext(contractEnv({ [key]: '   ' })), LaunchContractError);
  }
});

test('the artifact bucket is optional, and its absence is a value', () => {
  assert.equal(launchContext(contractEnv({ RUNNER_ARTIFACT_BUCKET: undefined })).artifactBucket, null);
  assert.equal(launchContext(contractEnv({ RUNNER_ARTIFACT_BUCKET: '' })).artifactBucket, null);
});

test('a numeric contract value is a number or a fault, never a prefix of one', () => {
  // `parseFloat` reads a leading number out of any string and discards the
  // rest, so a thousands separator would arrive as 40 and a unit suffix would
  // be silently dropped.
  for (const bad of ['40,000', '250ms', 'many', '', '1e']) {
    assert.throws(() => launchContext(contractEnv({ RUNNER_RATE_SHARE: bad })), LaunchContractError, bad);
  }
  assert.equal(launchContext(contractEnv({ RUNNER_RATE_SHARE: '12.5' })).ratePerWorker, 12.5);
  // Whole numbers where the value counts things.
  assert.throws(() => launchContext(contractEnv({ RUNNER_WORKER_COUNT: '2.5' })), LaunchContractError);
  assert.throws(() => launchContext(contractEnv({ RUNNER_WORKER_COUNT: '0' })), LaunchContractError);
  assert.throws(() => launchContext(contractEnv({ RUNNER_STOP_TIMEOUT_SECONDS: '1' })), LaunchContractError);
  assert.throws(() => launchContext(contractEnv({ RUNNER_STOP_TIMEOUT_SECONDS: '240' })), LaunchContractError);
});

test('a boolean contract value is compared exactly, with no permissive reading', () => {
  assert.equal(launchContext(contractEnv({ RUNNER_CONNECTION_REUSE: 'false' })).connectionReuse, false);
  // The only producer renders it lowercase, so anything else is a hand-edit -
  // and a hand-edit read as permissive here changes how many connections a
  // worker may hold, which is a sizing input rather than a preference.
  for (const bad of ['TRUE', 'True', 'yes', '1', 'on']) {
    assert.throws(() => launchContext(contractEnv({ RUNNER_CONNECTION_REUSE: bad })), LaunchContractError, bad);
  }
});

test('the load model is one of the two the library implements', () => {
  assert.equal(launchContext(contractEnv({ RUNNER_LOAD_MODEL: 'closed' })).loadModel, 'closed');
  assert.throws(() => launchContext(contractEnv({ RUNNER_LOAD_MODEL: 'stress' })), LaunchContractError);
});

test('the request timeout is the sizing ceiling and not a figure of its own', () => {
  const ctx = launchContext(contractEnv());
  assert.equal(requestTimeout(ctx), '250ms');
  // A request allowed to outlive the ceiling occupies a socket for longer than
  // the arithmetic assumed; one abandoned below it is a different experiment.
  assert.equal(requestTimeout({ latencyCeilingMs: 400.2 }), '401ms');
});

test('the start barrier waits, reports lateness, and refuses a stale run', () => {
  const ctx = launchContext(contractEnv());
  const slept = [];
  const sleep = (seconds) => slept.push(seconds);

  const onTime = waitForStartInstant(ctx, { sleep, now: () => CONTRACT.startEpoch - 5 });
  assert.deepEqual(onTime, { waitedSeconds: 5, lateBySeconds: 0, onTime: true });
  assert.deepEqual(slept, [5]);

  // Negative skew is a measurement fact rather than an error: a worker placed
  // late cannot join the ramp where its peers are, and the record should say
  // by how much.
  const late = waitForStartInstant(ctx, { sleep, now: () => CONTRACT.startEpoch + 12 });
  assert.deepEqual(late, { waitedSeconds: 0, lateBySeconds: 12, onTime: false });
  assert.deepEqual(slept, [5], 'a late worker must not sleep');

  assert.equal(startSkewSeconds(ctx, CONTRACT.startEpoch - 30), 30);

  // A barrier that long is a stale run identifier or a clock disagreement, and
  // waiting it out would bill the whole fleet for the wait.
  assert.throws(
    () => waitForStartInstant(ctx, { sleep, now: () => CONTRACT.startEpoch - 100_000 }),
    LaunchContractError,
  );
  assert.throws(() => waitForStartInstant(ctx, { now: () => 0 }), LaunchContractError);
});

test('a path is joined onto the target address, never resolved against it', () => {
  assert.equal(endpoint(BASE, '/items'), `${BASE}/items`);
  assert.equal(endpoint(`${BASE}/api/`, '/v1/items'), `${BASE}/api/v1/items`);
  assert.equal(endpoint(BASE, '/items?limit=25'), `${BASE}/items?limit=25`);
  assert.equal(endpoint(BASE, ''), `${BASE}/`);
});

test('a path that would point the run at another host is refused', () => {
  // Either one silently measures a different site and reports every result
  // under this target's name.
  const hostile = [
    '//elsewhere.example.invalid/items',
    '/\\elsewhere.example.invalid/items',
    '/\t/elsewhere.example.invalid/items',
    '/\n/elsewhere.example.invalid/items',
    '/\r/elsewhere.example.invalid/items',
    'items',
    '../items',
  ];
  for (const path of hostile) {
    assert.throws(() => endpoint(BASE, path), LaunchContractError, `accepted ${JSON.stringify(path)}`);
  }
});

test('a target address that is not an http URL is refused', () => {
  for (const bad of ['not a url', 'ftp://files.example.invalid', 'file:///etc/hosts', '']) {
    assert.throws(() => endpoint(bad, '/items'), LaunchContractError, bad);
  }
  assert.equal(requireTargetBaseUrl(contractEnv()), BASE);
  assert.equal(requireTargetBaseUrl(contractEnv({ TARGET_BASE_URL: `${BASE}///` })), BASE);
  // A default would make a scenario runnable against nothing, and the run
  // would report every request failing to connect - which reads as the target
  // being down.
  assert.throws(() => requireTargetBaseUrl(contractEnv({ TARGET_BASE_URL: undefined })), LaunchContractError);
});

test('a worker that cannot read its own identity is refused a data partition', () => {
  // A default index is the worst available answer: it is silent, it is the
  // same on every worker, and the run then reports having covered a key space
  // it touched one slice of, N times over.
  for (const identity of [null, undefined, {}, { taskId: '' }, { taskId: '  ' }]) {
    assert.throws(() => partitionIndex(identity, 8), (error) => {
      assert.match(error.message, /refused rather than defaulted/);
      return true;
    });
  }
  assert.throws(() => partitionIndex({ taskId: 'abc' }, 0), LaunchContractError);
  assert.throws(() => partitionIndex({ taskId: 'abc' }, 2.5), LaunchContractError);
});

test('a partition index is stable, in range, and not derived from the user number', () => {
  const taskIds = [
    '1f2c3b4a5d6e7f80',
    '90abcdef12345678',
    'fedcba9876543210',
    '0011223344556677',
  ];
  for (const taskId of taskIds) {
    const first = partitionIndex({ taskId }, 8);
    assert.equal(partitionIndex({ taskId }, 8), first, 'the index must not move between calls');
    assert.ok(Number.isInteger(first) && first >= 0 && first < 8);
  }
  // Distinct identities should mostly land in distinct partitions. The
  // identifier is an opaque hexadecimal task id rather than a counter, so the
  // distribution is only approximately uniform and the test says so rather
  // than claiming evenness.
  const spread = new Set(taskIds.map((taskId) => partitionIndex({ taskId }, 8)));
  assert.ok(spread.size >= 2, 'every identity collided into one partition');
  assert.equal(stableIndex('', 4) >= 0, true);
});

test('the container metadata endpoint is built only when one was supplied', () => {
  // The task's own metadata is the only per-worker fact inside the container:
  // the user number restarts at one in every worker, and a launch override is
  // identical across every task in one request.
  assert.equal(metadataEndpoint({}), null);
  assert.equal(metadataEndpoint({ ECS_CONTAINER_METADATA_URI_V4: '' }), null);
  assert.equal(
    metadataEndpoint({ ECS_CONTAINER_METADATA_URI_V4: 'http://metadata.invalid/v4/self//' }),
    'http://metadata.invalid/v4/self/task',
  );
  assert.equal(
    metadataEndpoint({ ECS_CONTAINER_METADATA_URI: 'http://metadata.invalid/v3/self' }),
    'http://metadata.invalid/v3/self/task',
  );
});

test('an optional scenario input is absent when unset or empty', () => {
  const env = contractEnv({ READ_PATH: '/catalogue', READ_PAGE_SIZE: '50', EMPTY: '  ' });
  assert.equal(present('x'), true);
  assert.equal(present('  '), false);
  assert.equal(present(undefined), false);

  assert.equal(optionalText(env, 'READ_PATH', '/items'), '/catalogue');
  assert.equal(optionalText(env, 'EMPTY', '/items'), '/items');
  assert.equal(optionalText(env, 'ABSENT', null), null);

  assert.equal(optionalNumber(env, 'READ_PAGE_SIZE', 25), 50);
  assert.equal(optionalNumber(env, 'ABSENT', 25), 25);
  assert.throws(() => optionalNumber({ SIZE: 'lots' }, 'SIZE', 25), LaunchContractError);
});

test('the environment is read from the generator global when there is one', () => {
  const original = globalThis.__ENV;
  try {
    globalThis.__ENV = { RUNNER_RUN_ID: 'r-aaa111' };
    assert.equal(defaultEnv().RUNNER_RUN_ID, 'r-aaa111');
  } finally {
    if (original === undefined) delete globalThis.__ENV;
    else globalThis.__ENV = original;
  }
  // Passing one explicitly is what makes the whole contract testable without a
  // container, which is the reason the source is resolved rather than assumed.
  assert.equal(typeof defaultEnv(), 'object');
});
