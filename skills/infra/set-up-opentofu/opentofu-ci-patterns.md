# OpenTofu CI Patterns

Reference for `set-up-opentofu`. The three workflows below are the skill's step 6. They passed `actionlint` on 2026-10-09; none has run on GitHub. Application delivery (image build, deploy) is [set-up-delivery-pipeline](../set-up-delivery-pipeline/SKILL.md) — these files touch infrastructure only. Repo-side rules (layout, backend, encryption) are [opentofu-patterns.md](./opentofu-patterns.md).

## The workflows

`.github/workflows/infra.yml` — check on every PR and push to `main`; dev plan on PR; plan and apply per environment after merge:

```yaml
name: infra

on:
  pull_request:
    paths: ["infra/**", ".github/workflows/infra.yml", ".github/workflows/_tofu.yml"]
  push:
    branches: [main]
    paths: ["infra/**", ".github/workflows/infra.yml", ".github/workflows/_tofu.yml"]

permissions: {}

concurrency:
  group: infra-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.13.1
      - name: Format
        run: tofu fmt -check -recursive -diff infra
      - name: Validate every environment (no backend, no secrets)
        run: |
          for env in infra/envs/*/; do
            tofu -chdir="$env" init -backend=false -input=false -lockfile=readonly >/dev/null
            tofu -chdir="$env" validate
          done
      - name: Module tests
        run: |
          for m in infra/modules/*/; do
            [ -d "$m/tests" ] || continue
            tofu -chdir="$m" init -backend=false -input=false >/dev/null
            tofu -chdir="$m" test
          done
      - name: Misconfiguration scan
        run: |
          docker run --rm -v "$PWD/infra:/work:ro" \
            ghcr.io/aquasecurity/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa \
            config --exit-code 1 --severity HIGH,CRITICAL --no-progress /work

  # A pull request shows the dev plan only. stg and prd plans are produced after merge, in front of their approval.
  plan-dev:
    if: github.event_name == 'pull_request'
    needs: check
    uses: ./.github/workflows/_tofu.yml
    with:
      environment: dev
      apply: false
    secrets: inherit
    permissions:
      contents: read

  dev:
    if: github.event_name == 'push'
    needs: check
    uses: ./.github/workflows/_tofu.yml
    with:
      environment: dev
      apply: true
    secrets: inherit
    permissions:
      contents: read

  stg:
    needs: dev
    uses: ./.github/workflows/_tofu.yml
    with:
      environment: stg
      apply: true
    secrets: inherit
    permissions:
      contents: read

  prd:
    needs: stg
    uses: ./.github/workflows/_tofu.yml
    with:
      environment: prd
      apply: true
    secrets: inherit
    permissions:
      contents: read
```

`.github/workflows/_tofu.yml` — the reusable per-environment plan and apply:

