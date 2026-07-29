const REPORT_SEQUENCE = Symbol.for("dotfiles.herdr.pi.report-sequence");

export function nextHerdrReportSequence(): number {
  const shared = globalThis as typeof globalThis & Record<symbol, number | undefined>;
  const current = shared[REPORT_SEQUENCE];
  // Reserve sub-millisecond slots while keeping fresh processes ordered by wall time.
  const wallClockFloor = Date.now() * 1000;
  const next = Math.max((current ?? 0) + 1, wallClockFloor);
  shared[REPORT_SEQUENCE] = next;
  return next;
}
