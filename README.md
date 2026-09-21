# finops-guardian

A Claude Code skill that detects infrastructure-expensive code patterns before they reach production, and states exactly what each one will cost in dollars.

**The problem:** One AI-generated admin dashboard caused $12,000 in database costs in a single month, from a query pattern that worked perfectly in every test. Unoptimized AI-generated code has been documented to inflate cloud infrastructure bills by up to 400% at production scale, compressing gross margins from a healthy 80% down into the 50-60% range. FinOps teams call the smallest version of this the "$500 query" — a single lazy commit that adds hundreds of dollars a day without ever throwing an error.

This skill does not just flag the pattern. It classifies the cost growth curve and projects the dollar range at current, 10x, and 100x scale, showing the arithmetic behind every number.

---

## Install

**Via Claude Code plugin marketplace (recommended):**
```bash
/plugin marketplace add sowadalmughni/finops-guardian
/plugin install finops-guardian@sowadalmughni
```

**Via npx (works with any agent that supports the open skills format):**
```bash
npx skills add https://github.com/sowadalmughni/finops-guardian
```

**Manually (project-level):**
```bash
git clone https://github.com/sowadalmughni/finops-guardian /tmp/finops-guardian
mkdir -p .claude/skills
cp -r /tmp/finops-guardian/skills/finops-guardian .claude/skills/finops-guardian
```

**Personal (follows you across all projects):**
```bash
git clone https://github.com/sowadalmughni/finops-guardian /tmp/finops-guardian
mkdir -p ~/.claude/skills
cp -r /tmp/finops-guardian/skills/finops-guardian ~/.claude/skills/finops-guardian
```

### Requirements

Scripts are POSIX bash and rely on GNU grep's `-P` (PCRE) flag. They run as-is on Linux, WSL, and Git Bash on Windows. On stock macOS, install GNU grep first (`brew install grep`) — BSD grep does not support `-P`, and `scan-cost-patterns.sh` checks for this at startup and exits with a clear error rather than silently under-reporting. `estimate-impact.sh` additionally requires `python3` to compute the dollar tables.

### Validating the Scanner

Don't take the detection claims on faith — `evals/scan-fixtures/planted-issues/` is a small synthetic codebase with one deliberately planted issue per pattern (an N+1 loop, a 5-call fan-out, an unbounded retry, an unretentioned storage write, an uncapped serverless config, an uncached JOIN endpoint, an unbounded LLM agent loop, a per-item paid API call). Run:

```bash
bash skills/finops-guardian/evals/run-scan-checks.sh
```

This runs the scanner against the fixture and asserts each planted pattern is actually caught at the expected classification, printing a PASS/FAIL line per assertion and exiting non-zero if anything regresses. Run this after modifying any detection regex in `skills/finops-guardian/scripts/scan-cost-patterns.sh`.

---

## Quick Start

**Scan a target for cost-risk patterns:**
```bash
bash .claude/skills/finops-guardian/scripts/scan-cost-patterns.sh ./src
```

**Project dollar cost for a specific pattern at a given scale:**
```bash
bash .claude/skills/finops-guardian/scripts/estimate-impact.sh \
  --pattern n1_query --records 10000 --requests-per-day 500
```

Output:
```
Formula: (1 + N) queries × cost/query × requests/day × 30
N (result set size): 10,000
Cost per query: $0.0000005
Requests/day: 500

Projected monthly database query cost
  Scale        Monthly Cost
  Current            $75.01
  10x               $750.08
  100x            $7,500.75
```

Or invoke via Claude:
> *"Review this PR for cost impact"*
> *"Will this scale?"*
> *"Check this for infrastructure cost risk"*
> *"Why is our cloud bill so high?"*

---

## Cost Curve Classification

Every finding is classified before a dollar figure is attached:

| Class | Growth | Gate |
|-------|--------|------|
| 🟢 CONSTANT | O(1), O(log n) | PASS |
| 🟡 LINEAR | O(n) | PASS with note |
| 🟠 SUPRALINEAR | O(n log n), or high-multiplier O(n) | WARN |
| 🔴 QUADRATIC+ | O(n²) or worse, O(n×m) cross-product | BLOCK |
| ⚫ RUNAWAY | Unbounded — no retry cap, no storage TTL, no concurrency limit | BLOCK, regardless of current traffic |

A RUNAWAY finding is not a growth-rate problem — it is a missing hard cap. A single triggering failure produces unlimited cost at any traffic level, today, not just at scale.

---

## Patterns Detected

