// A stand-in for the generator's execution context.
//
// `scenario.startTime` is the value the phase tag is derived from, and it is
// the scenario's own start rather than the run's on purpose: the run's start
// includes the synchronized-start barrier, whose length differs on every
// worker, so tagging from it would give the same request a different phase on
// two workers. A test sets this directly to place a request in a phase.

export const state = {
  scenarioStartTime: 0,
  iterationInInstance: 0,
  vuIdInTest: 1,
};

export function resetExecution(overrides = {}) {
  state.scenarioStartTime = overrides.scenarioStartTime ?? 0;
  state.iterationInInstance = overrides.iterationInInstance ?? 0;
  state.vuIdInTest = overrides.vuIdInTest ?? 1;
}

const exec = {
  get scenario() {
    return {
      startTime: state.scenarioStartTime,
      iterationInInstance: state.iterationInInstance,
      iterationInTest: state.iterationInInstance,
      name: 'load',
    };
  },
  get vu() {
    return { idInTest: state.vuIdInTest, idInInstance: state.vuIdInTest, iterationInScenario: 0 };
  },
  get instance() {
    return { vusActive: 1, iterationsCompleted: state.iterationInInstance };
  },
};

export default exec;
