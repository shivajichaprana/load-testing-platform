// Load profiles, and the arithmetic that turns one into an executable plan.
//
// A profile is a shape, expressed as fractions of the rate this worker was
// given rather than as absolute rates. That is not a convenience: a profile
// holding an absolute rate is a profile that offers the whole fleet's
// objective from every worker in it.
//
// The derived figures below matter more than the shape.
//
//   Concurrency is arrival rate multiplied by response time. It is the same
//   equation the fleet size came out of, so the virtual user population a
//   worker pre-allocates is derived from the sizing ceiling and not from the
//   latency anyone expects. A population sized on the expected latency has
//   exactly enough users for the healthy case; when the target slows, the
//   generator cannot hold enough requests in flight to maintain the arrival
//   rate, and the iterations it cannot start are DROPPED. The offered load
//   then falls at the moment the target begins to struggle, which is the one
//   moment at which the fall is indistinguishable from the target recovering.
//
//   The drain stage is not politeness. An arrival-rate profile that ends at
//   its peak ends with requests in flight, and those requests are cut off by
//   the stop rather than answered, so the last interval of every run reports
//   a burst of failures the target never caused.

export class ProfileError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProfileError';
  }
}

/**
 * The named shapes.
 *
 * `share` is the arrival rate at the END of the stage, as a fraction of this
 * worker's share; the executor ramps linearly to it from the previous stage's
 * value. `phase` labels the stage so that a threshold can be scoped to it, and
 * `thresholdPhases` names the phases whose numbers the profile is willing to
 * be judged on.
 *
 * The spike profile is the reason that last field exists. Asserting a latency
 * ceiling during the spike makes the profile unpassable by construction — the
 * spike is the thing being provoked. What the profile can be judged on is
 * whether the baseline was healthy before it and whether it came back
 * afterwards, so those are the phases the thresholds are scoped to.
 */
export const PROFILES = Object.freeze({
  smoke: {
    description: 'A short run at a fraction of the objective, to prove the scenario executes.',
    stages: [
      { duration: '20s', share: 0.01, phase: 'ramp' },
      { duration: '40s', share: 0.01, phase: 'steady' },
      { duration: '10s', share: 0, phase: 'drain' },
    ],
    thresholdPhases: ['steady'],
  },
  steady: {
    description: 'Ramp to the objective and hold it. The default shape for a comparable run.',
    stages: [
      { duration: '2m', share: 1, phase: 'ramp' },
      { duration: '10m', share: 1, phase: 'steady' },
      { duration: '30s', share: 0, phase: 'drain' },
    ],
    thresholdPhases: ['steady'],
  },
  staircase: {
    description: 'Quarter steps to the objective, then hold, to locate where behaviour changes.',
    stages: [
      { duration: '2m', share: 0.25, phase: 'ramp' },
      { duration: '2m', share: 0.5, phase: 'ramp' },
      { duration: '2m', share: 0.75, phase: 'ramp' },
      { duration: '2m', share: 1, phase: 'ramp' },
      { duration: '5m', share: 1, phase: 'steady' },
      { duration: '30s', share: 0, phase: 'drain' },
    ],
    thresholdPhases: ['steady'],
  },
  soak: {
    description: 'The objective held long enough for accumulation to show: leaks, pools, caches.',
    stages: [
      { duration: '5m', share: 1, phase: 'ramp' },
      { duration: '120m', share: 1, phase: 'steady' },
      { duration: '1m', share: 0, phase: 'drain' },
    ],
    thresholdPhases: ['steady'],
  },
  spike: {
    description: 'A baseline, a sudden multiple of it, and the return. Judged on before and after.',
    stages: [
      { duration: '1m', share: 0.2, phase: 'ramp' },
      { duration: '3m', share: 0.2, phase: 'baseline' },
      { duration: '10s', share: 1, phase: 'spike' },
      { duration: '1m', share: 1, phase: 'spike' },
      { duration: '10s', share: 0.2, phase: 'spike' },
      { duration: '4m', share: 0.2, phase: 'recovery' },
      { duration: '30s', share: 0, phase: 'drain' },
    ],
    thresholdPhases: ['baseline', 'recovery'],
  },
});

export const PROFILE_NAMES = Object.freeze(Object.keys(PROFILES));

