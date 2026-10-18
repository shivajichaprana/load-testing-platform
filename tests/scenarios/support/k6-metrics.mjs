// Stand-ins for the generator's custom metric types.
//
// Recording only. A real Trend keeps a distribution so a threshold can be
// written against a percentile of it; nothing here needs the distribution,
// only the fact that a value was submitted with the tags that make it
// attributable to a phase.

const submissions = [];

export function recordedMetrics() {
  return submissions.slice();
}

export function resetMetrics() {
  submissions.length = 0;
}

class Metric {
  constructor(kind, name, isTime = false) {
    this.kind = kind;
    this.name = name;
    this.isTime = isTime;
  }

  add(value, tags = {}) {
    submissions.push({ kind: this.kind, name: this.name, value, tags: { ...tags } });
  }
}

export class Trend extends Metric {
  constructor(name, isTime) {
    super('trend', name, isTime);
  }
}

export class Counter extends Metric {
  constructor(name, isTime) {
    super('counter', name, isTime);
  }
}

export class Rate extends Metric {
  constructor(name) {
    super('rate', name);
  }
}

export class Gauge extends Metric {
  constructor(name, isTime) {
    super('gauge', name, isTime);
  }
}
