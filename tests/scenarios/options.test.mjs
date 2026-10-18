// Composing a scenario's options from the launch contract.
//
// The composition exists so that a scenario file states what it is testing and
// nothing about how the run is SHAPED - the shape belongs to the fleet. Three
// values are the ones a scenario is most tempted to restate, and all three are
// sizing inputs: the arrival rate, the latency ceiling, and whether
// connections are reused. A scenario that contradicts one of them changes what
// the fleet can offer without changing what the fleet reports offering.
//
// The other half of this file is the refusal. A finding of error severity
// describes a run that would PASS without having measured anything, so it
// stops the run before it starts rather than being printed and ignored.

import test from 'node:test';
import assert from 'node:assert/strict';

import { CONTRACT, contractEnv, recordingLogger } from './support/contract.mjs';
import { ScenarioOptionsError, SYSTEM_TAGS, closedModelOptions, openModelOptions } from '../../scenarios/lib/options.js';
import { jsonFieldPresent, statusIs, suite } from '../../scenarios/lib/checks.js';
import { launchContext } from '../../scenarios/lib/runtime.js';

const READ_CHECKS = suite('read path', [statusIs(200), jsonFieldPresent('items')]);

function openCtx(overrides = {}) {
  return launchContext(contractEnv(overrides));
}

function closedCtx(overrides = {}) {
  return launchContext(contractEnv({ RUNNER_LOAD_MODEL: 'closed', ...overrides }));
}

test('the emitted tag set keeps the tag the latency threshold selects on', () => {
  // The latency gate selects on `expected_response`, and a threshold whose
  // selector matches nothing passes - so a default that changed would turn the
  // gate OFF rather than break it. Stating the set is what prevents that.
  assert.ok(SYSTEM_TAGS.includes('expected_response'));
  assert.ok(SYSTEM_TAGS.includes('name'));
  assert.ok(SYSTEM_TAGS.includes('check'));
  // Absent on purpose: a URL carrying an identifier produces one sub-metric
  // per distinct request, which grows the result set without bound and leaves
  // no name a threshold can be written against.
  assert.ok(!SYSTEM_TAGS.includes('url'));
});

test('open-model options carry the plan, the scenario and the thresholds together', () => {
  const logger = recordingLogger();
  const built = openModelOptions({ suite: READ_CHECKS, ctx: openCtx(), logger });

  assert.equal(built.plan.profileName, 'steady');
  assert.equal(built.plan.peakRate, CONTRACT.ratePerWorker);
  assert.equal(built.plan.preAllocatedVUs, 25);

  const scenario = built.options.scenarios.load;
  assert.equal(scenario.executor, 'ramping-arrival-rate');
  assert.equal(scenario.preAllocatedVUs, built.plan.preAllocatedVUs);
  assert.equal(scenario.maxVUs, built.plan.maxVUs);

  // The ceiling the fleet was sized with is the ceiling the run is judged by.
  assert.deepEqual(
    built.options.thresholds['http_req_duration{expected_response:true,phase:steady}'],
    [`p(95)<${CONTRACT.latencyCeilingMs}`],
  );
  assert.deepEqual(built.options.thresholds.dropped_iterations, ['count<1']);
  assert.equal(built.options.tags.run_id, CONTRACT.runId);
  assert.equal(built.options.tags.load_model, 'open');
  assert.ok(Object.isFrozen(built));
});

test('response bodies are discarded globally and asked for by the suites that read them', () => {
  const logger = recordingLogger();
  const built = openModelOptions({ suite: READ_CHECKS, ctx: openCtx(), logger });
  // A retained body is held for the length of the iteration, so the memory
  // cost scales with the population - the largest figure in the plan, because
  // it is sized from the latency ceiling.
  assert.equal(built.options.discardResponseBodies, true);
  assert.equal(READ_CHECKS.params().responseType, 'text');
});

test('connection reuse comes from the contract, never from the scenario', () => {
  const logger = recordingLogger();
  const reusing = openModelOptions({ suite: READ_CHECKS, ctx: openCtx(), logger });
  assert.equal(reusing.options.noConnectionReuse, false);

  // Reuse removes one term from the four-tuple occupancy the worker's socket
  // budget was divided by, and that term is one to two orders of magnitude
  // larger than the rest: a scenario switching it off changes the worker's
  // ceiling while the fleet still reports the size it derived.
  const fresh = openModelOptions({
    suite: READ_CHECKS,
    ctx: openCtx({ RUNNER_CONNECTION_REUSE: 'false' }),
    logger,
  });
  assert.equal(fresh.options.noConnectionReuse, true);
});