const DURATION_UNITS = Object.freeze({ ms: 1, s: 1000, m: 60000, h: 3600000 });

/**
 * A stage's target, as a whole number.
 *
 * The executor's target is a whole number of arrivals per time unit, so a
 * fractional share has to be rounded, and the DIRECTION of the rounding is a
 * decision rather than a detail.
 *
 * It rounds DOWN. Rounding up would be the generous reading - a stage never
 * offering less than its share - but it can push the population a worker holds
 * past the four-tuple budget the fleet size was derived by dividing, and that
 * overshoot arrives as address-unavailable errors recorded against the target.
 * Rounding down costs a fraction of one arrival per second per worker, which
 * is reported as a finding rather than absorbed.
 *
 * A positive share that rounds to nothing is refused. The remedy is a larger
 * time unit - the same rate expressed as arrivals per minute is a whole number
 * - and naming it is more use than a stage that silently offers no load.
 */
function scaleTarget(base, share, unit) {
  const exact = base * share;
  const target = Math.floor(exact);
  if (share > 0 && target < 1) {
    throw new ProfileError(
      `a stage at ${share} of ${base} ${unit} is ${exact.toFixed(4)}, which rounds to no load at ` +
        'all. The executor takes a whole number of arrivals per time unit, so express the rate ' +
        'in a larger time unit, or give this worker a larger share.',
    );
  }
  return target;
}

/**
 * Parse a duration in the generator's own notation.
 *
 * Strict on purpose. The generator accepts a unitless number as seconds in
 * some positions and milliseconds in others, so a bare number here is refused
 * rather than guessed at: the two readings differ by a factor of a thousand
 * and both produce a run that completes.
 */
