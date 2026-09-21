// Fixture: Pattern 8 (per-item paid API call) — no batch endpoint used.
export async function enrichContacts(contacts: Contact[]) {
  for (const contact of contacts) {
    const enriched = await enrichmentApi.lookup(contact.email);
    await saveEnrichedContact(enriched);
  }
}