test('a scenario cannot be run on a fleet sized for the other load model', () => {
  const logger = recordingLogger();
  // The fleet was sized for one model, so running the other on it offers a
  // different load from the one the sizing arithmetic was published for.
  assert.throws(
    () => openModelOptions({ suite: READ_CHECKS, ctx: closedCtx(), logger }),
    (error) => {
      assert.ok(error instanceof ScenarioOptionsError);
      assert.match(error.message, /open-model/);
      return true;
    },
  );
  assert.throws(
    () => closedModelOptions({ suite: READ_CHECKS, virtualUsers: 50, ctx: openCtx(), logger }),
    ScenarioOptionsError,
  );
});

test('a finding that would make the run report an unearned pass stops it', () => {
  const logger = recordingLogger();
  // The container is killed before the graceful stop plus the flush can
  // complete, so the results of the run would be lost at the point they were
  // being written.
  assert.throws(
    () =>
      openModelOptions({
        suite: READ_CHECKS,
        ctx: openCtx({ RUNNER_STOP_TIMEOUT_SECONDS: '40' }),
        logger,
      }),
    (error) => {
      assert.ok(error instanceof ScenarioOptionsError);
      assert.match(error.message, /L103/);
      // Refused before the run rather than after it, because the finding
      // describes a run that passes without having measured anything.
      assert.match(error.message, /PASSES without having measured anything/);
      return true;
    },
  );
  assert.ok(logger.codes().includes('L103'));
});

test('a population over the worker socket budget stops the run as well', () => {
  const logger = recordingLogger();
  assert.throws(
    () => openModelOptions({ suite: READ_CHECKS, ctx: openCtx({ RUNNER_TUPLE_BUDGET: '20' }), logger }),
    ScenarioOptionsError,
  );
  assert.ok(logger.codes().includes('L106'));
});

test('a note is reported and does not stop the run', () => {
  const logger = recordingLogger();
  openModelOptions({ suite: READ_CHECKS, ctx: openCtx(), logger });
  // The blind-outage window and the retained-body cost are properties of the
  // objective the author chose, not faults introduced by a change: failing on
  // them would make a correct configuration unrunnable.
  assert.ok(logger.codes().includes('C101'));
  assert.ok(logger.codes().includes('C102'));
  assert.deepEqual(logger.lines.error, []);
});

test('a profile can be selected and scaled without touching the rate', () => {
  const logger = recordingLogger();
  const built = openModelOptions({
    suite: READ_CHECKS,
    ctx: openCtx(),
    profileName: 'staircase',
    durationScale: 0.5,
    logger,
  });
  assert.equal(built.plan.profileName, 'staircase');
  assert.equal(built.plan.peakRate, CONTRACT.ratePerWorker);
  assert.equal(built.options.scenarios.load.stages.length, 6);
});

test('closed-model options publish the rate they will offer and threshold no drops', () => {
  const logger = recordingLogger();
  const built = closedModelOptions({
    suite: READ_CHECKS,
    virtualUsers: 50,
    thinkTimeMs: 0,
    ctx: closedCtx(),
    logger,
  });

  assert.equal(built.plan.peakUsers, 50);
  assert.equal(built.plan.impliedRateAtCeiling, 200);
  assert.equal(built.options.scenarios.journey.executor, 'ramping-vus');
  assert.equal(built.options.tags.load_model, 'closed');

  // A closed-model executor starts no iteration it cannot run, so there are no
  // dropped iterations to threshold - and a threshold nothing can breach reads
  // like one that was checked.
  assert.ok(!Object.prototype.hasOwnProperty.call(built.options.thresholds, 'dropped_iterations'));
  assert.deepEqual(
    built.options.thresholds['http_req_duration{expected_response:true,phase:steady}'],
    [`p(95)<${CONTRACT.latencyCeilingMs}`],
  );
});

test('the think time is part of the circuit the implied rate is divided by', () => {
  const logger = recordingLogger();
  const brisk = closedModelOptions({ suite: READ_CHECKS, virtualUsers: 50, thinkTimeMs: 0, ctx: closedCtx(), logger });
  const paced = closedModelOptions({
    suite: READ_CHECKS,
    virtualUsers: 50,
    thinkTimeMs: 2000,
    ctx: closedCtx(),
    logger,
  });
  assert.ok(paced.plan.impliedRateAtCeiling < brisk.plan.impliedRateAtCeiling);
  assert.equal(paced.plan.thinkTimeMs, 2000);
});

test('the scenario key can be named, so a result set says which scenario it came from', () => {
  const logger = recordingLogger();
  const built = openModelOptions({ suite: READ_CHECKS, ctx: openCtx(), scenarioName: 'read', logger });
  assert.deepEqual(Object.keys(built.options.scenarios), ['read']);
});
