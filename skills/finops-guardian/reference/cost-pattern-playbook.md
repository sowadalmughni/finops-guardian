# Cost Pattern Playbook

Every pattern below includes what it looks like, why AI generates it, its cost curve classification, the dollar formula used to project impact, and the exact rewrite that flattens the curve.

Unit costs referenced here come from `../metrics/cloud-cost-heuristics.json`. All dollar figures are directional midpoints — state the assumption whenever you cite a number.

---

## Pattern 1: N+1 Query Cost Multiplication

**What it looks like:**
```typescript
const users = await userRepository.findAll();
const enriched = await Promise.all(
  users.map(async (user) => ({
    ...user,
    orders: await orderRepository.findByUserId(user.id),
  }))
);
```

**Why AI generates it:** The model resolves "get users with their orders" literally — fetch users, then resolve the relation per user. It does not reason about the aggregate query cost across the full result set.

**Classification:** LINEAR to QUADRATIC+. One query becomes N+1. If this pattern is nested inside another loop (e.g., resolving orders, then resolving line items per order), the cost curve becomes O(n²).

**Cost formula:**
```
total_queries = 1 + N
cost = total_queries * postgres_read_query.mid   ($0.0000005/query)

At N = 100:     101 queries  ≈ $0.00005 per page load — invisible
At N = 10,000:  10,001 queries ≈ $0.005 per page load
At N = 10,000 and 500 page loads/day: $2.50/day in raw query cost alone,
  PLUS connection pool exhaustion risk once concurrent N+1 loads exceed pool size.
```

**Documented case:** $12,000/month database cost spike from a single AI-generated admin dashboard using this exact pattern.

**Exact rewrite:**
```typescript
// AFTER — one query, or two with a batched IN clause
const users = await userRepository.find({ relations: ['orders'] }); // TypeORM
// or
const users = await prisma.user.findMany({ include: { orders: true } }); // Prisma
```

**Classification after fix:** CONSTANT relative to N (query count no longer scales with row count — it becomes 1-2 queries regardless of N, though result size still grows with N).

---

## Pattern 2: Accidental Fan-Out

**What it looks like:**
```typescript
async function onOrderCreated(order: Order) {
  await sendConfirmationEmail(order);        // external API call #1
  await notifySlackChannel(order);            // external API call #2
  await updateInventorySystem(order);         // external API call #3
  await syncToAnalytics(order);               // external API call #4
  await triggerFulfillmentWebhook(order);     // external API call #5
}
```

**Why AI generates it:** Each integration is added correctly in isolation, one prompt at a time — "also send a Slack notification," "also sync to analytics." No single addition looks wrong. The aggregate is five sequential external calls per event, each with its own latency, failure mode, and often its own cost.

**Classification:** LINEAR with a high multiplier per event. Becomes SUPRALINEAR to QUADRATIC+ if any of these downstream calls itself fans out further (e.g., the webhook triggers three more calls on the receiving end that loop back).

**Cost formula:**
```
cost_per_event = sum(cost of each downstream call)
total_cost = event_count * cost_per_event

If 3 of the 5 calls are paid third-party APIs at $0.01/call average:
cost_per_event ≈ $0.03
At 10,000 orders/month: $300/month just in fan-out API costs,
  before counting the compute cost of holding the request open across 5 sequential awaits.
```

**Exact rewrite:**
```typescript
// AFTER — parallelize independent calls, queue the non-critical ones
async function onOrderCreated(order: Order) {
  // Critical path: must complete before responding to the user
  await sendConfirmationEmail(order);

  // Non-critical: queue for async processing, don't block the response
  await eventQueue.publish('order.created', { orderId: order.id });
  // A worker consumes this queue and handles Slack, inventory, analytics,
  // and fulfillment independently — with its own retry and backoff policy.
}
```

**Classification after fix:** LINEAR with a much smaller multiplier on the critical path. The queued work still costs the same in aggregate but no longer blocks the request, and gains independent retry isolation — a failure in analytics sync no longer risks re-triggering the entire fan-out chain.

---

## Pattern 3: Runaway Retry Loop

