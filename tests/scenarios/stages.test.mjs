// The arithmetic that turns a load profile into an executable plan.
//
// Every assertion here is on a quantity whose wrong value produces a run that
// COMPLETES and reports a result. That is the organising idea of the suite: a
// profile that fails to parse is caught by the first run anybody attempts,
// while a profile that offers a fifth of the load it claims, or whose
// percentile mixes the ramp into the hold, produces a clean green report of a
// measurement that was never taken. The second kind is what is pinned down
// below.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  PROFILES,
  PROFILE_NAMES,
  ProfileError,
  closedModelScenario,
  concurrencyAt,
  dropShare,
  formatDuration,
  impliedRate,
  maxVUsFor,
  openModelScenario,
  parseDuration,
  phaseAt,
  phaseDurations,
  phaseWindows,
  planFindings,
  preAllocatedVUsFor,
  resolveProfile,
  socketParity,
  stagePlan,
  stopBudget,
} from '../../scenarios/lib/stages.js';

const STEADY = Object.freeze({
  profileName: 'steady',
  ratePerWorker: 100,
  latencyCeilingMs: 250,
});

/** Finding codes present in a findings list, deduplicated and sorted. */
function codesOf(findings) {
  return [...new Set(findings.map((finding) => finding.code))].sort();
}

function severityOf(findings, code) {
  const found = findings.find((finding) => finding.code === code);
  return found === undefined ? null : found.severity;
}

test('every named profile drains to zero and names a phase it contains', () => {
  assert.ok(PROFILE_NAMES.length > 0, 'the library ships no profiles');
  for (const name of PROFILE_NAMES) {
    const profile = PROFILES[name];
    const last = profile.stages[profile.stages.length - 1];
    // An arrival-rate profile that ends at its peak ends with requests in
    // flight, and the stop cuts those off rather than waiting for them: the
    // final interval of every such run reports a burst of failures the target
    // never caused.
    assert.equal(last.share, 0, `profile ${name} does not drain to zero`);

    const phases = new Set(profile.stages.map((stage) => stage.phase));
    assert.ok(profile.thresholdPhases.length > 0, `profile ${name} judges no phase`);
    for (const phase of profile.thresholdPhases) {
      // A threshold scoped to a sub-metric with no samples PASSES, so a
      // profile naming a phase it never enters is a profile whose gates can
      // never fail.
      assert.ok(phases.has(phase), `profile ${name} judges the absent phase ${phase}`);
    }
  }
});

test('the spike profile is judged before and after the spike, never during it', () => {
  // Asserting a latency ceiling during the spike makes the profile unpassable
  // by construction, because the spike is the thing being provoked. The
  // answerable questions are whether the baseline was healthy and whether it
  // came back.
  assert.deepEqual(PROFILES.spike.thresholdPhases, ['baseline', 'recovery']);
  assert.ok(PROFILES.spike.stages.some((stage) => stage.phase === 'spike'));
});

test('an unknown profile is refused by name, with the available names', () => {
  assert.throws(() => resolveProfile('stress'), (error) => {
    assert.ok(error instanceof ProfileError);
    assert.match(error.message, /unknown profile "stress"/);
    for (const name of PROFILE_NAMES) assert.ok(error.message.includes(name));
    return true;
  });
});

test('a duration is read only with its unit stated', () => {
  assert.equal(parseDuration('250ms'), 250);
  assert.equal(parseDuration('90s'), 90_000);
  assert.equal(parseDuration('2m'), 120_000);
  assert.equal(parseDuration('1h30m'), 5_400_000);
  assert.equal(parseDuration(' 30s '), 30_000);

  // A bare number reads as seconds in one position and milliseconds in
  // another; the two differ by a factor of a thousand and both produce a run
  // that completes, so it is refused rather than guessed at.
  for (const bad of ['90', '', '   ', 's', '-5s', '1m 30s', '2w', 90, null, undefined]) {
    assert.throws(() => parseDuration(bad), ProfileError, `accepted ${JSON.stringify(bad)}`);
  }
});

test('a duration is rendered in the largest unit that divides it evenly', () => {
  assert.equal(formatDuration(3_600_000), '1h');
  assert.equal(formatDuration(120_000), '2m');
  assert.equal(formatDuration(750_000), '750s');
  assert.equal(formatDuration(30_000), '30s');
  assert.equal(formatDuration(1_500), '1500ms');
  assert.equal(formatDuration(0), '0s');
  assert.throws(() => formatDuration(-1), ProfileError);
});

test('a duration survives a round trip through both renderings', () => {
  for (const text of ['250ms', '20s', '2m', '1h', '750s']) {
    assert.equal(parseDuration(formatDuration(parseDuration(text))), parseDuration(text));
  }
});

