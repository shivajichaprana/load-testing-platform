// A multi-step journey under the closed model: a fixed population of users,
// each waiting for its own response and pausing between steps.
//
// This file answers a different question from the other two, and the
// difference is not a detail of configuration. Under this model the throughput
// is an OUTPUT — the population divided by the time one user spends on a
// circuit — so it falls as the target slows. The run therefore cannot hold a
// rate through a degradation, and asking it to is refused by the library
// rather than approximated. What it can report is what rate it offered, which
// it does, at the ceiling and as it goes.

import http from 'k6/http';
import exec from 'k6/execution';
import { group, sleep } from 'k6';
import { Trend } from 'k6/metrics';

import {
  defaultEnv,
  endpoint,
  launchContext,
  optionalNumber,
  optionalText,
  requestTimeout,
  requireTargetBaseUrl,
  waitForStartInstant,
} from './lib/runtime.js';
import { phaseAt } from './lib/stages.js';
import { jsonFieldPresent, statusIs, suite } from './lib/checks.js';
import { closedModelOptions } from './lib/options.js';

const env = defaultEnv();
const ctx = launchContext(env);
const baseUrl = requireTargetBaseUrl(env);
const thinkTimeMs = optionalNumber(env, 'THINK_TIME_MS', 2000);
const virtualUsers = optionalNumber(env, 'VIRTUAL_USERS', 50);

const stepChecks = suite('journey step', [statusIs(200), jsonFieldPresent('items')]);

const built = closedModelOptions({
  suite: stepChecks,
  virtualUsers,
  thinkTimeMs,
  profileName: optionalText(env, 'PROFILE', 'steady'),
  ctx,
});

export const options = built.options;

// The circuit time is what the model's throughput is divided by, so it is
// measured rather than assumed: the implied rate published before the run is
// computed at the latency ceiling, and this is what the circuit actually cost.
const circuitDuration = new Trend('journey_circuit_duration', true);

export function setup() {
  const start = waitForStartInstant(ctx, { sleep, now: () => Date.now() / 1000 });
  return {
    runId: ctx.runId,
    impliedRateAtCeiling: built.plan.impliedRateAtCeiling,
    users: built.plan.peakUsers,
    start,
  };
}

function step(name, path, phase) {
  const response = http.get(
    endpoint(baseUrl, path),
    stepChecks.params({ tags: { name, phase }, timeout: requestTimeout(ctx) }),
  );
  stepChecks.run(response, { phase, step: name });
  return response;
}

export default function journey() {
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const phase = phaseAt(elapsedMs, built.plan.windows);
  const startedAt = Date.now();

  // Groups name the steps in the result. They do not isolate them: a step that
  // fails does not stop the circuit, so a user continues into a step whose
  // precondition the previous one failed to establish. That is deliberate here
  // — the point is to keep offering the circuit — and it is why each step
  // carries its own name rather than being judged only through the group.
  group('browse', () => {
    step('browse listing', '/items', phase);
  });
  sleep(thinkTimeMs / 1000);

  group('search', () => {
    step('search items', '/items?q=load', phase);
  });
  sleep(thinkTimeMs / 1000);

  group('view', () => {
    step('view item', '/items/featured', phase);
  });

  // The think time is part of the circuit, because it is part of what the
  // population's rate is divided by. Excluding it would make the measured
  // circuit disagree with the published implied rate.
  circuitDuration.add(Date.now() - startedAt, { phase });
  sleep(thinkTimeMs / 1000);
}
