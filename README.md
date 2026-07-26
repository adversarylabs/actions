# Adversary Actions

Reusable GitHub Actions for pushing and running Adversary Labs adversaries.

| Action | Status | Purpose |
| --- | --- | --- |
| [`version`](version) | Available | Synchronize release metadata from a tag and commit it back to the release branch. |
| [`push`](push) | Available | Validate, build, package, and push an adversary to an OCI registry. |
| [`run`](run) | Available | Run one or more adversaries against the checked-out repository. |

## Version an adversary

The version action treats a `v`-prefixed release tag as the source of truth. It updates `adversary.yaml`, synchronizes npm package metadata when present, and commits the result back to the release branch with `[skip-ci]`. Reruns verify and reuse an existing version commit instead of creating another one.

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
  with:
    fetch-depth: 0
    persist-credentials: false

- uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
  with:
    node-version: 22

- name: Synchronize release metadata
  id: version
  uses: adversarylabs/actions/version@v1.0.0
  with:
    tag: ${{ github.ref_name }}
    token: ${{ secrets.RELEASE_GITHUB_TOKEN }}

- name: Push
  uses: adversarylabs/actions/push@v1.0.0
  with:
    token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
    registry-namespace: your-team-slug
    repository-name: ${{ steps.version.outputs.name }}
    push-latest: true
```

Use a fine-grained GitHub token limited to repository contents read/write. The action stores Git authentication only for its fetch and push operations, removes it before returning, never force-pushes, and never receives the registry credential. `sync-npm: auto` updates `package.json` and `package-lock.json` when `package.json` exists; set it to `false` for non-npm adversaries or `true` to require npm metadata.

### Version inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | yes | — | Release tag formatted as `v<semantic-version>`. |
| `path` | no | `.` | Adversary project directory. |
| `branch` | no | `main` | Branch that receives the version commit. |
| `token` | yes | — | Fine-grained GitHub token with repository contents read/write. |
| `sync-npm` | no | `auto` | Synchronize npm metadata when present (`auto`, `true`, or `false`). |

### Version outputs

| Output | Description |
| --- | --- |
| `name` | OCI-compatible name from `adversary.yaml`. |
| `version` | Semantic version without the tag's `v` prefix. |
| `changed` | Whether this invocation created and pushed a version commit. |
| `commit` | Version bump commit, or current branch commit when unchanged. |

## Push an adversary

The push action installs an Adversary CLI release, verifies the release archive against `checksums.txt`, validates the project, packages it, and pushes both the OCI image manifest and adversary-manifest referrer.

```yaml
name: Push adversary

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  push:
    runs-on: depot-ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
        with:
          node-version: 22
          cache: npm

      - name: Push
        id: push
        uses: adversarylabs/actions/push@v1.0.0
        with:
          path: .
          token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
          registry-namespace: your-team-slug
          repository-name: security-reviewer
          push-latest: true

      - name: Report digest
        run: echo "Pushed ${{ steps.push.outputs.reference }} at ${{ steps.push.outputs.digest }}"
```

When `cli-version` is omitted, the action queries GitHub's latest-release endpoint and installs the latest stable Adversary CLI release. GitHub excludes drafts and prereleases from that endpoint. Until a stable release exists, set `cli-version` to an exact prerelease such as `2026.7.17-beta.3`. Pin `cli-version` when reproducible toolchain selection is more important than automatically tracking stable releases, and pin the action itself to an exact release tag or full commit SHA.

The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action. pnpm and Yarn installs require Corepack, which is not bundled with Node.js 25 and later; install Corepack separately on those runtimes. For reproducible pnpm or Yarn installs, pin the exact tool version in the `packageManager` field of `package.json`.

### Authentication

The default `auth-mode: token` accepts an Adversary Labs service-account token. Create a token with `registry:push`, store it as `ADVERSARY_SERVICE_ACCOUNT_TOKEN` in Depot CI or GitHub Actions, and pass your team slug as `registry-namespace`. The action sends the token to `adversary login --token-stdin`, removes it from the environment before pushing, and deletes the temporary CLI profile afterward.

For an interactive run, set `auth-mode: oauth`. The CLI prints a device-login URL and code and waits for approval through your normal OAuth login. The device request currently expires after ten minutes.

Set `auth-mode: existing` to skip login. This supports a runner with a preconfigured CLI profile or an external OCI registry authenticated through Docker’s credential store. When `profile` is omitted, the action uses the CLI's default profile; set `profile` explicitly to use a different preconfigured profile. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: adversarylabs/actions/push@v1.0.0
  with:
    cli-version: 2026.7.9-beta.1
    auth-mode: existing
    remote-reference: ghcr.io/acme/dockerfile:0.1.0
```