test('concurrency is the arrival rate multiplied by the response time', () => {
  // The sizing equation. It is asserted here because the fleet size came out
  // of it: if the two disagree the fleet is sized for one experiment and the
  // workers are configured for another.
  assert.equal(concurrencyAt(100, 250), 25);
  assert.equal(concurrencyAt(0, 250), 0);
  assert.throws(() => concurrencyAt(-1, 250), ProfileError);
  assert.throws(() => concurrencyAt(100, 0), ProfileError);
});

test('the population is sized at the ceiling and never below one', () => {
  assert.equal(preAllocatedVUsFor(100, 250), 25);
  // Sized on the CEILING rather than on the expected latency. A population
  // sized on the expected figure has exactly enough users for the healthy
  // case, and the iterations it cannot start are dropped at the one moment
  // that is indistinguishable from the target recovering.
  assert.ok(preAllocatedVUsFor(100, 250) > preAllocatedVUsFor(100, 40));
  assert.equal(preAllocatedVUsFor(0.5, 250), 1);
  assert.equal(maxVUsFor(25, 1.25), 32);
  assert.equal(maxVUsFor(25, 1), 25);
  assert.throws(() => maxVUsFor(25, 0.9), ProfileError);
});

test('a dropped-iteration figure is a share of the intended work', () => {
  assert.equal(dropShare(0, 0), 0);
  assert.equal(dropShare(5, 95), 0.05);
  assert.equal(dropShare(1, 0), 1);
});

test('phase windows tile the run with no gap and no overlap', () => {
  const windows = phaseWindows(PROFILES.steady.stages);
  assert.equal(windows[0].startMs, 0);
  for (let i = 1; i < windows.length; i += 1) {
    assert.equal(windows[i].startMs, windows[i - 1].endMs);
    assert.equal(windows[i].durationMs, windows[i].endMs - windows[i].startMs);
  }
  assert.deepEqual(phaseDurations(windows), { ramp: 120_000, steady: 600_000, drain: 30_000 });
});

test('a phase boundary belongs to the stage that begins there', () => {
  const windows = phaseWindows(PROFILES.steady.stages);
  // Half-open intervals, so no instant belongs to two phases and none belongs
  // to neither. A percentile taken over a whole run mixes the ramp with the
  // hold, which are different loads, so the phase has to be attached to the
  // request as it is made.
  assert.equal(phaseAt(0, windows), 'ramp');
  assert.equal(phaseAt(119_999, windows), 'ramp');
  assert.equal(phaseAt(120_000, windows), 'steady');
  assert.equal(phaseAt(719_999, windows), 'steady');
  assert.equal(phaseAt(720_000, windows), 'drain');

  // Before the clock and past the end both resolve, because a null phase
  // becomes an untagged sub-metric that every scoped threshold ignores - and
  // a threshold with no samples passes.
  assert.equal(phaseAt(-1, windows), 'ramp');
  assert.equal(phaseAt(10_000_000, windows), 'drain');
  assert.throws(() => phaseAt(0, []), ProfileError);
});

test('a plan carries every figure it was derived from', () => {
  const plan = stagePlan({ ...STEADY });
  assert.equal(plan.targetUnit, 'requests/s');
  assert.deepEqual(plan.stages.map((stage) => stage.target), [100, 100, 0]);
  assert.deepEqual(plan.stages.map((stage) => stage.duration), ['2m', '10m', '30s']);
  assert.equal(plan.peakRate, 100);
  assert.equal(plan.preAllocatedVUs, 25);
  assert.equal(plan.maxVUs, 32);
  assert.equal(plan.peakConcurrency, 25);
  assert.equal(plan.totalDuration, '750s');
  assert.deepEqual(plan.thresholdPhases, ['steady']);
  // Frozen, because a plan mutated after the findings were computed is a plan
  // whose findings describe something else.
  assert.ok(Object.isFrozen(plan));
  assert.ok(Object.isFrozen(plan.stages[0]));
});

test('a stage target rounds down, and the shortfall is reported rather than absorbed', () => {
  const plan = stagePlan({ ...STEADY, profileName: 'staircase', ratePerWorker: 10.4 });
  // Rounding up could push the population past the four-tuple budget the
  // fleet size was derived by dividing, and that overshoot arrives as
  // address-unavailable errors recorded against the TARGET.
  assert.deepEqual(plan.stages.map((stage) => stage.target), [2, 5, 7, 10, 10, 0]);
  assert.equal(plan.stages[0].exactTarget, 2.6);

  const findings = planFindings(plan, { stopTimeoutSeconds: 120, tupleBudget: 64 });
  assert.ok(codesOf(findings).includes('L108'));
  assert.equal(severityOf(findings, 'L108'), 'warn');
  assert.match(findings.find((f) => f.code === 'L108').message, /10 requests\/s against a share of 10\.4000/);
});