| Pattern | Typical Classification | Documented Case |
|---------|------------------------|------------------|
| N+1 ORM query | LINEAR → QUADRATIC+ if nested | $12,000/month from one AI-generated dashboard |
| Accidental API fan-out | SUPRALINEAR | One event triggering cascading downstream calls |
| Unbounded retry loop | RUNAWAY | Compute and token budgets silently burned before anyone notices |
| Unbounded storage growth | LINEAR, compounding | Every prompt/output/attachment saved indefinitely, no TTL |
| Lazy auto-scaling | SUPRALINEAR → RUNAWAY | No concurrency cap, compounds with retry storms |
| Missing cache on expensive ops | LINEAR with avoidable multiplier | Complex JOINs recomputed on every request |
| Unbounded LLM agent loop | RUNAWAY | Agentic loops burning tokens with no iteration cap |
| Per-item paid API call | LINEAR, high multiplier | Missed batch-endpoint discount, scales with business growth |

---

## Suppressing a Finding

Some patterns are intentional — a health-check poller that retries forever by design, bounded externally by a liveness probe timeout, is not a bug. Add a comment containing `finops-guardian-ignore` on the flagged line or the line above it:

```typescript
// finops-guardian-ignore: intentional unbounded poll, bounded externally
// by the container orchestrator's liveness probe timeout (ADR-014)
while (true) {
  ...
}
```

Suppressions are counted and reported, not silent — `⚪ SUPPRESSED` in the text summary, `suppressed_count` in JSON output — so a suppressed finding still shows up as a decision made, not a gap in coverage.

---

## Shift-Left FinOps: CI Gate

Cost is evaluated before merge, exactly like a failed test — not discovered on next month's invoice. `skills/finops-guardian/templates/ci-cost-gate.md` includes ready-to-use GitHub Actions, GitLab CI, and pre-commit hook configurations that run the scanner on every PR and block merge on any RUNAWAY or QUADRATIC+ finding.

```bash
bash skills/finops-guardian/scripts/scan-cost-patterns.sh . --files-from changed_files.txt --gate-only
echo $?   # 0 = PASS, 1 = BLOCK
```

---

## What's Included

```
finops-guardian/
├── .claude-plugin/
│   ├── marketplace.json                ← Enables `/plugin marketplace add`
│   └── plugin.json                     ← Plugin manifest
├── LICENSE
├── README.md                           ← This file
├── CHANGELOG.md
└── skills/
    └── finops-guardian/
        ├── SKILL.md                    ← 5 invocation modes, cost curve classification
        ├── metrics/
        │   └── cloud-cost-heuristics.json   ← Unit costs, growth formulas, documented case studies
        ├── reference/
        │   └── cost-pattern-playbook.md     ← 8 patterns: why AI generates it, cost formula, exact rewrite
        ├── templates/
        │   ├── cost-impact-report.md        ← Full report: scale assumptions, findings, savings projection
        │   └── ci-cost-gate.md              ← GitHub Actions, GitLab CI, pre-commit hook templates
        ├── scripts/
        │   ├── scan-cost-patterns.sh        ← Detects all 8 patterns, classifies, gates on RUNAWAY/QUADRATIC+
        │   └── estimate-impact.sh           ← Projects dollar cost at current/10x/100x scale
        └── evals/
            ├── run-scan-checks.sh           ← Asserts the scanner catches every planted pattern
            ├── trigger-evals.json           ← Positive/near-miss queries for invocation matching
            └── scan-fixtures/planted-issues/ ← One deliberately planted issue per pattern
```

---

## Related Skills

Part of the Kitalon Labs AI engineering skill collection:

| Skill | Focus |
|-------|-------|
| [spec-driven-dev](https://github.com/sowadalmughni/spec-driven-dev) | Architecture approval before code generation |
| [ai-codebase-audit](https://github.com/sowadalmughni/ai-codebase-audit) | Full six-failure-mode project audit |
| [vibe-debt-scanner](https://github.com/sowadalmughni/vibe-debt-scanner) | Module-level code quality debt score |
| [rls-security-check](https://github.com/sowadalmughni/rls-security-check) | Row Level Security specialist |
| **finops-guardian** | Infrastructure cost curve classification and dollar projection |

`ai-codebase-audit` and `vibe-debt-scanner` both flag N+1 queries and retry patterns as part of a broader check. This skill is the only one that converts every finding into a classified growth curve and a dollar range, with the arithmetic shown.

---

## About

Built by **Md. Sowad Al-Mughni** — founder of [Kitalon Labs](https://www.kitalonlabs.com), an AI-native product studio.

- Website: [www.kitalonlabs.com](https://www.kitalonlabs.com)
- GitHub: [github.com/sowadalmughni](https://github.com/sowadalmughni)

---

## License

MIT — use freely, attribution appreciated.
