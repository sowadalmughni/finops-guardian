// Fixture: Pattern 1 (N+1 query) — a query fired inside a for-loop instead
// of a single eager-loaded join.
export async function getUsersWithOrders(users: User[]) {
  const enriched = [];
  for (const user of users) {
    const orders = await orderRepository.findByUserId(user.id);
    enriched.push({ ...user, orders });
  }
  return enriched;
}
