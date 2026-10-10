// A write path held at the fleet's objective, with each worker writing into
// its own slice of the key space.
//
// The partitioning is the point of this scenario as a worked example. It
// cannot come from the virtual user number, because every worker is a separate
// generator process and each numbers its users from one — so partitioning by
// that number has every worker writing the same keys, and a run that reports
// having exercised the whole key space while contending on a fraction of it.
// It cannot come from a launch override either: one launch request places
// identical tasks, so every task in the request receives the same overrides.
// The task's own metadata is the only per-worker fact inside the container, and
// when it cannot be read the scenario is refused rather than defaulted.

import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';

import {
  defaultEnv,
  endpoint,
  launchContext,
  metadataEndpoint,
  optionalNumber,
  optionalText,
  partitionIndex,
  requestTimeout,
  requireTargetBaseUrl,
  waitForStartInstant,
} from './lib/runtime.js';
import { phaseAt } from './lib/stages.js';
import { jsonFieldPresent, statusIn, suite } from './lib/checks.js';
import { openModelOptions } from './lib/options.js';

const env = defaultEnv();
const ctx = launchContext(env);
const baseUrl = requireTargetBaseUrl(env);
const writePath = optionalText(env, 'WRITE_PATH', '/items');
const keysPerPartition = optionalNumber(env, 'WRITE_KEYS_PER_PARTITION', 100000);

const writeChecks = suite('write path', [
  statusIn([200, 201, 202]),
  jsonFieldPresent('id'),
]);

const built = openModelOptions({
  suite: writeChecks,
  profileName: optionalText(env, 'PROFILE', 'steady'),
  ctx,
});

export const options = built.options;

function readTaskIdentity() {
  const metadata = metadataEndpoint(env);
  if (!metadata) return null;
  // This request carries no phase tag on purpose, so it sits outside every
  // phase-scoped threshold: a probe of the container's own metadata is not
  // part of the measurement and should not be able to fail the run's gates.
  const response = http.get(metadata, {
    timeout: '5s',
    responseType: 'text',
    tags: { name: 'task metadata' },
  });
  if (response.status !== 200) return null;
  try {
    const document = response.json();
    const arn = String(document.TaskARN || '');
    const taskId = arn.split('/').pop();
    return taskId ? { taskId } : null;
  } catch {
    return null;
  }
}

export function setup() {
  const start = waitForStartInstant(ctx, { sleep, now: () => Date.now() / 1000 });
  // Refuses when the identity is unreadable. Worth stating why the refusal is
  // better than a fallback: a fallback index is the same on every worker, so
  // the run would succeed, report full coverage of the key space, and have
  // contended on one partition of it the whole time.
  const partition = partitionIndex(readTaskIdentity(), ctx.workerCount);
  return {
    runId: ctx.runId,
    partition,
    keyBase: partition * keysPerPartition,
    start,
  };
}

export default function writePath_(data) {
  const elapsedMs = Date.now() - exec.scenario.startTime;
  const phase = phaseAt(elapsedMs, built.plan.windows);

  // Distinct per iteration within this worker's slice, and distinct across the
  // fleet because the slices do not overlap.
  const key = data.keyBase + (exec.scenario.iterationInInstance % keysPerPartition);
  const body = JSON.stringify({ key: `item-${key}`, value: elapsedMs });

  const response = http.post(
    endpoint(baseUrl, writePath),
    body,
    writeChecks.params({
      headers: {
        'Content-Type': 'application/json',
        // A retry that reaches the target twice must not create two records.
        // Without this the error rate and the record count disagree, and the
        // record count is the one a reader trusts.
        'Idempotency-Key': `${data.runId}-${key}`,
      },
      tags: { name: 'write item', phase },
      timeout: requestTimeout(ctx),
    }),
  );

  writeChecks.run(response, { phase });
}