**What it looks like:**
```typescript
async function retryUntilSuccess(fn: () => Promise<any>) {
  while (true) {
    try {
      return await fn();
    } catch {
      await sleep(1000);
      // no maximum attempt count
    }
  }
}
```

**Why AI generates it:** "Retry on failure" is a common and reasonable-sounding instruction. Without an explicit maximum attempt count in the prompt, the model produces the simplest version: retry forever. This works perfectly in every test, because tests do not simulate a dependency that never recovers.

**Classification:** RUNAWAY. This is not a scale problem — it is a cap problem. A single dependency outage triggers unlimited retries, unlimited compute consumption, and if the wrapped function makes a paid API call, unlimited spend, regardless of how much traffic the rest of the system has.

**Cost formula:**
```
cost = retries_until_manual_intervention * cost_per_attempt

If cost_per_attempt includes a $0.01 third-party API call and the dependency
is down for 6 hours before anyone notices, at 1 retry/second:
21,600 attempts * $0.01 = $216 from ONE stuck retry loop, on ONE request.
If this pattern exists on a webhook handler processing 50 events during that outage:
50 * $216 = $10,800 from a single incident.
```

**Documented case:** Agentic workflows and serverless retry logic with no maximum attempt cap have been observed silently burning through compute and token budgets before anyone notices.

**Exact rewrite:**
```typescript
// AFTER — bounded retries with exponential backoff
async function withRetry<T>(
  fn: () => Promise<T>,
  maxAttempts = 3,
  baseDelayMs = 1000
): Promise<T> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt === maxAttempts) {
        logger.error('Max retry attempts exhausted', { attempt, error });
        throw error;
      }
      const delay = baseDelayMs * 2 ** (attempt - 1);
      await sleep(delay);
    }
  }
  throw new Error('unreachable');
}
```

**Classification after fix:** CONSTANT — worst case cost is now `maxAttempts * cost_per_attempt`, a fixed ceiling regardless of how long the dependency stays down.

---

## Pattern 4: Unbounded Storage Growth

**What it looks like:**
```typescript
async function logInteraction(userId: string, prompt: string, response: string) {
  await db.interactionLogs.create({
    data: { userId, prompt, response, createdAt: new Date() },
  });
  // No TTL, no archival policy, no size cap — every interaction stored forever
}
```

**Why AI generates it:** Logging every interaction is a reasonable default for debugging and analytics during development. The model has no signal about the difference between "log this for a week" and "this table will hold 50 million rows in year two."

**Classification:** LINEAR in principle, but functionally unbounded because there is no retention policy — the growth never stops, and cost compounds every month on top of the previous month's accumulated storage.

**Cost formula:**
```
Assume 10,000 interactions/day, average 2KB per record (prompt + response text):
daily_growth = 10,000 * 2KB = 20MB/day = ~600MB/month
Cumulative storage cost compounds: by month 12, ~7.2GB accumulated.
At database_storage_gb_month.mid ($0.20/GB): ~$1.44/month by year one — modest alone,
but this scales with EVERY table using this pattern, and query performance on an
unindexed, ever-growing table degrades independently of the storage cost itself.
```

**Documented case:** AI infrastructure scaffolding defaulting to unbounded storage models — saving every user prompt, AI output, and attachment indefinitely with no expiry policy.

**Exact rewrite:**
```typescript
// AFTER — explicit retention policy with archival
async function logInteraction(userId: string, prompt: string, response: string) {
  await db.interactionLogs.create({
    data: { userId, prompt, response, createdAt: new Date() },
  });
}

// Scheduled job — archive or delete records older than the retention window
async function enforceRetentionPolicy() {
  const cutoff = subDays(new Date(), 90); // 90-day retention, adjust to actual need
  const oldRecords = await db.interactionLogs.findMany({
    where: { createdAt: { lt: cutoff } },
  });
  if (oldRecords.length > 0) {
    await archiveToColdStorage(oldRecords); // cheaper storage tier, if retention is needed
    await db.interactionLogs.deleteMany({ where: { createdAt: { lt: cutoff } } });
  }
}
```