export function parseDuration(text) {
  if (typeof text !== 'string' || text.trim() === '') {
    throw new ProfileError(`a duration must be a non-empty string; received ${JSON.stringify(text)}.`);
  }
  const trimmed = text.trim();
  const pattern = /([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)/g;
  let total = 0;
  let consumed = 0;
  let match;
  while ((match = pattern.exec(trimmed)) !== null) {
    if (match.index !== consumed) break;
    total += Number(match[1]) * DURATION_UNITS[match[2]];
    consumed = pattern.lastIndex;
  }
  if (consumed !== trimmed.length || total <= 0) {
    throw new ProfileError(
      `${JSON.stringify(text)} is not a duration. Write the unit explicitly, as in "90s", "2m" ` +
        'or "1h30m"; a bare number is refused because it reads as seconds in one position and ' +
        'milliseconds in another.',
    );
  }
  return total;
}

/** Whole seconds where it divides evenly, so a plan reads the way it was written. */
export function formatDuration(ms) {
  if (!Number.isFinite(ms) || ms < 0) throw new ProfileError('a duration must be a non-negative number of milliseconds.');
  if (ms % 1000 !== 0) return `${ms}ms`;
  const seconds = ms / 1000;
  if (seconds % 3600 === 0 && seconds !== 0) return `${seconds / 3600}h`;
  if (seconds % 60 === 0 && seconds !== 0) return `${seconds / 60}m`;
  return `${seconds}s`;
}

/**
 * Requests in flight at a given rate and response time.
 *
 * The sizing equation, in the generator's units. This is the same arithmetic
 * the fleet size came out of, deliberately: if the two disagree the fleet is
 * sized for one experiment and the workers are configured for another.
 */
export function concurrencyAt(ratePerSecond, responseTimeMs) {
  if (!Number.isFinite(ratePerSecond) || ratePerSecond < 0) {
    throw new ProfileError('the arrival rate must be a non-negative number.');
  }
  if (!Number.isFinite(responseTimeMs) || responseTimeMs <= 0) {
    throw new ProfileError('the response time must be greater than zero.');
  }
  return (ratePerSecond * responseTimeMs) / 1000;
}

/**
 * The population to pre-allocate.
 *
 * At the ceiling, never at the expected latency, and pre-allocated rather than
 * left to grow: a user allocated after the run has started is INITIALIZED
 * during the run, and the one moment the generator needs more of them is the
 * moment the target slowed down. The cost of that initialization then lands on
 * the measurement it was triggered by.
 */
export function preAllocatedVUsFor(peakRatePerSecond, latencyCeilingMs) {
  return Math.max(1, Math.ceil(concurrencyAt(peakRatePerSecond, latencyCeilingMs)));
}

/**
 * The ceiling on the population.
 *
 * Headroom over the pre-allocated figure, and no more. Its purpose is not to
 * rescue a run: it is to make the shortfall VISIBLE, as dropped iterations,
 * rather than let the generator quietly hold more requests in flight than the
 * socket budget the fleet was sized against allows.
 */
export function maxVUsFor(preAllocatedVUs, headroom = 1.25) {
  if (!Number.isFinite(headroom) || headroom < 1) {
    throw new ProfileError('the population headroom must be at least 1.');
  }
  return Math.max(preAllocatedVUs, Math.ceil(preAllocatedVUs * headroom));
}

/**
 * The share of a run's intended iterations that were never started.
 *
 * Reported as a share rather than a count because a count is not comparable
 * between two runs of different length or rate, and the whole purpose of a
 * baseline is comparison.
 */
export function dropShare(dropped, completed) {
  const total = dropped + completed;
  return total <= 0 ? 0 : dropped / total;
}

/** Resolve a profile by name, with the available names in the refusal. */
export function resolveProfile(name) {
  const profile = Object.prototype.hasOwnProperty.call(PROFILES, name) ? PROFILES[name] : undefined;
  if (!profile) {
    throw new ProfileError(
      `unknown profile ${JSON.stringify(name)}. Available: ${PROFILE_NAMES.join(', ')}.`,
    );
  }
  return profile;
}

/**
 * Cumulative windows for each stage, so a request can be tagged with the phase
 * it was made in.
 *
 * The generator has no built-in per-stage tag, and a percentile taken over a
 * whole run mixes the ramp with the hold. Those are different loads, so the
 * number describes neither — which is why the phase has to be attached to the
 * request as it is made.
 */
export function phaseWindows(stages) {
  let offset = 0;
  return Object.freeze(
    stages.map((stage) => {
      const durationMs = parseDuration(stage.duration);
      const window = Object.freeze({
        phase: stage.phase,
        startMs: offset,
        endMs: offset + durationMs,
        durationMs,
      });
      offset += durationMs;
      return window;
    }),
  );
}

/**
 * The phase an elapsed time falls in.
 *
 * Half-open intervals: a request made exactly at a boundary belongs to the
 * stage beginning there, so no instant belongs to two phases and no instant
 * belongs to none. Past the end of the last stage the run is draining whatever
 * the last stage was called, so the final phase is returned rather than null —
 * a null here would become an untagged sub-metric that every scoped threshold
 * ignores.
 */
export function phaseAt(elapsedMs, windows) {
  if (windows.length === 0) throw new ProfileError('a plan with no stages has no phases.');
  if (elapsedMs < 0) return windows[0].phase;
  for (const window of windows) {
    if (elapsedMs >= window.startMs && elapsedMs < window.endMs) return window.phase;
  }
  return windows[windows.length - 1].phase;
}

/** Total time in each phase, which is what the threshold arithmetic needs. */
export function phaseDurations(windows) {
  const totals = {};
  for (const window of windows) {
    totals[window.phase] = (totals[window.phase] || 0) + window.durationMs;
  }
  return Object.freeze(totals);
}

/**
 * A profile, resolved against this worker's rate share into something the
 * generator can execute, with every derived figure kept rather than recomputed
 * where it is used.
 */
export function stagePlan({
  profileName,
  ratePerWorker,
  latencyCeilingMs,
  durationScale = 1,
  populationHeadroom = 1.25,
  gracefulStopSeconds = 30,
}) {
  const profile = resolveProfile(profileName);
  if (!Number.isFinite(ratePerWorker) || ratePerWorker <= 0) {
    throw new ProfileError(
      'this worker has no positive rate share, so there is no arrival rate to ramp to. A share ' +
        'of zero means the fleet size and the objective disagree.',
    );
  }
  if (!Number.isFinite(durationScale) || durationScale <= 0) {
    throw new ProfileError('the duration scale must be greater than zero.');
  }

  const stages = profile.stages.map((stage) => {
    const scaledMs = Math.round(parseDuration(stage.duration) * durationScale);
    if (scaledMs < 1000) {
      throw new ProfileError(
        `scaling ${stage.duration} by ${durationScale} gives ${scaledMs}ms, below the one second ` +
          'the generator can express as a stage.',
      );
    }
    return Object.freeze({
      duration: formatDuration(scaledMs),
      target: scaleTarget(ratePerWorker, stage.share, 'requests/s'),
      exactTarget: ratePerWorker * stage.share,
      phase: stage.phase,
      share: stage.share,
    });
  });

  const windows = phaseWindows(stages);
  const peakRate = Math.max(...stages.map((stage) => stage.target));
  const preAllocatedVUs = preAllocatedVUsFor(peakRate, latencyCeilingMs);
  const totalMs = windows.length === 0 ? 0 : windows[windows.length - 1].endMs;

  return Object.freeze({
    profileName,
    description: profile.description,
    targetUnit: 'requests/s',
    stages,
    windows,
    phaseDurations: phaseDurations(windows),
    thresholdPhases: Object.freeze([...profile.thresholdPhases]),
    peakRate,
    ratePerWorker,
    latencyCeilingMs,
    preAllocatedVUs,
    maxVUs: maxVUsFor(preAllocatedVUs, populationHeadroom),
    gracefulStopSeconds,
    totalMs,
    totalDuration: formatDuration(totalMs),
    // What the generator will hold open at the peak if the target sits exactly
    // on the ceiling. Published because it is the figure the socket budget was
    // divided by, and a reader comparing the two should not have to derive it.
    peakConcurrency: concurrencyAt(peakRate, latencyCeilingMs),
  });
}

/**
 * The open model: arrivals at a stated rate, regardless of what comes back.
 *
 * This is the executor for a question of the form "what happens at N requests
 * per second". It is also the only model in which the rate is the input, which
 * is why it is the default.
 */
export function openModelScenario(plan, { exec = 'default', startRate = 0, tags = {} } = {}) {
  return Object.freeze({
    executor: 'ramping-arrival-rate',
    exec,
    startRate,
    timeUnit: '1s',
    preAllocatedVUs: plan.preAllocatedVUs,
    maxVUs: plan.maxVUs,
    stages: plan.stages.map((stage) => ({ target: stage.target, duration: stage.duration })),
    gracefulStop: `${plan.gracefulStopSeconds}s`,
    tags: Object.freeze({ load_model: 'open', profile: plan.profileName, ...tags }),
  });
}

/**
 * The rate a fixed population actually offers.
 *
 * An output and never an input: population divided by the time one user spends
 * on an iteration. It is highest when think time is zero, and it FALLS as the
 * target slows — which is why a closed-model run cannot hold a target rate
 * through a degradation, and why asking it to is refused below.
 */
export function impliedRate(virtualUsers, responseTimeMs, thinkTimeMs = 0) {
  const cycleMs = responseTimeMs + thinkTimeMs;
  if (!Number.isFinite(cycleMs) || cycleMs <= 0) {
    throw new ProfileError('the sum of response time and think time must be greater than zero.');
  }
  return (virtualUsers * 1000) / cycleMs;
}

/**
 * The closed model: a fixed population of users, each waiting for its own
 * response before issuing the next request.
 *
 * Answers "what happens to N concurrent users", which is a different question
 * with a different answer from the open model's. A stated target rate is
 * refused rather than converted into a population, because the conversion is
 * only valid at one response time and the run exists to find out what the
 * response time is.
 */
export function closedModelScenario({
  virtualUsers,
  profileName,
  latencyCeilingMs,
  thinkTimeMs = 0,
  durationScale = 1,
  targetRate = null,
  exec = 'default',
  gracefulStopSeconds = 30,
  gracefulRampDownSeconds = 30,
  tags = {},
}) {
  if (targetRate !== null) {
    throw new ProfileError(
      'a closed-model scenario cannot be given a target rate. Under this model the rate is an ' +
        'output — population divided by response time plus think time — so it falls exactly when ' +
        'the target slows down. If the question is about a rate, the model has to be open.',
    );
  }
  if (!Number.isInteger(virtualUsers) || virtualUsers < 1) {
    throw new ProfileError('the virtual user population must be a positive whole number.');
  }

  const profile = resolveProfile(profileName);
  const stages = profile.stages.map((stage) => {
    const scaledMs = Math.round(parseDuration(stage.duration) * durationScale);
    return Object.freeze({
      duration: formatDuration(scaledMs),
      target: scaleTarget(virtualUsers, stage.share, 'users'),
      exactTarget: virtualUsers * stage.share,
      phase: stage.phase,
      share: stage.share,
    });
  });
  const windows = phaseWindows(stages);
  const peakUsers = Math.max(...stages.map((stage) => stage.target));

  return Object.freeze({
    plan: Object.freeze({
      profileName,
      description: profile.description,
      targetUnit: 'users',
      stages,
      windows,
      phaseDurations: phaseDurations(windows),
      thresholdPhases: Object.freeze([...profile.thresholdPhases]),
      latencyCeilingMs,
      peakUsers,
      thinkTimeMs,
      gracefulStopSeconds,
      gracefulRampDownSeconds,
      totalMs: windows[windows.length - 1].endMs,
      totalDuration: formatDuration(windows[windows.length - 1].endMs),
      // Reported so that the run's record says what rate it offered rather than
      // leaving a reader to assume the population was the rate. Both bounds,
      // because the honest answer is a range: the ceiling is reached only if
      // every response arrives at the sizing ceiling.
      impliedRateAtCeiling: impliedRate(peakUsers, latencyCeilingMs, thinkTimeMs),
    }),
    scenario: Object.freeze({
      executor: 'ramping-vus',
      exec,
      startVUs: stages[0].target > 0 ? 1 : 0,
      stages: stages.map((stage) => ({ target: stage.target, duration: stage.duration })),
      gracefulStop: `${gracefulStopSeconds}s`,
      // Distinct from gracefulStop: this is how long a user being REMOVED
      // during a ramp down is given to finish. Without it the ramp down cuts
      // requests off mid-flight and the drain reports failures the target did
      // not cause.
      gracefulRampDown: `${gracefulRampDownSeconds}s`,
      tags: Object.freeze({ load_model: 'closed', profile: profileName, ...tags }),
    }),
  });
}

/**
 * Whether the run can flush what it has before the container is killed.
 *
 * Two different grace periods are in play and they are not the same budget.
 * The generator's graceful stop is how long it lets iterations finish after it
 * is told to stop; the container's stop timeout is how long the whole process
 * has before it is killed outright. The second has to cover the first plus the
 * flush, or the process is killed in the middle of writing out the results of
 * the run that just completed.
 */
export function stopBudget({ gracefulStopSeconds, stopTimeoutSeconds, flushReserveSeconds = 15 }) {
  const required = gracefulStopSeconds + flushReserveSeconds;
  return Object.freeze({
    gracefulStopSeconds,
    flushReserveSeconds,
    stopTimeoutSeconds,
    requiredSeconds: required,
    spareSeconds: stopTimeoutSeconds - required,
    fits: required <= stopTimeoutSeconds,
  });
}

/**
 * The population against the worker's connection budget.
 *
 * These two bounds are the same bound written twice, which is the reason the
 * sizing is sound rather than a coincidence: one virtual user holds one
 * connection and one connection is one four-tuple, so the population a worker
 * must hold to maintain its rate share at the ceiling is the arrival rate
 * multiplied by the ceiling — and when the socket bound is the binding one,
 * the fleet size was derived by dividing the budget by exactly that product.
 * The population then equals the budget, and the parity is exact.
 *
 * When the processor bound is binding instead, the population comes out BELOW
 * the budget and the difference is real margin. There is no configuration in
 * which it legitimately comes out above: a population over the budget means
 * the scenario intends to hold more connections than the worker has, which
 * arrives as address-unavailable errors attributed to the target.
 */
export function socketParity({ preAllocatedVUs, tupleBudget }) {
  return Object.freeze({
    preAllocatedVUs,
    tupleBudget,
    spare: tupleBudget - preAllocatedVUs,
    utilisation: tupleBudget === 0 ? Infinity : preAllocatedVUs / tupleBudget,
    fits: preAllocatedVUs <= tupleBudget,
  });
}

/** Findings about the plan. Codes are stable; the text is not. */
export function planFindings(plan, { stopTimeoutSeconds, flushReserveSeconds = 15, tupleBudget } = {}) {
  const findings = [];
  const durations = plan.phaseDurations;

  for (const phase of plan.thresholdPhases) {
    if (!durations[phase]) {
      findings.push({
        code: 'L101',
        severity: 'error',
        message:
          `profile ${plan.profileName} scopes its thresholds to the ${phase} phase, and no stage ` +
          'carries that phase. A threshold scoped to a sub-metric with no samples PASSES, so the ' +
          'run would report success without having evaluated anything.',
      });
    }
  }

  if (plan.preAllocatedVUs !== undefined && plan.preAllocatedVUs > plan.maxVUs) {
    findings.push({
      code: 'L102',
      severity: 'error',
      message: `the pre-allocated population (${plan.preAllocatedVUs}) exceeds the ceiling (${plan.maxVUs}).`,
    });
  }

  if (stopTimeoutSeconds !== undefined) {
    const budget = stopBudget({
      gracefulStopSeconds: plan.gracefulStopSeconds,
      stopTimeoutSeconds,
      flushReserveSeconds,
    });
    if (!budget.fits) {
      findings.push({
        code: 'L103',
        severity: 'error',
        message:
          `the graceful stop (${budget.gracefulStopSeconds}s) plus the flush reserve ` +
          `(${budget.flushReserveSeconds}s) needs ${budget.requiredSeconds}s, and the container is ` +
          `killed after ${budget.stopTimeoutSeconds}s. The results of the run would be lost at the ` +
          'point they were being written.',
      });
    }
  }

  const lastStage = plan.stages[plan.stages.length - 1];
  if (lastStage && lastStage.target > 0) {
    findings.push({
      code: 'L104',
      severity: 'warn',
      message:
        `profile ${plan.profileName} ends at ${lastStage.target} ${plan.targetUnit} rather than ` +
        'draining to zero. ' +
        'Requests in flight at the end are cut off by the stop rather than answered, so the last ' +
        'interval of every run reports failures the target did not cause.',
    });
  }

  if (plan.peakConcurrency !== undefined && plan.maxVUs !== undefined && plan.peakConcurrency > plan.maxVUs) {
    findings.push({
      code: 'L105',
      severity: 'error',
      message:
        `holding ${plan.peakRate}/s at the ${plan.latencyCeilingMs}ms ceiling needs ` +
        `${Math.ceil(plan.peakConcurrency)} users and the ceiling is ${plan.maxVUs}. The rate ` +
        'cannot be maintained at the ceiling, so the shortfall arrives as dropped iterations ' +
        'exactly when the target slows down.',
    });
  }

  const peakStage = plan.stages.find((stage) => stage.target === plan.peakRate || stage.target === plan.peakUsers);
  if (peakStage && peakStage.exactTarget > 0) {
    const loss = (peakStage.exactTarget - peakStage.target) / peakStage.exactTarget;
    if (loss > 0) {
      findings.push({
        code: 'L108',
        severity: loss > 0.01 ? 'warn' : 'note',
        message:
          `the peak stage offers ${peakStage.target} ${plan.targetUnit} against a share of ` +
          `${peakStage.exactTarget.toFixed(4)}, ${(loss * 100).toFixed(3)}% less, because the ` +
          'executor takes whole arrivals and the rounding is downward on purpose. Reported rather ' +
          'than absorbed: a fleet offering less than its objective while reporting the objective ' +
          'is the error this arithmetic exists to prevent.',
      });
    }
  }

  if (tupleBudget !== undefined && plan.preAllocatedVUs !== undefined) {
    const parity = socketParity({ preAllocatedVUs: plan.preAllocatedVUs, tupleBudget });
    if (!parity.fits) {
      findings.push({
        code: 'L106',
        severity: 'error',
        message:
          `holding ${plan.peakRate} ${plan.targetUnit} at the ${plan.latencyCeilingMs}ms ceiling ` +
          `needs ${parity.preAllocatedVUs} connections open at once and this worker's four-tuple ` +
          `budget is ${parity.tupleBudget}. The shortfall arrives as address-unavailable errors, ` +
          'which are recorded against the target rather than against the generator.',
      });
    } else if (parity.utilisation > 0.9) {
      findings.push({
        code: 'L107',
        severity: 'warn',
        message:
          `the peak population is ${(parity.utilisation * 100).toFixed(1)}% of this worker's ` +
          `four-tuple budget (${parity.preAllocatedVUs} of ${parity.tupleBudget}), leaving ` +
          `${parity.spare} spare. At full socket-bound sizing the two are equal by construction, ` +
          'so this is expected there and is worth checking anywhere else.',
      });
    }
  }

  return Object.freeze(findings);
}
