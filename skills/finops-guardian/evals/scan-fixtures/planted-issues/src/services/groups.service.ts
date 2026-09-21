// Fixture: Pattern 1 — async array-map N+1, genuinely nested inside a for loop.
// Proves true nesting is still caught after the self-match fix.
export async function getGroupsWithNestedOrders(groups: Group[]) {
  for (const group of groups) {
    const results = await Promise.all(
      group.users.map(async (user) => ({
        ...user,
        orders: await orderRepository.findByUserId(user.id),
      }))
    );
    group.results = results;
  }
  return groups;
}
