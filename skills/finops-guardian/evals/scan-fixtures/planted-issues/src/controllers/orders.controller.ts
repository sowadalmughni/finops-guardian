// Fixture: Pattern 2 (accidental fan-out) — five sequential downstream calls
// added one integration at a time, none of them wrong in isolation.
async function onOrderCreated(order: Order) {
  await emailClient.send(order);
  await slackClient.notify(order);
  await eventBus.publish('order.created', order);
  await fetch(fulfillmentWebhookUrl, { method: 'POST', body: JSON.stringify(order) });
  await api.syncInventory(order);
}
