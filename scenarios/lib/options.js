// Composing a scenario's options from the launch contract.
//
// Everything here exists so that a scenario file states what it is testing and
// nothing about how the run is shaped: the shape is the fleet's, and a
// scenario that restates any part of it can disagree with the fleet it is
// running on. The three values a scenario is most tempted to restate are the
// arrival rate, the latency ceiling and whether connections are reused, and
// all three are sizing inputs — a scenario that contradicts one of them
// changes what the fleet can offer without changing what the fleet reports
// offering.

import { launchContext } from './runtime.js';
import {
  closedModelScenario,
  openModelScenario,
  planFindings,
  stagePlan,
} from './stages.js';
import { SUMMARY_TREND_STATS, thresholdFindings, thresholds } from './checks.js';

export class ScenarioOptionsError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ScenarioOptionsError';
  }
}

/**
 * The tags emitted on every sample.
 *
 * Stated explicitly rather than left at the default set, because one of them
 * is load-bearing: the latency threshold selects on `expected_response`, and a
 * threshold whose selector matches nothing passes. A default that changes
 * would therefore turn the latency gate off rather than break it.
 *
 * `url` is deliberately absent. A URL carrying an identifier produces one
 * sub-metric per distinct request, which grows the result set without bound
 * and leaves no name a threshold can be written against; `name` is the
 * grouped form and is what the thresholds use.
 */
export const SYSTEM_TAGS = Object.freeze([
  'proto',
  'subproto',
  'status',
  'method',
  'name',
  'group',
  'check',
  'error',
  'error_code',
  'tls_version',
  'scenario',
  'expected_response',
]);

function reportFindings(findings, { logger = console } = {}) {
  const errors = findings.filter((finding) => finding.severity === 'error');
  for (const finding of findings) {
    const line = `[${finding.code}] ${finding.severity}: ${finding.message}`;
    if (finding.severity === 'error') logger.error(line);
    else logger.warn(line);
  }
  if (errors.length > 0) {
    throw new ScenarioOptionsError(
      `${errors.length} finding(s) make this run unable to report a result it does not have: ` +
        `${errors.map((finding) => finding.code).join(', ')}. Refused before the run rather than ` +
        'after it, because each one produces a run that PASSES without having measured anything.',
    );
  }
}

/**
 * Options for an open-model scenario: arrivals at a rate, from this worker's
 * share of the fleet's objective.
 */
export function openModelOptions({
  suite: checkSuite,
  profileName = 'steady',
  ctx = launchContext(),
  durationScale = 1,
  populationHeadroom = 1.25,
  gracefulStopSeconds = 30,
  flushReserveSeconds = 15,
  maxErrorRate = 0.01,
  latencyPercentile = 'p(95)',
  minCheckPassRate = 0.99,
  maxDropShare = 0,
  scenarioName = 'load',
  logger = console,
}) {
  if (ctx.loadModel !== 'open') {
    throw new ScenarioOptionsError(
      `this scenario is open-model and the fleet was launched as ${ctx.loadModel}. The fleet was ` +
        'sized for the other model, so running this one on it offers a different load from the ' +
        'one the sizing arithmetic was published for.',
    );
  }

  const plan = stagePlan({
    profileName,
    ratePerWorker: ctx.ratePerWorker,
    latencyCeilingMs: ctx.latencyCeilingMs,
    durationScale,
    populationHeadroom,
    gracefulStopSeconds,
  });

  reportFindings(
    [
      ...planFindings(plan, {
        stopTimeoutSeconds: ctx.stopTimeoutSeconds,
        flushReserveSeconds,
        tupleBudget: ctx.tupleBudget,
      }),
      ...thresholdFindings({ plan, maxErrorRate, suite: checkSuite }),
    ],
    { logger },
  );

  return Object.freeze({
    plan,
    options: {
      scenarios: { [scenarioName]: openModelScenario(plan) },
      thresholds: thresholds({
        suite: checkSuite,
        plan,
        maxErrorRate,
        latencyPercentile,
        minCheckPassRate,
        maxDropShare,
      }),
      // Discarded by default and asked for per request by the suites that read
      // them. A retained body is held for the length of the iteration, so the
      // memory cost scales with the population — which is the figure sized
      // from the latency ceiling and therefore the largest one in the plan.
      discardResponseBodies: true,
      // From the contract, not from the scenario. Reuse removes one term from
      // the four-tuple occupancy a worker's socket budget was divided by, and
      // that term is one to two orders of magnitude larger than the rest of
      // it: a scenario switching reuse off changes the worker's ceiling by
      // that factor while the fleet still reports the size it derived.
      noConnectionReuse: !ctx.connectionReuse,
      summaryTrendStats: [...SUMMARY_TREND_STATS],
      systemTags: [...SYSTEM_TAGS],
      tags: { run_id: ctx.runId, profile: plan.profileName, load_model: 'open' },
    },
  });
}

/**
 * Options for a closed-model scenario: a fixed population, each user waiting
 * for its own response.
 *
 * The population is a scenario input here rather than a contract value,
 * because the contract carries a rate and this model does not take one. The
 * rate it will offer is computed and reported instead.
 */
export function closedModelOptions({
  suite: checkSuite,
  virtualUsers,
  profileName = 'steady',
  ctx = launchContext(),
  thinkTimeMs = 0,
  durationScale = 1,
  gracefulStopSeconds = 30,
  flushReserveSeconds = 15,
  maxErrorRate = 0.01,
  latencyPercentile = 'p(95)',
  minCheckPassRate = 0.99,
  scenarioName = 'journey',
  logger = console,
}) {
  if (ctx.loadModel !== 'closed') {
    throw new ScenarioOptionsError(
      `this scenario is closed-model and the fleet was launched as ${ctx.loadModel}.`,
    );
  }

  const built = closedModelScenario({
    virtualUsers,
    profileName,
    latencyCeilingMs: ctx.latencyCeilingMs,
    thinkTimeMs,
    durationScale,
    gracefulStopSeconds,
  });

  reportFindings(
    [
      ...planFindings(built.plan, {
        stopTimeoutSeconds: ctx.stopTimeoutSeconds,
        flushReserveSeconds,
        tupleBudget: ctx.tupleBudget,
      }),
      ...thresholdFindings({ plan: built.plan, maxErrorRate, suite: checkSuite }),
    ],
    { logger },
  );

  return Object.freeze({
    plan: built.plan,
    options: {
      scenarios: { [scenarioName]: built.scenario },
      thresholds: thresholds({
        suite: checkSuite,
        plan: built.plan,
        maxErrorRate,
        latencyPercentile,
        minCheckPassRate,
        // A closed-model executor starts no iteration it cannot run, so there
        // are no dropped iterations to threshold. The rate falling is the
        // model's own behaviour rather than a generator shortfall, which is
        // exactly why this model cannot answer a question about a rate.
        maxDropShare: null,
      }),
      discardResponseBodies: true,
      noConnectionReuse: !ctx.connectionReuse,
      summaryTrendStats: [...SUMMARY_TREND_STATS],
      systemTags: [...SYSTEM_TAGS],
      tags: { run_id: ctx.runId, profile: profileName, load_model: 'closed' },
    },
  });
}
