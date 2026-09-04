# Adversary Actions

Reusable GitHub Actions for pushing and running Adversary Labs adversaries.

| Action | Status | Purpose |
| --- | --- | --- |
| [`version`](version) | Available | Synchronize release metadata and runtime identity, rebuild, verify, and commit from a release version. |
| [`push`](push) | Available | Validate, build, package, and push an adversary to an OCI registry. |
| [`run`](run) | Available | Run one or more adversaries against the checked-out repository. |

## Version an adversary

The version action treats a `v`-prefixed release version as the source of truth. It updates `adversary.yaml`, synchronizes npm package metadata when present, safely updates a single literal `version` property in the `new Adversary({...})` initializer, rebuilds Node projects, and imports the built runtime to require `createApp().version` to equal the release version. Changed, already tracked `dist/` artifacts are included in the metadata commit. Reruns verify and reuse an existing version commit instead of creating another one.

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
  uses: adversarylabs/actions/version@v1.1.0
  with:
    tag: ${{ github.ref_name }}
    token: ${{ secrets.RELEASE_GITHUB_TOKEN }}

- name: Push
  uses: adversarylabs/actions/push@v1.1.0
  with:
    auth-mode: token
    token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
    registry-namespace: your-team-slug
    repository-name: ${{ steps.version.outputs.name }}
    push-latest: true
```

Use a fine-grained GitHub token limited to repository contents read/write. The action stores Git authentication only for its fetch and push operations, removes it before returning, never force-pushes, and never receives the registry credential. `sync-npm: auto` updates `package.json` and `package-lock.json` when `package.json` exists; set it to `false` for non-npm adversaries or `true` to require npm metadata.

For Node adversaries, the runtime command must identify a project-relative JavaScript entrypoint and the built module must export `createApp()`. A literal runtime version is synchronized with a token-aware source edit; computed or omitted versions are left untouched and accepted only when the rebuilt app reports the correct version (for example, when a future SDK infers it from package metadata). Multiple initializers and runtimes that cannot prove their identity fail closed. Non-Node adversaries keep the metadata-only behavior. Dependency installation and builds use the repository's npm, pnpm, or Yarn lockfile; an existing build script is run when present.

### Prepare before tagging

Existing tag-triggered workflows remain supported, but they necessarily build from a working tree that differs from the tag when a version update is needed. For signed tag/runtime identity, run this action on the release branch *before* creating the tag: pass the intended `v<version>` as `tag`, wait for the action to push its commit, then create the annotated or signed tag at `${{ steps.version.outputs.commit }}`. The existing release workflow should become verify-and-publish-only for that tag. This ordering makes the tagged tree, rebuilt runtime, registry bytes, and protocol version identical.

The preparation workflow should check out the release branch itself (not a tag) with full history, invoke `version` with the intended tag text, and hand its `commit` output to authorized signing/release tooling. That tooling must fetch the pushed commit and create the tag at that exact object; it should reject an existing tag or a branch that advanced unexpectedly. The tag-triggered workflow then validates and publishes without mutating source.

During migration, do not create the tag until the version step succeeds. The backward-compatible tag-triggered mode still fixes and verifies the published runtime and main-branch metadata, but it cannot retroactively change the already-created tag object.

### Version inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | yes | — | Intended release tag formatted as `v<semantic-version>`; it may be prepared before the tag exists. |
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

The push action installs an Adversary CLI release, verifies the release archive against `checksums.txt`, validates the project, packages it, and pushes both the OCI image manifest and adversary-manifest referrer. Private publishes to the authenticated team namespace on the Adversary Labs registry are signed automatically; the publisher receives only the signature and public team delegation, never a private key.

```yaml
name: Push adversary

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read
  id-token: write

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
        uses: adversarylabs/actions/push@v1.1.0
        with:
          path: .
          registry-namespace: your-team-slug
          repository-name: security-reviewer
          push-latest: true

      - name: Report digest
        run: echo "Pushed ${{ steps.push.outputs.reference }} at ${{ steps.push.outputs.digest }}"