test('a stage that rounds to no load at all is refused', () => {
  // Naming it is more use than a stage that silently offers nothing: the
  // remedy is a larger time unit, which the refusal says.
  assert.throws(
    () => stagePlan({ ...STEADY, profileName: 'staircase', ratePerWorker: 2 }),
    (error) => {
      assert.ok(error instanceof ProfileError);
      assert.match(error.message, /rounds to no load at all/);
      assert.match(error.message, /larger time unit/);
      return true;
    },
  );
});

test('a worker with no rate share is refused rather than given an empty plan', () => {
  for (const rate of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => stagePlan({ ...STEADY, ratePerWorker: rate }), ProfileError);
  }
});

test('scaling a profile keeps its shape and refuses a sub-second stage', () => {
  const half = stagePlan({ ...STEADY, durationScale: 0.5 });
  assert.deepEqual(half.stages.map((stage) => stage.duration), ['1m', '5m', '15s']);
  assert.equal(half.peakRate, 100, 'scaling time must not change the rate');

  assert.throws(() => stagePlan({ ...STEADY, profileName: 'smoke', durationScale: 0.01 }), ProfileError);
  assert.throws(() => stagePlan({ ...STEADY, durationScale: 0 }), ProfileError);
});

test('the open-model scenario is built from the plan and from nothing else', () => {
  const plan = stagePlan({ ...STEADY });
  const scenario = openModelScenario(plan, { tags: { suite_under_test: 'read' } });
  assert.equal(scenario.executor, 'ramping-arrival-rate');
  assert.equal(scenario.timeUnit, '1s');
  assert.equal(scenario.startRate, 0);
  assert.equal(scenario.preAllocatedVUs, plan.preAllocatedVUs);
  assert.equal(scenario.maxVUs, plan.maxVUs);
  assert.equal(scenario.gracefulStop, '30s');
  assert.deepEqual(scenario.stages, [
    { target: 100, duration: '2m' },
    { target: 100, duration: '10m' },
    { target: 0, duration: '30s' },
  ]);
  assert.equal(scenario.tags.load_model, 'open');
  assert.equal(scenario.tags.profile, 'steady');
  assert.equal(scenario.tags.suite_under_test, 'read');
});

test('a closed-model scenario refuses a target rate instead of converting it', () => {
  // The conversion is only valid at one response time, and the run exists to
  // find out what the response time is.
  assert.throws(
    () => closedModelScenario({ virtualUsers: 50, profileName: 'steady', latencyCeilingMs: 250, targetRate: 400 }),
    (error) => {
      assert.match(error.message, /cannot be given a target rate/);
      assert.match(error.message, /the model has to be open/);
      return true;
    },
  );
});

test('a closed-model plan publishes the rate it will offer rather than implying it', () => {
  const built = closedModelScenario({
    virtualUsers: 50,
    profileName: 'steady',
    latencyCeilingMs: 250,
    thinkTimeMs: 0,
  });
  assert.equal(built.plan.targetUnit, 'users');
  assert.equal(built.plan.peakUsers, 50);
  // Population divided by the circuit time. Published so that the run's record
  // does not leave a reader assuming the population was the rate.
  assert.equal(built.plan.impliedRateAtCeiling, 200);
  assert.equal(built.scenario.executor, 'ramping-vus');
  assert.equal(built.scenario.startVUs, 1);
  // Distinct from the graceful stop: this is how long a user being REMOVED
  // during a ramp down is given to finish, without which the ramp down cuts
  // requests off mid-flight.
  assert.equal(built.scenario.gracefulRampDown, '30s');
  assert.equal(built.scenario.tags.load_model, 'closed');

  for (const bad of [0, -1, 2.5, '50']) {
    assert.throws(
      () => closedModelScenario({ virtualUsers: bad, profileName: 'steady', latencyCeilingMs: 250 }),
      ProfileError,
    );
  }
});

test('the implied rate falls as the circuit lengthens', () => {
  assert.equal(impliedRate(50, 250, 0), 200);
  assert.equal(impliedRate(50, 250, 250), 100);
  // Which is why this model cannot hold a rate through a degradation: the rate
  // is an output of the response time, so it drops exactly when the target
  // slows.
  assert.ok(impliedRate(50, 1000, 0) < impliedRate(50, 250, 0));
  assert.throws(() => impliedRate(50, 0, 0), ProfileError);
});

