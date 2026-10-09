# Pipeline Patterns

Reference for [set-up-delivery-pipeline](./SKILL.md). Why the pipeline has this shape. Security rules that apply
beyond CI live in [security-baseline](../../core/_shared/security-baseline.md); principles in
[engineering-principles](../../core/_shared/engineering-principles.md).

## Rule: build once, promote the digest

**Why:** A rebuild per environment produces a different artifact each time: new base-image layers, new dependency
resolution, a different clock. "It passed in stg" then says nothing about prd. A digest (`sha256:…`) names bytes, so
the bytes that passed `dev` and `stg` are the bytes that reach `prd`. Tags are mutable; digests are not.
**How to apply:** `_build.yml` runs on `main` only and outputs `name@sha256:…`. Every deploy takes that string. A tag
push never builds; it looks up the digest that `main` built for the same commit (`sha-<commit>`), and fails with a
clear error when none exists. Environment differences live in environment variables, never in the image.
**Anti-example:** `docker build` inside the `prd` job "to be sure it is fresh". It deploys something nobody tested.

## Rule: `permissions: {}` at the top, grants per job

**Why:** Without an explicit block, the token gets the repo-level default, and an unreviewed workflow can hold write
access to contents, packages and pull requests. A top-level empty block makes every grant visible in review, next to the job
that needs it. A called reusable workflow cannot get more than its caller grants, so the caller job lists the full set.
**How to apply:** `permissions: {}` on every workflow; `contents: read` on every job that checks out; add
`packages: write`, `id-token: write`, `attestations: write`, `artifact-metadata: write` only on the build job.
Deploy jobs get `packages: read` and `attestations: read`. Add `id-token: write` to a deploy job only when the host
trusts GitHub OIDC. Set the repo default to read-only as a second layer.
**Anti-example:** `permissions: write-all`, or no `permissions:` key and trusting the repo default.

## Rule: pin every third-party action to a full commit SHA

**Why:** A tag such as `v4` is a pointer the action's owner can move. A compromised or hijacked tag runs attacker code
with your job's token and secrets. A full SHA cannot be moved. GitHub can enforce this: the repository setting
`sha_pinning_required` fails any run that references an action by tag or branch.
**How to apply:** `uses: owner/action@<40-hex> # vX.Y.Z`. Enable `sha_pinning_required` (step 4 of the skill) after
every workflow is pinned, because it fails all unpinned runs at once, including transitive ones inside composite
actions. Dependabot (or Renovate with `helpers:pinGitHubActionDigests`) updates the SHA and the comment together; the
`cooldown` of 7 days keeps a freshly published release from reaching `main` before the community has looked at it.
Reusable workflows in the same repository (`./.github/workflows/x.yml`) are exempt and run at the caller's commit.
**Anti-example:** `uses: actions/checkout@v4` "because Dependabot bumps it". Dependabot proposes; it does not make a
tag immutable.

## Rule: OIDC where the target supports it, a scoped short-lived secret where it does not

**Why:** A long-lived cloud key in a secret store is a standing credential: it leaks through logs, forks, and former
colleagues, and nobody notices. An OIDC token is minted per job, lives minutes, and carries claims (repository,
environment, ref) the cloud checks. A stolen workflow log contains nothing reusable.
**How to apply:**

| Target | Auth | Notes |
|---|---|---|
| GHCR | `github.token` (`packages: write` to push, `read` to pull) | Job-scoped; no PAT. |
| AWS | OIDC, `aws-actions/configure-aws-credentials` (v6.3.0 when verified) | Trust policy `sub` = `repo:<org>/<repo>:environment:<env>`. |
| Azure | OIDC, `azure/login` (v3.1.0 when verified) | Federated credential per environment. |
| GCP | OIDC through Workload Identity Federation | Attribute condition on repository and environment. |
| Hetzner, IONOS (VPS over SSH) | No OIDC found 2026-10-09. SSH key as an **environment** secret | See the SSH rule below. |
| Hetzner Cloud API, IONOS API (IaC) | No OIDC found. API token as an environment secret | Owned by [set-up-opentofu](../set-up-opentofu/SKILL.md). |
| Vercel | Token as a `prd`-environment secret | OIDC at Vercel is for Vercel to cloud, not for CLI auth. |
| Supabase | Access token + DB password as environment secrets | `supabase link` and `db push` need both. |

Scope every OIDC trust policy to the **environment** claim, not just the repository. Then only a job that passed the
environment's protection rules can assume the prd role.
**Anti-example:** A trust policy with `sub: repo:org/*`. Any workflow in any repo of the org assumes the prd role.

## Rule: SSH deploy keys are environment-scoped, forced-command, and rotated

**Why:** An SSH key that can open a shell as a user in the `docker` group is root on the host. CI needs one capability:
"deploy this digest". Restrict the key to that.
**How to apply:** One key per environment, stored only as a secret of that GitHub environment (a `dev` job cannot read the
`prd` key). On the host: a dedicated `deploy` user, and in `authorized_keys`
`restrict,command="/opt/deploy/run.sh" ssh-ed25519 AAAA…` so the key can only run the deploy script, which validates
that its argument is an `image@sha256:` reference of your repository. Rotate on a schedule and on every offboarding.
Pass the registry login as a short-lived token (`github.token`) through the script's stdin, into a temporary Docker config
directory removed at the end; do not leave a PAT on the host.
**Anti-example:** One `SSH_PRIVATE_KEY` repository secret with a login shell on all three hosts.

## Rule: environments are the gate and the secret scope