```

When `cli-version` is omitted, the action installs its pinned default, `2026.9.4`. Set `cli-version` explicitly to test a different release. Pin the action itself to an exact release tag or full commit SHA for reproducible CI.

The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action. pnpm and Yarn installs require Corepack, which is not bundled with Node.js 25 and later; install Corepack separately on those runtimes. For reproducible pnpm or Yarn installs, pin the exact tool version in the `packageManager` field of `package.json`.

### Authentication

The default `auth-mode: auto` requests the job identity with audience `https://adversarylabs.ai`, exchanges it for a ten-minute team credential, and deletes the temporary CLI profile afterward. Add `permissions: id-token: write`, trust the repository under the team page, and pass the team slug as `registry-namespace`. This works both in GitHub Actions and native Depot CI workflows; Depot identities can also be pinned to the Depot organization ID. For v1 compatibility, `auto` selects token authentication when the `token` input is populated; explicit `oidc` never falls back to a long-lived token.

For CI systems without compatible OIDC, `auth-mode: token` accepts an Adversary Labs service-account token. Create one with `registry:push`, store it as a CI secret, and pass it through the `token` input.

For an interactive run, set `auth-mode: oauth`. The CLI prints a device-login URL and code and waits for approval through your normal OAuth login. The device request currently expires after ten minutes.

Set `auth-mode: existing` to skip login. This supports a runner with a preconfigured CLI profile or an external OCI registry authenticated through Docker’s credential store. When `profile` is omitted, the action uses the CLI's default profile; set `profile` explicitly to use a different preconfigured profile. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: adversarylabs/actions/push@v1.1.0
  with:
    cli-version: 2026.7.9-beta.1
    auth-mode: existing
    remote-reference: ghcr.io/acme/dockerfile:0.1.0
