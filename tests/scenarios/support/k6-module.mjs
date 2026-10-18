// Stand-ins for the generator's own modules, so the scenario library can be
// exercised without a generator.
//
// The point of substituting them rather than mocking at a higher level: the
// one behaviour this suite exists to pin down is that a CHECK records a result
// and does not fail the run, while a THRESHOLD decides the exit status. That
// distinction lives in the generator's `check`, so a test that replaced the
// library's own call sites would be asserting against its own invention.
//
// Each stand-in therefore reproduces only the contract the library relies on,
// and records what it was given so a test can assert on the call rather than
// on a return value. Nothing here simulates load, and nothing here decides a
// verdict - a stand-in that returned verdicts would be a second
// implementation of the thing under test.

/** Every `check()` call, in order, for a test to read back. */
export const recorded = {
  checks: [],
  trends: [],
  groups: [],
  sleeps: [],
};

/** Forget everything recorded so far. Called from a test's setup. */
export function resetRecorder() {
  recorded.checks.length = 0;
  recorded.trends.length = 0;
  recorded.groups.length = 0;
  recorded.sleeps.length = 0;
}

/**
 * The generator's `check`.
 *
 * Returns whether every predicate passed and NEVER throws, which is the
 * property the library is built around: a failing check leaves the run
 * running and the exit status to the thresholds.
 */
export function check(value, predicates, tags = {}) {
  const results = {};
  let allPassed = true;
  for (const [name, predicate] of Object.entries(predicates)) {
    let passed;
    try {
      passed = Boolean(predicate(value));
    } catch {
      // The generator counts a throwing predicate as a failed check rather
      // than as an error, so this does too.
      passed = false;
    }
    results[name] = passed;
    if (!passed) allPassed = false;
  }
  recorded.checks.push({ tags: { ...tags }, results, passed: allPassed });
  return allPassed;
}

/** Named grouping. It does not isolate: a throwing body propagates. */
export function group(name, body) {
  recorded.groups.push(name);
  return body();
}

export function sleep(seconds) {
  recorded.sleeps.push(seconds);
}

export function fail(message) {
  throw new Error(message);
}

export default { check, group, sleep, fail };