For hosted pushes, `repository-name` overrides the remote name independently of the name in `adversary.yaml`. The action combines `registry-host` (default `registry.adversarylabs.ai`), `registry-namespace`, the repository name, and the packaged manifest version. Set `push-latest: true` to push the same digest under `latest` as well. Use `remote-reference` instead when the complete versioned destination must be supplied explicitly; it cannot be combined with `repository-name`.

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cli-version` | no | latest stable release | Exact Adversary CLI release tag. Pin this input to use a prerelease. |
| `path` | no | `.` | Adversary project directory. |
| `builder` | no | `local` | `local` or `docker` package builder. |
| `install-dependencies` | no | `true` | Install dependencies from a supported lockfile before local packaging. Set to `false` when already installed; ignored by the Docker builder. |
| `name` | no | — | Local artifact-name override. |
| `remote-reference` | no | — | Fully qualified OCI destination. |
| `repository-name` | no | — | Remote repository name within `registry-namespace`; preserves the packaged version as its tag. |
| `push-latest` | no | `false` | Also push the same artifact with the `latest` tag. |
| `api-url` | no | hosted API | API endpoint used for login and registry token exchange. |
| `profile` | no | `push-action` for token/OAuth; CLI default for existing | CLI credential profile. |
| `auth-mode` | no | `token` | `token` for a service account, `oauth` for device approval, or `existing` for preconfigured credentials. |
| `token` | with token auth | — | Service-account token supplied through a Depot CI or GitHub Actions secret. |
| `client-name` | no | `Adversary push action` | Name shown on the OAuth device-approval screen. |
| `registry-host` | no | — | Registry host override. |
| `registry-namespace` | with token auth* | — | Team registry namespace. May be omitted when `remote-reference` is explicit. |

### Outputs

| Output | Description |
| --- | --- |
| `reference` | Canonical pushed registry reference. |
| `digest` | Pushed OCI image manifest digest. |
| `manifest-digest` | Pushed adversary-manifest referrer digest. |
| `local-reference` | Canonical reference produced by the package step. |
| `latest-reference` | Pushed `latest` reference when `push-latest` is enabled. |

## Run adversaries

The run action installs an Adversary CLI release, optionally authenticates for private registry pulls, and executes `adversary run` against the checked-out source. It maps every active `adversary run` flag and supports model-backed adversaries through provider inputs and secrets. Use the same composite action from GitHub Actions or Depot CI (`runs-on: depot-ubuntu-latest`).

```yaml
name: Adversary review

on:
  pull_request:

permissions:
  contents: read

jobs:
  review:
    runs-on: depot-ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          fetch-depth: 0

      - name: Run adversaries
        id: review
        uses: adversarylabs/actions/run@v1.0.0
        with:
          adversaries: |
            adversarylabs/dockerfile
            adversarylabs/go-cli
          path: .
          base: ${{ github.event.pull_request.base.sha }}
          head: ${{ github.event.pull_request.head.sha }}
          auth-mode: token
          token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
          registry-namespace: your-team-slug
          model-provider: openai
          model: gpt-4o
          model-api-key: ${{ secrets.OPENAI_API_KEY }}
          format: json

      - name: Report outcome
        if: always()
        run: |
          echo "outcome=${{ steps.review.outputs.outcome }}"
          echo "findings=${{ steps.review.outputs.findings-count }}"
```

When `cli-version` is omitted, the action installs the latest stable Adversary CLI release (same resolution rules as push). Pin `cli-version` and the action ref for reproducible CI. `path` defaults to `.`.

For pull-request change detection, pass `base` and `head` git SHAs or refs. Use `all-files: true` for a full-tree scan (for example on `push` to main). `base`/`head` and `all-files` cannot be combined.

### Authentication

Default `auth-mode: none` skips login so public and local adversaries work without a token. For private registry pulls in CI, set `auth-mode: token` and pass a service-account token with pull access (not a push credential) from Depot CI or GitHub Actions secrets. The action sends the token to `adversary login --token-stdin`, clears it from the environment, and removes a unique temporary profile afterward so caller-owned profiles are never logged out.

```yaml
- uses: adversarylabs/actions/run@v1.0.0
  with:
    adversaries: your-team/private-reviewer
    auth-mode: token
    token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
    registry-namespace: your-team-slug
