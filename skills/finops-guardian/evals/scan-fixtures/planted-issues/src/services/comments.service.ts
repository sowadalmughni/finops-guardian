// Fixture: Pattern 1 — async array-map N+1, NOT nested in another loop.
// Proves the nested-loop check doesn't self-match on the triggering line.
export async function getUsersWithComments(users: User[]) {
  const enriched = await Promise.all(
    users.map(async (user) => ({
      ...user,
      comments: await commentRepository.findByUserId(user.id),
    }))
  );
  return enriched;
}