test('the container stop timeout has to cover the graceful stop plus the flush', () => {
  const fits = stopBudget({ gracefulStopSeconds: 30, stopTimeoutSeconds: 120 });
  assert.equal(fits.requiredSeconds, 45);
  assert.equal(fits.spareSeconds, 75);
  assert.equal(fits.fits, true);

  // Two different budgets, and the second has to cover the first: otherwise
  // the process is killed in the middle of writing out the results of the run
  // that just completed.
  const tight = stopBudget({ gracefulStopSeconds: 30, stopTimeoutSeconds: 40 });
  assert.equal(tight.fits, false);
  assert.equal(tight.spareSeconds, -5);
});

test('socket parity is exact at socket-bound sizing and has margin otherwise', () => {
  // One virtual user holds one connection and one connection is one
  // four-tuple, so when the socket bound is the binding one the fleet size was
  // derived by dividing the budget by exactly this product.
  const exact = socketParity({ preAllocatedVUs: 64, tupleBudget: 64 });
  assert.equal(exact.fits, true);
  assert.equal(exact.spare, 0);
  assert.equal(exact.utilisation, 1);

  const margin = socketParity({ preAllocatedVUs: 25, tupleBudget: 64 });
  assert.ok(margin.utilisation < 1);

  const over = socketParity({ preAllocatedVUs: 65, tupleBudget: 64 });
  assert.equal(over.fits, false);
  assert.equal(over.spare, -1);
});

test('a healthy plan produces no finding that would stop a run', () => {
  const plan = stagePlan({ ...STEADY });
  const findings = planFindings(plan, { stopTimeoutSeconds: 120, tupleBudget: 64 });
  assert.deepEqual(findings.filter((finding) => finding.severity === 'error'), []);
  assert.deepEqual(codesOf(findings), []);
});

test('a population over the four-tuple budget is an error, and near it a warning', () => {
  const plan = stagePlan({ ...STEADY });
  assert.equal(plan.preAllocatedVUs, 25);

  const over = planFindings(plan, { stopTimeoutSeconds: 120, tupleBudget: 20 });
  assert.ok(codesOf(over).includes('L106'));
  assert.equal(severityOf(over, 'L106'), 'error');
  // The shortfall arrives as address-unavailable errors, which are recorded
  // against the target rather than against the generator.
  assert.match(over.find((f) => f.code === 'L106').message, /recorded against the target/);

  const near = planFindings(plan, { stopTimeoutSeconds: 120, tupleBudget: 26 });
  assert.ok(codesOf(near).includes('L107'));
  assert.equal(severityOf(near, 'L107'), 'warn');

  const clear = planFindings(plan, { stopTimeoutSeconds: 120, tupleBudget: 28 });
  assert.deepEqual(codesOf(clear), []);
});

test('a stop timeout too short to flush the results is an error', () => {
  const plan = stagePlan({ ...STEADY });
  const findings = planFindings(plan, { stopTimeoutSeconds: 40, tupleBudget: 64 });
  assert.ok(codesOf(findings).includes('L103'));
  assert.equal(severityOf(findings, 'L103'), 'error');
});

test('a plan judged on a phase it does not contain is an error', () => {
  const plan = stagePlan({ ...STEADY });
  const judgedOnMissing = { ...plan, thresholdPhases: ['soak'] };
  const findings = planFindings(judgedOnMissing, { stopTimeoutSeconds: 120, tupleBudget: 64 });
  assert.ok(codesOf(findings).includes('L101'));
  assert.equal(severityOf(findings, 'L101'), 'error');
  // Stated in the finding, because it is the reason the condition is an error
  // rather than a warning.
  assert.match(findings.find((f) => f.code === 'L101').message, /no samples PASSES/);
});

test('a profile that does not drain to zero is reported', () => {
  const plan = stagePlan({ ...STEADY });
  const undrained = {
    ...plan,
    stages: [...plan.stages.slice(0, 2)],
  };
  const findings = planFindings(undrained, { stopTimeoutSeconds: 120, tupleBudget: 64 });
  assert.ok(codesOf(findings).includes('L104'));
  assert.equal(severityOf(findings, 'L104'), 'warn');
});

test('a rate that cannot be held at the ceiling is an error, not a dropped iteration', () => {
  const plan = stagePlan({ ...STEADY });
  const starved = { ...plan, maxVUs: 10 };
  const findings = planFindings(starved, { stopTimeoutSeconds: 120, tupleBudget: 64 });
  assert.ok(codesOf(findings).includes('L105'));
  assert.equal(severityOf(findings, 'L105'), 'error');
  // Caught before the run, because during the run it arrives as a fall in
  // offered load at the moment the target begins to struggle.
  assert.match(findings.find((f) => f.code === 'L105').message, /dropped iterations/);
});
