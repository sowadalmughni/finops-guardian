# Shift-Left FinOps: CI/CD Cost Gate

This implements the Shift-Left FinOps model: cost is evaluated before merge, exactly like a failed test, rather than discovered on next month's invoice. Treating cost as a bug that blocks a PR changes engineering behavior immediately — the same way a failing unit test does.

Choose the integration that matches your pipeline.

---

## GitHub Actions

```yaml
# .github/workflows/finops-gate.yml
name: FinOps Cost Gate

on:
  pull_request:
    branches: [main, develop]

jobs:
  cost-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install finops-guardian
        run: |
          git clone https://github.com/sowadalmughni/finops-guardian.git /tmp/finops-guardian
          chmod +x /tmp/finops-guardian/skills/finops-guardian/scripts/*.sh

      - name: Get changed files
        id: changed-files
        run: |
          git diff --name-only origin/${{ github.base_ref }}...HEAD > changed_files.txt
          cat changed_files.txt

      - name: Run cost pattern scan on changed files
        id: cost-scan
        run: |
          bash /tmp/finops-guardian/skills/finops-guardian/scripts/scan-cost-patterns.sh . --files-from changed_files.txt \
            --format json > cost-scan-results.json
          cat cost-scan-results.json

      - name: Evaluate gate
        id: gate
        run: |
          RUNAWAY=$(jq '[.findings[] | select(.classification == "RUNAWAY")] | length' cost-scan-results.json)
          QUADRATIC=$(jq '[.findings[] | select(.classification == "QUADRATIC_PLUS")] | length' cost-scan-results.json)

          echo "runaway=$RUNAWAY" >> "$GITHUB_OUTPUT"
          echo "quadratic=$QUADRATIC" >> "$GITHUB_OUTPUT"

          if [ "$RUNAWAY" -gt 0 ] || [ "$QUADRATIC" -gt 0 ]; then
            echo "gate=BLOCK" >> "$GITHUB_OUTPUT"
            exit 1
          else
            echo "gate=PASS" >> "$GITHUB_OUTPUT"
          fi

      - name: Comment on PR with findings
        if: always()
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const results = JSON.parse(fs.readFileSync('cost-scan-results.json', 'utf8'));
            const gate = '${{ steps.gate.outputs.gate }}';
            const icon = gate === 'BLOCK' ? '🔴' : '🟢';

            let body = `## ${icon} FinOps Cost Gate: ${gate}\n\n`;
            body += `**RUNAWAY findings:** ${{ steps.gate.outputs.runaway }}\n`;
            body += `**QUADRATIC+ findings:** ${{ steps.gate.outputs.quadratic }}\n\n`;

            if (results.findings && results.findings.length > 0) {
              body += `| File | Pattern | Classification | Projected Monthly Cost |\n`;
              body += `|------|---------|----------------|------------------------|\n`;
              for (const f of results.findings) {
                body += `| ${f.file}:${f.line} | ${f.pattern} | ${f.classification} | $${f.projected_monthly_cost || 'n/a'} |\n`;
              }
            } else {
              body += `No cost-risk patterns detected in changed files.\n`;
            }

            body += `\n_Full playbook and rewrites: [finops-guardian](https://github.com/sowadalmughni/finops-guardian)_`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: body,
            });
```

**Behavior:** Any RUNAWAY or QUADRATIC+ finding fails the check and blocks merge (if branch protection requires this check to pass). Every other classification is reported in a PR comment but does not block, matching the SUPRALINEAR gate being a WARN rather than a hard stop.

---

## Pre-Commit Hook (Local, Before Push)

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit
# Install: cp this to .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

FINOPS_GUARDIAN_PATH="${FINOPS_GUARDIAN_PATH:-$HOME/.claude/skills/finops-guardian}"

if [ ! -d "$FINOPS_GUARDIAN_PATH" ]; then
  echo "finops-guardian not found at $FINOPS_GUARDIAN_PATH — skipping cost gate."
  echo "Install: see https://github.com/sowadalmughni/finops-guardian#install"
  exit 0
fi

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ts|tsx|js|jsx|py)$')

if [ -z "$STAGED_FILES" ]; then
  exit 0
fi

echo "Running FinOps cost gate on staged files..."
echo "$STAGED_FILES" > /tmp/finops-staged-files.txt

bash "$FINOPS_GUARDIAN_PATH/scripts/scan-cost-patterns.sh" . --files-from /tmp/finops-staged-files.txt --gate-only

GATE_RESULT=$?

if [ "$GATE_RESULT" -ne 0 ]; then
  echo ""
  echo "🔴 FinOps Cost Gate: BLOCKED"
  echo "A RUNAWAY or QUADRATIC+ cost pattern was found in staged changes."
  echo "Run the full scan for details:"
  echo "  bash $FINOPS_GUARDIAN_PATH/scripts/scan-cost-patterns.sh ."
  echo ""
  echo "To bypass (not recommended): git commit --no-verify"
  exit 1
fi

echo "🟢 FinOps Cost Gate: PASS"
exit 0
```

---

## GitLab CI

```yaml
# .gitlab-ci.yml
finops-cost-gate:
  stage: test
  image: bash:latest
  before_script:
    - apk add --no-cache git jq
    - git clone https://github.com/sowadalmughni/finops-guardian.git /tmp/finops-guardian
    - chmod +x /tmp/finops-guardian/skills/finops-guardian/scripts/*.sh
  script:
    - git diff --name-only $CI_MERGE_REQUEST_DIFF_BASE_SHA...HEAD > changed_files.txt
    - bash /tmp/finops-guardian/skills/finops-guardian/scripts/scan-cost-patterns.sh . --files-from changed_files.txt --format json > cost-scan-results.json
    - |
      RUNAWAY=$(jq '[.findings[] | select(.classification == "RUNAWAY")] | length' cost-scan-results.json)
      QUADRATIC=$(jq '[.findings[] | select(.classification == "QUADRATIC_PLUS")] | length' cost-scan-results.json)
      if [ "$RUNAWAY" -gt 0 ] || [ "$QUADRATIC" -gt 0 ]; then
        echo "FinOps Cost Gate: BLOCK — $RUNAWAY RUNAWAY, $QUADRATIC QUADRATIC+ findings"
        cat cost-scan-results.json
        exit 1
      fi
      echo "FinOps Cost Gate: PASS"
  artifacts:
    paths:
      - cost-scan-results.json
    when: always
  only:
    - merge_requests
```

---

## Design Principle Behind This Gate

Cost is treated as a bug, evaluated before deployment rather than after. A developer generating a pull request with an unoptimized query gets the same immediate, specific feedback they would get from a failed unit test: a bot calculates the infrastructure footprint of the change and flags it with an explicit dollar figure, forcing the inefficiency to be rectified before merge rather than discovered on next month's invoice.

The gate does not block on every finding — only on RUNAWAY and QUADRATIC+, which are the two classes that produce genuinely unbounded or explosive cost growth. LINEAR and SUPRALINEAR findings are surfaced for visibility and prioritization, not treated as merge-blocking, because most linear cost growth is a legitimate and acceptable tradeoff at the point a PR is opened.