**Why:** An environment secret is released to a job only after the environment's protection rules pass. So the same
mechanism gives you approval and isolation: a PR from a branch cannot read `prd` secrets, and nothing reaches `prd`
without a human who is not the author.
**How to apply:** `dev` open to `main`; `stg` and `prd` restricted to `v*` tags (deployment tag policy); `prd` with
required reviewers and `prevent_self_review: true`. Admins can bypass by default; disable that for `prd` in the
environment settings ("Allow administrators to bypass configured protection rules"; not in the REST schema, so it is a UI step). Keep per-environment config (URLs, hosts, flags) as environment
**variables** and credentials as environment **secrets**. Names are identical across environments; only values differ,
so workflow files contain no environment-specific branches.
**Anti-example:** `if: github.ref == 'refs/heads/main'` as the "protection" for a deploy that reads repository secrets.

## Rule: the prd gate must exist on every plan

**Why:** Required reviewers on environments are free in public repos but need GitHub Enterprise for private ones
(GitHub Free, Pro and Team: public only; verified 2026-10-09). Without a gate, "manual approval" silently becomes
"auto-deploy to prd".
**How to apply:** On a private repo without Enterprise, split `prd` into its own workflow `deploy-prd.yml` triggered by
`workflow_dispatch` only, take the digest as input, and protect it with a repository **ruleset** that limits who can
push the `v*` tags, plus branch protection requiring a PR review on `main`. State the weaker guarantee to the user:
the gate is "who can press the button", not "a second person must approve". If that is not enough, move the repo to a
plan that has the feature or make it public. Never remove the gate.
**Anti-example:** Leaving `environment: prd` in the workflow with no reviewers configured. It reads as a gate and is not.

## Rule: attest provenance at build, verify before deploy

**Why:** Provenance proves which workflow, repository and commit produced a digest. Verifying before deploy means a
digest pushed by hand, or by a different workflow, cannot reach any environment, even with valid registry credentials.
**How to apply:** `actions/attest` in `_build.yml` with `subject-name` (lowercase, no tag), `subject-digest`,
`push-to-registry: true`. `_deploy.yml` runs `gh attestation verify oci://<image> --owner <org> --signer-workflow
<repo>/.github/workflows/_build.yml` and stops the job on failure. `actions/attest-build-provenance` v4 is a wrapper
around `actions/attest`; new code uses `actions/attest` directly. `build-push-action`'s own `provenance` is set to
`false` so the image stays a single manifest with one digest; the signed attestation replaces it.
**Limit:** Artifact attestations on **private** repositories need GitHub Enterprise Cloud (public repos: all plans).
On other plans remove the attest step and the verify step, set `provenance: mode=max` on `build-push-action`
(unsigned, stored in the registry), and say so. Digest promotion stays.
**Anti-example:** Verifying with `--owner` alone. Any workflow in the org that can push to the registry then passes.

## Rule: concurrency: cancel checks, never cancel deploys

**Why:** A newer push makes an older PR check run worthless; cancelling saves minutes. A deploy killed half way leaves a
host in an unknown state. Two deploys to one environment at the same time race.
**How to apply:** `delivery.yml`: group by PR number or ref, `cancel-in-progress` only for `pull_request`. Deploy job:
group `deploy-<environment>`, `cancel-in-progress: false`. GitHub keeps one running and the newest pending run in a
group, so a burst of merges deploys the first and the last, in order.

## Rule: cache what is expensive and safe

**Why:** Dependency install and image layers dominate run time; both are content-addressed, so a stale cache is a miss,
not a wrong result.
**How to apply:** Node: `setup-node` with `cache: pnpm` (key from the lockfile). Tools: `mise-action` caches its
installs. Images: `cache-from: type=gha` / `cache-to: type=gha,mode=max`. Never cache secrets, `.env`, or build
output that embeds them. A cache written by a PR branch is not readable by `main`, so a PR cannot poison the default branch.

## Rule: untrusted text never reaches a shell unquoted

**Why:** `run: echo "${{ github.event.pull_request.title }}"` is code injection: the title is pasted into the script
before the shell parses it. Branch names, PR titles, issue bodies and commit messages are attacker-controlled.
**How to apply:** Pass values through `env:` and use `"$VAR"` in the script. Trigger on `pull_request`, not
`pull_request_target` (the latter runs with secrets against fork code). `zizmor` in `_checks.yml` flags both.
**Anti-example:** `run: ./deploy.sh ${{ inputs.image }}`.

## Rule: one entry workflow with no logic, one reusable workflow per track

**Why:** The job graph is the policy ("what runs when, in what order, behind which gate"); the steps are mechanics.
Separating them keeps the policy readable in one screen and makes a mechanic (a new host) a one-file change. The
`deploy/deploy.sh` seam does the same at the host boundary: swapping Hetzner for IONOS changes a script, not the graph.
**How to apply:** `delivery.yml` contains triggers, concurrency, `needs`, and `with:`. Everything else is in
`_checks`, `_build`, `_deploy`. Reusable workflows are prefixed `_` and have only `workflow_call`.

## When to deviate

- **Monorepo with several services:** keep one `delivery.yml`; call `_build.yml` once per service with a `service` input
  and use `paths` filters (or a changed-files job) to skip unchanged services. The tag still promotes all digests of
  that commit together.
- **Pull-based hosts** (an agent on the server pulls new digests): drop the SSH credential from CI entirely; CI only
  publishes and attests. The agent verifies the attestation. Better security, more moving parts; choose it when the
  host fleet is more than a few machines.
- **Library or CLI (no deploy):** only `_checks.yml`; releases through a tag workflow that builds artifacts and attests
  them with `subject-path`.
- **Very small hobby repo:** skip `stg`; a two-environment graph (`dev` on merge, `prd` on tag with approval) is fine.
  Keep digest promotion and the gate.
- **GitHub Enterprise Server:** artifact attestations are not supported; Vercel's Git integration does not work;
  use the prebuilt Vercel fallback and the unsigned-provenance path.
