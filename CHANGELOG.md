# Changelog

## [1.1.0] — 2026-09-21

### Fixed

- `scripts/scan-cost-patterns.sh` — The N+1 nested-loop check (`.map(async)` branch) looked back over the 15 lines up to and *including* the line that triggered the match. Since that line always contains `.map(` — one of the things the check searches for — every finding from this branch self-matched and was classified QUADRATIC_PLUS regardless of whether it was actually nested inside another loop. Fixed by excluding the triggering line from the lookback window; verified with new fixtures covering both a genuinely-nested case (still QUADRATIC_PLUS) and a non-nested case (now correctly LINEAR).

### Added

- Suppression mechanism: a comment containing `finops-guardian-ignore` on the flagged line or the line above it silences that specific finding. Auditable, not silent — suppressions are counted and reported (⚪ SUPPRESSED in the text summary, `suppressed_count` in JSON output) rather than disappearing without a trace.
- `metrics/cloud-cost-heuristics.json` — `_meta.last_reviewed` and `_meta.review_cadence` fields, since unit costs (especially `llm_api`) drift and previously had no signal indicating when they needed re-verification.
- Three new eval fixtures (`comments.service.ts`, `groups.service.ts`, `health-check-poller.ts`) and matching assertions proving the classification fix and the suppression mechanism both work as intended, not just as documented.

## [1.0.0] — 2026-09-19

### Added

- `SKILL.md` — Five invocation modes: PR Cost Review, Full Codebase Sweep, Cost Projection Mode, CI Gate Mode, Runaway Loop Audit. Introduces a five-tier cost curve classification (CONSTANT, LINEAR, SUPRALINEAR, QUADRATIC_PLUS, RUNAWAY) that gates findings independently of raw dollar amount.
- `metrics/cloud-cost-heuristics.json` — Directional unit costs for database operations, storage, compute, LLM API tokens (GPT-4-class, Claude Sonnet-class, embeddings), and third-party APIs. Growth models with cost formulas for 8 patterns. Documented case studies including the $12,000/month dashboard incident and the 400% cloud bill inflation figure. Explicit blocking thresholds.
- `reference/cost-pattern-playbook.md` — 8 patterns in full depth: N+1 queries, accidental fan-out, runaway retry loops, unbounded storage, lazy auto-scaling, missing cache, unbounded LLM agent loops, per-item paid API calls. Each includes code sample, why AI generates it, classification, cost formula with worked arithmetic, documented case, and exact rewrite with post-fix classification. Closes with a cross-pattern compounding section covering how RUNAWAY and QUADRATIC+ findings multiply when nested.
- `templates/cost-impact-report.md` — Report template requiring explicit scale assumptions before any dollar figure, per-finding before/after cost curve and savings projection, and a cross-pattern compounding check.
- `templates/ci-cost-gate.md` — Shift-Left FinOps CI/CD templates: GitHub Actions (with automatic PR comment showing findings and projected cost), GitLab CI, and a local pre-commit hook. Gate blocks only on RUNAWAY and QUADRATIC+ findings.
- `scripts/scan-cost-patterns.sh` — Detects all 8 patterns via static analysis (including lazy auto-scaling in serverless/k8s YAML config, not just application code), classifies each finding, supports `--files-from` for PR-diff scanning, `--gate-only` for CI use, and `--format json` for machine-readable output. Exit code 1 on any BLOCK-tier finding. Preflights for GNU grep's `-P` (PCRE) support and fails with a clear error rather than silently under-reporting on platforms where it's missing (e.g. stock macOS).
- `scripts/estimate-impact.sh` — Interactive cost projector. Takes scale parameters (records, requests/day, attempts, GB stored, item count) and a pattern name, outputs a current/10x/100x dollar table with the arithmetic shown, sourced from `cloud-cost-heuristics.json`.
- `evals/` — Validation harness: `scan-fixtures/planted-issues/` plants one real instance of each of the 8 patterns, `run-scan-checks.sh` asserts the scanner actually catches each one at the expected classification, and `trigger-evals.json` lists positive and near-miss invocation queries.
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` — Plugin manifest and single-plugin marketplace definition enabling `/plugin marketplace add` + `/plugin install`.
- `LICENSE` (MIT), `.gitattributes`, `.gitignore`.

### Design Decisions

- Classification always precedes dollar estimation. A pattern's growth curve determines urgency far more than its current dollar amount does.
- RUNAWAY is defined as a missing hard cap, not a growth rate — it blocks regardless of current traffic, because a single triggering event produces unbounded cost at any scale.
- Every dollar figure in every output must show its arithmetic: unit cost × multiplier × scale assumption. A number with no visible formula is treated as a guess, not a finding.
- The CI gate blocks only on RUNAWAY and QUADRATIC+, deliberately not on LINEAR or SUPRALINEAR, because most linear cost growth is an acceptable and expected tradeoff at PR time — the gate exists to catch the two classes that produce genuinely unbounded or explosive growth.
- Unit costs are stored in a single JSON file (`cloud-cost-heuristics.json`) so they can be corrected to match a specific project's actual cloud provider and tier without editing any script logic.