```

`auth-mode: oauth` uses interactive device login. `auth-mode: existing` uses a preconfigured CLI profile or Docker credential store and never logs in or out.

### Model-backed adversaries

Provide `model-provider` (`openai`, `anthropic`, or `fireworks`), `model`, and `model-api-key` (a secret). The action maps the key to `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `FIREWORKS_API_KEY` and never places API keys on the CLI argument list. Optional `openai-base-url`, `anthropic-base-url`, and `fireworks-base-url` set the corresponding `ADVERSARY_*_BASE_URL` overrides. You may also set the standard provider environment variables on the step yourself and omit `model-api-key`.

### Exit codes and findings

The step preserves CLI exit codes: `0` success, `1` findings, `2` usage/configuration, `3` execution failure, `4` network/auth. Set `fail-on-findings: false` to keep findings in outputs while exiting `0` (useful when a later step posts a report). With `format: json`, `findings-count` and `result-file` are populated from captured stdout.

### Run inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `adversaries` | yes | — | One or more adversary refs (whitespace or newlines). |
| `cli-version` | no | latest stable release | Exact Adversary CLI release tag. |
| `path` | no | `.` | Source directory to review. |
| `base` | no | — | Git base ref for change detection. |
| `head` | no | — | Git head ref for change detection. |
| `all-files` | no | `false` | Scan the entire target instead of a change. |
| `builder` | no | `local` | `local` or `docker` builder for local adversaries. |
| `build` | no | `false` | Build a local adversary before running. |
| `force` | no | `false` | Run even when file triggers do not match. |
| `format` | no | `text` | `text` or `json` output. |
| `keep-temp` | no | `false` | Keep the temporary run directory. |
| `no-network` | no | `false` | Require network isolation for the adversary child. |
| `verbose` | no | `false` | Detailed execution diagnostics. |
| `include-suppressed` | no | `false` | Request suppressed findings when supported. |
| `shell` | no | `false` | UNSAFE host shell in the adversary working directory. |
| `allow-unsafe-host-execution` | no | `false` | Allow unrestricted HostExecutor for an unknown publisher. |
| `timeout` | no | — | Max execution time (Go duration, for example `10m`). |
| `build-timeout` | no | — | Max explicit local build time (Go duration). |
| `model-provider` | no | — | `openai`, `anthropic`, or `fireworks`. |
| `model` | no | — | Provider model identifier. |
| `model-api-key` | no | — | Provider API key secret mapped from `model-provider`. |
| `openai-base-url` | no | — | OpenAI-compatible base URL override. |
| `anthropic-base-url` | no | — | Anthropic-compatible base URL override. |
| `fireworks-base-url` | no | — | Fireworks-compatible base URL override. |
| `fail-on-findings` | no | `true` | Fail the step when the review reports findings. |
| `api-url` | no | hosted API | API endpoint used for login. |
| `profile` | no | ephemeral `run-action-<id>` for token/OAuth; CLI default otherwise | For `existing`, the CLI profile to use (never logged out). For token/OAuth, used only as a name prefix for a unique action-owned profile that is removed after the step. |
| `auth-mode` | no | `none` | `none`, `token`, `oauth`, or `existing`. |
| `token` | with token auth | — | Pull-scoped service-account token secret. |
| `client-name` | no | `Adversary run action` | Name shown on the OAuth device-approval screen. |
| `registry-host` | no | — | Registry host override. |
| `registry-namespace` | no | — | Team registry namespace for service-account login. |

### Run outputs

| Output | Description |
| --- | --- |
| `exit-code` | CLI exit code (`0`–`4`). |
| `findings-count` | Finding count when `format` is `json`; empty for text. |
| `result-file` | Path to captured JSON stdout when `format` is `json`. |
| `outcome` | `success`, `findings`, or `failure`. |

## Security model

- **Push**: target source is built because packaging is required. Use only on reviewed code and protected release refs. Validation and packaging finish before authentication so target build scripts never see the service-account token. Prefer a push-scoped token.
- **Run**: read-only review of the checked-out tree. Prefer a pull-scoped service-account token (or `auth-mode: none` for public/local adversaries). Do not reuse push credentials in ordinary review jobs.
- The CLI archive is checksum-verified before execution. Pin `cli-version` in the caller workflow when exact toolchain reproducibility is required.
- Service-account tokens are passed through standard input, removed from the environment before `run`/`push`, and temporary CLI profiles are removed afterward.
- Model API keys are passed only through environment variables (never CLI flags) and are unset from action input env before the CLI is invoked.
- Neither action requires write permission for the caller repository. Registry authority comes only from the supplied credential flow.

## Development

Run the deterministic shell test suite locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Adversary Labs or push artifacts.
