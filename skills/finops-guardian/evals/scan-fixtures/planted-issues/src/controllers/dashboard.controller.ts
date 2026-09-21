// Fixture: Pattern 6 (missing cache) — expensive aggregation recomputed on
// every request instead of cached.
@Get('dashboard-summary')
async getDashboardSummary() {
  // Complex aggregation JOIN across 4 tables, re-computed on every request
  return this.analyticsService.computeFullSummary();
}