```

For hosted pushes, `repository-name` overrides the remote name independently of the name in `adversary.yaml`. It may be nested, such as `go/security`, and is always rooted under the authenticated team namespace (`adversarylabs/go/security`). A value already rooted at that same namespace is not duplicated. `library/*` is reserved for server-side official and partner promotion. The action combines `registry-host` (default `registry.adversarylabs.ai`), `registry-namespace`, the repository name, and the packaged manifest version. Set `push-latest: true` to push the same digest under `latest` as well. Use `remote-reference` instead when the complete versioned destination must be supplied explicitly; it cannot be combined with `repository-name`.

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cli-version` | no | `2026.9.4` | Exact Adversary CLI release tag. |
| `path` | no | `.` | Adversary project directory. |
| `builder` | no | `local` | `local` or `docker` package builder. |
| `install-dependencies` | no | `true` | Install dependencies from a supported lockfile before local packaging. Set to `false` when already installed; ignored by the Docker builder. |
| `name` | no | — | Local artifact-name override. |
| `remote-reference` | no | — | Fully qualified OCI destination. |
| `repository-name` | no | — | Remote repository name within `registry-namespace`; preserves the packaged version as its tag. |
| `push-latest` | no | `false` | Also push the same artifact with the `latest` tag. |
| `api-url` | no | hosted API | API endpoint used for login and registry token exchange. |
| `profile` | no | `push-action` for token/OAuth; CLI default for existing | CLI credential profile. |
| `auth-mode` | no | `auto` | `auto` uses a supplied token or otherwise OIDC; `oidc` requires GitHub Actions or Depot CI identity; `token`, `oauth`, and `existing` select those explicit flows. |
| `token` | with token auth | — | Service-account token supplied through a CI secret. For v1 compatibility, supplying it without `auth-mode` selects token auth. |
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
| `namespace-signature-digest` | Platform-issued namespace signature referrer digest for a hosted private publish; empty for external or public repositories. |
| `namespace-trust-digest` | Platform-endorsed team trust referrer digest for a hosted private publish; empty for external or public repositories. |

## Run adversaries

The run action installs an Adversary CLI release, optionally authenticates for registry pulls, and executes `adversary run` against the checked-out source. Pull-request runs default to the PR diff, automatically post findings as a submitted GitHub review, and do not fail the check merely because findings exist. Configuration, authentication, network, and execution failures still fail the step. The action pulls accessible adversaries, detects which ones match the change, and runs the selected set. Set `adversaries` to one or more references to run an explicit set instead, or set `all-files: true` to review the entire repository. OIDC pulls from the Adversary Labs registry fetch and verify the public team delegation automatically, so a valid hosted private signature can use host execution without the unsafe override. External copies such as GHCR remain untrusted. It supports model-backed adversaries through provider inputs and secrets. Use the same composite action from GitHub Actions or Depot CI (`runs-on: depot-ubuntu-latest`).

```yaml
name: Adversary review

on:
  pull_request:

permissions:
  contents: read
  id-token: write
  pull-requests: write

jobs:
  review:
    runs-on: depot-ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          fetch-depth: 0

      - name: Run adversaries
        id: review
        uses: adversarylabs/actions/run@v1
        with:
          path: .
          auth-mode: oidc
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

When `cli-version` is omitted, the action installs its pinned default, `2026.9.4`. Set `cli-version` explicitly to test a different release, and pin the action ref for reproducible CI. `path` defaults to `.`.

### Artifact cache

The action stores pulled adversaries in a content-addressed repository under `data-dir`. It still checks the remote catalog and resolves each OCI reference on every run; when the resolved digest is already present, the CLI reuses the local artifact without downloading its layers and verifies it before execution. `data-dir` defaults to `${RUNNER_TEMP}/adversary-data`, and an existing `ADVERSARY_DATA_DIR` environment value remains supported when the input is omitted.

Cache only this artifact directory. Adversary Labs credentials use the operating system's separate configuration directory and are not written beneath `data-dir`. The artifact cache does contain the complete contents of private adversaries, so scope access to jobs that are authorized to pull those packages.

Depot CI can persist the directory with a durable cache disk. Use a repository-specific disk name unless cross-repository sharing is intentional:

```yaml
- name: Mount adversary cache
  uses: depot/cache-mount@v1
  with:
    name: adversary-${{ github.event.repository.id }}-v1
    path: /mnt/adversary

- name: Run adversaries
  uses: adversarylabs/actions/run@v1
  with:
    data-dir: /mnt/adversary
    adversaries: auto
    auth-mode: oidc
    registry-namespace: your-team-slug
```

Other CI cache implementations can restore and save `${{ runner.temp }}/adversary-data` while using the action's default, or mount a different absolute path and pass it through `data-dir`. Include `v1` in the cache key so a future incompatible repository format can move to a fresh cache.

Automatic selection is the default. These are equivalent:

```yaml
- uses: adversarylabs/actions/run@v1

- uses: adversarylabs/actions/run@v1
  with:
    adversaries: auto
```

To bypass automatic selection, provide explicit references. Each explicit adversary still applies its own changed-file trigger unless `force: true` is set:

```yaml
- uses: adversarylabs/actions/run@v1
  with:
    adversaries: |
      web/nextjs
      web/react
```

Pull-request scope is inferred from the CI environment. Use `base` and `head` to override the inferred diff, or `all-files: true` to opt into a full-repository scan. `base`/`head` and `all-files` cannot be combined.

### Pull-request reviews

On `pull_request` and `pull_request_target` events, `github-review: auto` posts findings through GitHub's GraphQL review API and `github-submit: true` submits the review as an informational comment. Grant `pull-requests: write`; the action uses `github.token` unless `github-token` is supplied. The default summary covers actual findings only and uses the configured model provider for one cross-adversary synthesis; clean adversaries add nothing, and a clean run posts no review. Set `include-summary: false` to omit that persistent summary while retaining inline findings and findings that cannot be placed on the diff. Set `github-review: false` to keep results in the job log only.

### Authentication

Default `auth-mode: none` skips login so public and local adversaries work without a token. For private pulls, prefer `auth-mode: oidc`, add `permissions: id-token: write`, trust the GitHub or Depot repository identity on the team page, and set `registry-namespace`. The exchanged pull credential lasts ten minutes and the action removes its unique temporary profile afterward.

```yaml
- uses: adversarylabs/actions/run@v1
  with:
    adversaries: your-team/private-reviewer
    auth-mode: oidc
    registry-namespace: your-team-slug
```

Use `auth-mode: token` with a pull-scoped service-account token when OIDC is unavailable. `auth-mode: oauth` uses interactive device login. `auth-mode: existing` uses a preconfigured CLI profile or Docker credential store and never logs in or out.

### Model-backed adversaries

Provide `model-provider` (`openai`, `anthropic`, `fireworks`, or `camel`), `model`, and `model-api-key` (a secret). The action maps the key to `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `FIREWORKS_API_KEY`, or `CAMEL_API_KEY` and never places API keys on the CLI argument list. Optional `openai-base-url`, `anthropic-base-url`, `fireworks-base-url`, and `camel-base-url` set the corresponding `ADVERSARY_*_BASE_URL` overrides. You may also set the standard provider environment variables on the step yourself and omit `model-api-key`.

### Exit codes and findings

The action records the CLI exit code and outcome in its outputs. By default, CLI exit `1` (findings) becomes a successful step after the review is posted; exits `2`–`4` still fail. Set `fail-on-findings: true` only when findings should block the check. With `format: json`, `findings-count` and `result-file` are populated from captured stdout.

### Run inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `adversaries` | no | `auto` | `auto` to pull and select matching accessible adversaries, or one or more explicit refs (whitespace or newlines). |
| `cli-version` | no | `2026.9.4` | Exact Adversary CLI release tag. |
| `path` | no | `.` | Source directory to review. |
| `data-dir` | no | `${RUNNER_TEMP}/adversary-data` | Absolute directory containing cacheable adversary artifacts. `ADVERSARY_DATA_DIR` is used as a fallback when set. |
| `base` | no | — | Git base ref for change detection. |
| `head` | no | — | Git head ref for change detection. |
| `all-files` | no | `false` | Opt into a full-repository scan instead of the inferred PR or branch diff. |
| `github-review` | no | `auto` | `auto`, `true`, or `false`; auto posts on pull-request events. |
| `github-submit` | no | `true` | Submit the GitHub review as an informational comment instead of leaving it pending. |
| `include-summary` | no | `true` | Include the aggregate assessment/opinion in the review body; findings are still posted when false. |
| `github-token` | no | `github.token` | Token used to post the GitHub review. |
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
| `model-provider` | no | — | `openai`, `anthropic`, `fireworks`, or `camel`. |
| `model` | no | — | Provider model identifier. |
| `model-api-key` | no | — | Provider API key secret mapped from `model-provider`. |
| `openai-base-url` | no | — | OpenAI-compatible base URL override. |
| `anthropic-base-url` | no | — | Anthropic-compatible base URL override. |
| `fireworks-base-url` | no | — | Fireworks-compatible base URL override. |
| `camel-base-url` | no | — | Camel-compatible base URL override. |
| `fail-on-findings` | no | `false` | Fail the step when the review reports findings. |
| `api-url` | no | hosted API | API endpoint used for login. |
| `profile` | no | ephemeral `run-action-<id>` for token/OAuth; CLI default otherwise | For `existing`, the CLI profile to use (never logged out). For token/OAuth, used only as a name prefix for a unique action-owned profile that is removed after the step. |
| `auth-mode` | no | `none` | `none`, `oidc`, `token`, `oauth`, or `existing`. |
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
- OIDC credentials expire after ten minutes. OIDC and service-account tokens are passed through standard input, removed from the environment before `run`/`push`, and temporary CLI profiles are removed afterward.
- The run action's `data-dir` contains package payloads and trust metadata, never credentials. Treat caches containing private adversaries as private data and scope them accordingly.
- Model API keys are passed only through environment variables (never CLI flags) and are unset from action input env before the CLI is invoked.
- Neither action requires write permission for the caller repository. Registry authority comes only from the supplied credential flow.

## Development

Run the deterministic shell test suite locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Adversary Labs or push artifacts.