**Classification after fix:** CONSTANT ceiling — storage cost plateaus at `retention_window * daily_growth` instead of growing indefinitely.

---

## Pattern 5: Lazy Auto-Scaling

**What it looks like:** Autoscaling configuration with no maximum instance count, or reactive scaling with no cooldown period, deployed as the platform default without adjustment.

```yaml
# Serverless config — no concurrency limit set
functions:
  processWebhook:
    handler: handler.processWebhook
    # No reservedConcurrency, no maximum instance cap
```

**Why AI generates it:** Cloud platform defaults are permissive by design, optimized for "it just works" rather than cost containment. A generated infrastructure config inherits the platform default, which is usually unbounded or very high.

**Classification:** SUPRALINEAR under normal conditions, escalating to RUNAWAY when combined with a retry storm or fan-out bug — this is the multiplier pattern where two FinOps risks compound each other. A retry loop with no cap, running on infrastructure with no concurrency cap, produces the worst version of both problems simultaneously.

**Cost formula:**
```
cost = peak_concurrent_instances * container_vcpu_hour.mid * incident_duration_hours

Example: a retry storm during a dependency outage spikes concurrency to 500 instances
for 2 hours, at $0.04/vCPU-hour:
500 * $0.04 * 2 = $40 in compute alone, on top of whatever the retries themselves cost
via Pattern 3 above. These two patterns compound multiplicatively when both are present.
```

**Documented case:** Lazy auto-scaling policies with no upper bound compounding with retry storms or fan-out bugs to produce combinatorial cost multiplication during incidents.

**Exact rewrite:**
```yaml
functions:
  processWebhook:
    handler: handler.processWebhook
    reservedConcurrency: 50    # explicit ceiling
    timeout: 30                # prevent hung invocations from holding capacity
```

**Classification after fix:** LINEAR with an explicit, known ceiling — worst-case cost is now calculable in advance rather than open-ended.

---

## Pattern 6: Missing Cache on Expensive Repeated Operations

**What it looks like:**
```typescript
@Get('dashboard-summary')
async getDashboardSummary() {
  // Complex aggregation JOIN across 4 tables, re-computed on every request
  return this.analyticsService.computeFullSummary();
}
```

**Why AI generates it:** The endpoint is generated correctly for a single request. Caching is a cross-cutting concern that requires reasoning about request patterns over time, which is outside the scope of "generate an endpoint that returns the dashboard summary."

**Classification:** LINEAR with an avoidable multiplier — the same expensive computation is repeated once per request instead of once per unique result.

**Cost formula:**
```
uncached_cost = request_count * expensive_operation_cost
cached_cost = unique_result_count * expensive_operation_cost + (request_count * cache_read_cost)

If the summary changes once per hour but the dashboard is polled every 10 seconds
by 200 active users: 200 users * 360 requests/hour = 72,000 requests/hour,
versus 1 actual computation/hour if cached with a 1-hour TTL.
The ratio here (72,000:1) is the entire savings opportunity.
```

**Exact rewrite:**
```typescript
@Get('dashboard-summary')
async getDashboardSummary() {
  const cacheKey = 'dashboard-summary';
  const cached = await this.cache.get(cacheKey);
  if (cached) return cached;

  const summary = await this.analyticsService.computeFullSummary();
  await this.cache.set(cacheKey, summary, { ttl: 3600 }); // 1 hour
  return summary;
}
```

**Classification after fix:** CONSTANT relative to request volume — cost now scales with how often the underlying data actually changes, not with how often it is requested.

---

## Pattern 7: Unbounded LLM Agent Loop

**What it looks like:**
```python
def run_agent(task):
    while not task.is_complete():
        response = llm.call(task.get_context())
        task.apply(response)
    return task.result
```

**Why AI generates it:** Agentic loop patterns are frequently generated with a completion condition but no iteration ceiling, mirroring the same "retry until success" instinct as Pattern 3 — but here, every iteration also costs LLM tokens, which are more expensive per-unit than a database retry.

