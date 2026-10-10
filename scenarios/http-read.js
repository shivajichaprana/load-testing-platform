// A read path held at the fleet's objective.
//
// The scenario states what it asks of the target and what it considers a
// correct answer. Everything about the shape of the run — the rate, the ramp,
// the population, the thresholds and whether connections are reused — comes
// from the launch contract, so this file cannot disagree with the fleet it is
// running on.

import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';

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
import { jsonFieldPresent, latencyUnder, statusIs, suite } from './lib/checks.js';
import { openModelOptions } from './lib/options.js';

const env = defaultEnv();
const ctx = launchContext(env);
const baseUrl = requireTargetBaseUrl(env);
const listPath = optionalText(env, 'READ_PATH', '/items');
const pageSize = optionalNumber(env, 'READ_PAGE_SIZE', 25);

const readChecks = suite('read path', [
  statusIs(200),
  jsonFieldPresent('items'),
  latencyUnder(ctx.latencyCeilingMs),
]);

const built = openModelOptions({
  suite: readChecks,
  profileName: optionalText(env, 'PROFILE', 'steady'),
  ctx,
});

export const options = built.options;

export function setup() {
  // The barrier belongs here and not in a virtual user: a user that sleeps has
  // spent an iteration doing it, and the iteration is the unit the arrival rate
  // is expressed in.
  const start = waitForStartInstant(ctx, { sleep, now: () => Date.now() / 1000 });
  return {
    runId: ctx.runId,
    plan: {
      profile: built.plan.profileName,
      peakRate: built.plan.peakRate,
      duration: built.plan.totalDuration,
      population: built.plan.preAllocatedVUs,
    },
    start,
  };
}

export default function readPath() {
  // Elapsed time is taken from the scenario's own start instant rather than
  // from the run's. The run's includes the synchronized-start barrier above,
  // and that wait is a different length on every worker in the fleet — so the
  // same request would be tagged with a different phase on two workers, which
  // is the one thing a phase tag must not do.
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const phase = phaseAt(elapsedMs, built.plan.windows);

  const response = http.get(
    endpoint(baseUrl, `${listPath}?limit=${pageSize}`),
    readChecks.params({
      // A static name, so every page of this listing shares one sub-metric. The
      // URL carries a parameter, and tagging by URL would produce a metric per
      // distinct value and leave no name a threshold could be written against.
      tags: { name: 'read listing', phase },
      // The sizing ceiling, not a timeout of this scenario's own: a request
      // allowed to outlive it holds a socket the budget was not divided for.
      timeout: requestTimeout(ctx),
    }),
  );

  readChecks.run(response, { phase });
}
