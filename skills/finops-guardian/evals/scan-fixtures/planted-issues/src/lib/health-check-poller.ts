// Fixture: an otherwise-RUNAWAY unbounded retry, explicitly suppressed via
// the suppression marker. Proves it actually silences the finding.
export async function pollHealthUntilKilled(fn: () => Promise<any>) {
  // finops-guardian-ignore: intentional unbounded poll, bounded externally by the container orchestrator's liveness probe timeout (ADR-014)
  while (true) {
    try {
      return await fn();
    } catch (error) {
      await sleep(5000);
    }
  }
}