```yaml
name: _tofu

on:
  workflow_call:
    inputs:
      environment:
        type: string
        required: true
      apply:
        type: boolean
        required: true

permissions: {}

env:
  TF_IN_AUTOMATION: "true"
  TF_INPUT: "false"

jobs:
  plan:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    environment: ${{ inputs.environment }}-plan     # same secrets as the apply environment, no reviewers
    permissions:
      contents: read
    defaults:
      run:
        working-directory: infra/envs/${{ inputs.environment }}
    env:
      TF_ENCRYPTION: ${{ secrets.TF_ENCRYPTION }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}          # state bucket credentials
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      IONOS_TOKEN: ${{ secrets.IONOS_TOKEN }}
    outputs:
      changes: ${{ steps.plan.outputs.exitcode }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.13.1
          tofu_wrapper: false
      - run: tofu init -lockfile=readonly
      - name: Plan
        id: plan
        run: |
          set +e
          tofu plan -out=tfplan -lock-timeout=60s -detailed-exitcode
          code=$?
          set -e
          [ "$code" -ne 1 ] || exit 1
          echo "exitcode=$code" >>"$GITHUB_OUTPUT"
      - name: Show plan
        run: |
          {
            echo '### tofu plan: ${{ inputs.environment }}'
            echo '```'
            tofu show -no-color tfplan
            echo '```'
          } >>"$GITHUB_STEP_SUMMARY"
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: tfplan-${{ inputs.environment }}
          path: infra/envs/${{ inputs.environment }}/tfplan    # encrypted by the plan {} block
          retention-days: 3
          if-no-files-found: error

  apply:
    needs: plan
    if: inputs.apply && needs.plan.outputs.changes == '2'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    environment: ${{ inputs.environment }}            # prd: required reviewers see the plan summary first
    concurrency:
      group: tofu-${{ inputs.environment }}
      cancel-in-progress: false
    permissions:
      contents: read
    defaults:
      run:
        working-directory: infra/envs/${{ inputs.environment }}
    env:
      TF_ENCRYPTION: ${{ secrets.TF_ENCRYPTION }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      IONOS_TOKEN: ${{ secrets.IONOS_TOKEN }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.13.1
          tofu_wrapper: false
      - run: tofu init -lockfile=readonly
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: tfplan-${{ inputs.environment }}
          path: infra/envs/${{ inputs.environment }}
      - name: Apply the approved plan (fails if the state changed since the plan)
        run: tofu apply tfplan
```

`.github/workflows/infra-drift.yml` — weekly read-only plan over every environment:

```yaml
name: infra-drift

on:
  schedule:
    - cron: "17 5 * * 1"
  workflow_dispatch:

permissions: {}

jobs:
  drift:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        environment: [dev, stg, prd]
    environment: ${{ matrix.environment }}-plan
    permissions:
      contents: read
      issues: write
    defaults:
      run:
        working-directory: infra/envs/${{ matrix.environment }}
    env:
      TF_ENCRYPTION: ${{ secrets.TF_ENCRYPTION }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      IONOS_TOKEN: ${{ secrets.IONOS_TOKEN }}
      TF_IN_AUTOMATION: "true"
      TF_INPUT: "false"
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: opentofu/setup-opentofu@a1320f892987e89d278cc92dc5adc984fb93aca4 # v2.0.2
        with:
          tofu_version: 1.13.1
          tofu_wrapper: false
      - run: tofu init -lockfile=readonly
      - name: Plan against reality
        env:
          GH_TOKEN: ${{ github.token }}
          ENVIRONMENT: ${{ matrix.environment }}
        run: |
          set +e
          tofu plan -lock=false -detailed-exitcode -no-color | tee plan.txt
          code=${PIPESTATUS[0]}
          set -e
          if [ "$code" -eq 2 ]; then
            gh issue create --repo "$GITHUB_REPOSITORY" \
              --title "Infrastructure drift in $ENVIRONMENT" \
              --body "The weekly plan for $ENVIRONMENT shows changes nobody applied. Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
          fi
          exit "$code"
```

## Rule: apply the saved plan, not a fresh one
**Why:** `tofu apply tfplan` applies the bytes a human saw. OpenTofu re-checks the saved plan against the current state and config and refuses to apply it if either moved, so an approval cannot silently cover a different change. A plan recomputed in the apply job would include commits nobody reviewed.
**How to apply:** plan writes `-out=tfplan`, uploads it, and the apply job downloads and runs `tofu apply tfplan`. Exit 1 from plan fails the job; exit 0 skips apply (`changes == '2'` gate). `tofu_wrapper: false` keeps `-detailed-exitcode` intact — the wrapper would swallow the exit code.
**Anti-example:** `tofu apply -auto-approve` in the apply job.

## Rule: the plan artifact is encrypted and lives three days
**Why:** A saved plan holds resolved values. The `plan {}` block of `TF_ENCRYPTION` encrypts the file (verified: it starts with `{"meta":{"key_provider.pbkdf2`), so the artifact is ciphertext even inside GitHub. Three days of retention covers a long approval without hoarding plans.
**How to apply:** `actions/upload-artifact` with `retention-days: 3` and `if-no-files-found: error`, as in `_tofu.yml`.

## Rule: two GitHub environments per target
**Why:** A plan needs secrets but no human; an apply needs a human for prd. `<env>-plan` holds the same secrets with no reviewers, so plans never queue behind an approval; `<env>` carries the required reviewers that gate the apply. The cost is that every secret is stored twice.
**How to apply:** six environments: `dev`, `stg`, `prd` and `dev-plan`, `stg-plan`, `prd-plan`. The secret list is in the skill (step 6); no OIDC exists for Hetzner or IONOS, so these are scoped long-lived tokens.

## Rule: the PR shows the dev plan; stg and prd plan in front of their approval
**Why:** Fork pull requests cannot read repository secrets, and prd plans belong in front of the prd approval, not in a PR thread. After merge, dev applies first, then stg plans and applies, then prd — each prd/stg apply waits on its own environment reviewers.
**How to apply:** `plan-dev` runs on `pull_request`; `dev` → `stg` → `prd` chain through `needs` on `push`. The plan text goes to the step summary, which reviewers see at the approval gate.

## Rule: validate without credentials
**Why:** fmt, validate, module tests and the misconfiguration scan need no cloud secrets, so they run on any PR — forks included — and fail fast before anything slow starts. `init -backend=false` skips the state store; `-lockfile=readonly` fails when the lock file does not cover the config.
**How to apply:** the `check` job in `infra.yml`.

## Rule: drift is a weekly read-only plan
**Why:** Console edits and provider-side changes otherwise surface during an incident. `-detailed-exitcode` is the contract (verified): 0 clean, 2 changes, 1 error. The job plans with `-lock=false` because it only reads — it must not block an apply running at the same time — and it propagates the exit code, so a drifted environment fails the job and opens an issue with a link to the run.
**How to apply:** `infra-drift.yml`, a matrix over dev/stg/prd using the `<env>-plan` credentials and `issues: write` for `gh issue create`.

## Rule: one apply per environment at a time, never cancelled
**Why:** Two applies against one state interleave. The `concurrency` group `tofu-<env>` serialises applies per environment, and `cancel-in-progress: false` means a queued run waits instead of killing an apply mid-flight — cancelling between resource operations is how state gets wedged. Stale PR checks still cancel each other via the workflow-level group in `infra.yml`.
**How to apply:** the `apply` job's `concurrency` block in `_tofu.yml`.

## Pins
Every third-party action is pinned by commit SHA; versions, SHAs and the Trivy digest are verified in [stack-versions.md](../_shared/stack-versions.md). `permissions: {}` at the top and explicit grants per job; `persist-credentials: false` on every checkout.

## When to deviate
- **No reviewers available** (private repo on a plan without environment reviewers): the prd gate degrades to a pause in front of the plan summary. Say so in the README; do not pretend it is a second pair of eyes ([environments.md](../_shared/environments.md)).
- **Drift issue dedupe**: one new issue per week per environment piles up; search for an open `Infrastructure drift in <env>` issue before creating another (not implemented above).
- **Monorepo**: keep the `paths:` filters tight and give each infra directory its own concurrency group, or the app pipeline and infra block each other.
- **PR plan comments**: the plan goes to the step summary and the artifact, not a PR comment — comments need a write token and put plan output into the thread. Add a comment bot only with that trade-off accepted.
