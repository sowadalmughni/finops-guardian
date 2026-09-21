// Fixture: Pattern 3 (runaway retry loop) — no maximum attempt count.
export async function retryUntilSuccess(fn: () => Promise<any>) {
  while (true) {
    try {
      return await fn();
    } catch (error) {
      await sleep(1000);
    }
  }
}