**Classification:** RUNAWAY. If `task.is_complete()` never returns true due to a logic error, an ambiguous task, or a model that gets stuck reasoning in a circle, the loop consumes tokens indefinitely.

**Cost formula:**
```
cost = iterations * (avg_input_tokens/1000 * input_rate + avg_output_tokens/1000 * output_rate)

At 2,000 input + 500 output tokens per iteration, Claude Sonnet-class pricing:
per_iteration_cost = (2000/1000 * $0.003) + (500/1000 * $0.015) = $0.006 + $0.0075 = $0.0135
A stuck loop running 10,000 iterations before a timeout or manual kill:
10,000 * $0.0135 = $135 from a single stuck agent run.
```

**Documented case:** Agentic coding workflows carry compounding costs of LLM API calls and container runtime compute that can quickly add up for high-volume teams if left unchecked.

**Exact rewrite:**
```python
MAX_ITERATIONS = 25

def run_agent(task):
    iterations = 0
    while not task.is_complete():
        if iterations >= MAX_ITERATIONS:
            logger.error(f"Agent exceeded {MAX_ITERATIONS} iterations without completing task {task.id}")
            raise AgentIterationLimitExceeded(task.id, iterations)
        response = llm.call(task.get_context())
        task.apply(response)
        iterations += 1
    return task.result
```

**Classification after fix:** CONSTANT ceiling — `MAX_ITERATIONS * per_iteration_cost` is now a known, bounded worst case.

---

## Pattern 8: Per-Item Paid API Call Instead of Batch

**What it looks like:**
```typescript
for (const contact of contacts) {
  const enriched = await enrichmentApi.lookup(contact.email); // 1 paid call per contact
  await saveEnrichedContact(enriched);
}
```

**Why AI generates it:** Generated to handle "one record" correctly, then applied in a loop without checking whether the provider offers a batch endpoint. Most enrichment, geocoding, and lookup APIs support submitting hundreds of records in a single request at a lower effective per-record cost — but this requires knowing the specific provider's batch API, which the model does not verify.

**Classification:** LINEAR with a high per-unit multiplier, which is effectively SUPRALINEAR from a business perspective — the pattern gets exactly as expensive as the business is successful at acquiring contacts.

**Cost formula:**
```
per_item_cost = third_party_api.generic_paid_api_call.mid ($0.01 typical)
At 50,000 contacts/month: 50,000 * $0.01 = $500/month
Most batch endpoints price at 30-60% of the per-item rate:
batch_cost ≈ 50,000 * $0.004-0.007 = $200-350/month — a $150-300/month gap
purely from using the wrong endpoint shape.
```

**Exact rewrite:**
```typescript
// AFTER — batch the calls using the provider's bulk endpoint
const BATCH_SIZE = 100;
for (let i = 0; i < contacts.length; i += BATCH_SIZE) {
  const batch = contacts.slice(i, i + BATCH_SIZE);
  const enrichedBatch = await enrichmentApi.bulkLookup(batch.map(c => c.email));
  await saveEnrichedContactsBatch(enrichedBatch);
}
```

**Classification after fix:** LINEAR with a lower multiplier — cost still scales with volume, but at the provider's batch rate rather than its per-item rate, and with far fewer round-trip network calls.

---

## Cross-Pattern Compounding

The patterns above are not independent. The worst documented incidents happen when two or more compound:

- **Retry loop (Pattern 3) + Lazy auto-scaling (Pattern 5):** a failing dependency triggers unbounded retries, each retry spins up new concurrent instances with no cap, and the two multiply together rather than adding.
- **Fan-out (Pattern 2) + Per-item paid API (Pattern 8):** an event fans out to five downstream systems, and one of those five loops over a paid API per item — the fan-out multiplier and the per-item multiplier stack.
- **N+1 query (Pattern 1) nested inside a retry loop (Pattern 3):** a failing N+1-heavy endpoint gets retried without a cap, multiplying an already-expensive query pattern by an unbounded retry count.

When auditing, always check whether a QUADRATIC+ or RUNAWAY finding sits inside another loop or retry structure. The combined cost is multiplicative, not additive.
