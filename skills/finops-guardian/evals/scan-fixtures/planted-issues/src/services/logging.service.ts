// Fixture: Pattern 4 (unbounded storage) — logs kept forever, no lifecycle policy.
export async function logInteraction(userId: string, prompt: string, response: string) {
  await db.interactionLogs.create({ userId, prompt, response, createdAt: new Date() });
}
