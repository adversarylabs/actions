# Adversary Actions

Reusable GitHub Actions for publishing and running Adversary Labs adversaries.

| Action | Status | Purpose |
| --- | --- | --- |
| [`publish`](publish) | Available | Validate, build, package, and publish an adversary to an OCI registry. |
| `run` | Planned | Run one or more adversaries against the checked-out repository. |

## Publish an adversary

The publish action installs an Adversary CLI release, verifies the release archive against `checksums.txt`, validates the project, packages it, and pushes both the OCI image manifest and adversary-manifest referrer.

```yaml
name: Publish adversary

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  publish:
    runs-on: depot-ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0
        with:
          node-version: 22
          cache: npm

      - name: Publish
        id: publish
        uses: adversarylabs/actions/publish@v1.0.0
        with:
          path: .
          token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
          registry-namespace: your-team-slug
          repository-name: security-reviewer
          publish-latest: true

      - name: Report digest
        run: echo "Published ${{ steps.publish.outputs.reference }} at ${{ steps.publish.outputs.digest }}"
```

When `cli-version` is omitted, the action queries GitHub's latest-release endpoint and installs the latest stable Adversary CLI release. GitHub excludes drafts and prereleases from that endpoint. Until a stable release exists, set `cli-version` to an exact prerelease such as `2026.7.17-beta.3`. Pin `cli-version` when reproducible toolchain selection is more important than automatically tracking stable releases, and pin the action itself to an exact release tag or full commit SHA.

The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action. pnpm and Yarn installs require Corepack, which is not bundled with Node.js 25 and later; install Corepack separately on those runtimes. For reproducible pnpm or Yarn installs, pin the exact tool version in the `packageManager` field of `package.json`.

### Authentication

The default `auth-mode: token` accepts an Adversary Labs service-account token. Create a token with `registry:push`, store it as `ADVERSARY_SERVICE_ACCOUNT_TOKEN` in Depot CI or GitHub Actions, and pass your team slug as `registry-namespace`. The action sends the token to `adversary login --token-stdin`, removes it from the environment before publishing, and deletes the temporary CLI profile afterward.

For an interactive run, set `auth-mode: oauth`. The CLI prints a device-login URL and code and waits for approval through your normal OAuth login. The device request currently expires after ten minutes.

Set `auth-mode: existing` to skip login. This supports a runner with a preconfigured CLI profile or an external OCI registry authenticated through Docker’s credential store. When `profile` is omitted, the action uses the CLI's default profile; set `profile` explicitly to use a different preconfigured profile. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: adversarylabs/actions/publish@v1.0.0
  with:
    cli-version: 2026.7.9-beta.1
    auth-mode: existing
    remote-reference: ghcr.io/acme/dockerfile:0.1.0
```

For hosted publishing, `repository-name` overrides the remote name independently of the name in `adversary.yaml`. The action combines `registry-host` (default `registry.adversarylabs.ai`), `registry-namespace`, the repository name, and the packaged manifest version. Set `publish-latest: true` to publish the same digest under `latest` as well. Use `remote-reference` instead when the complete versioned destination must be supplied explicitly; it cannot be combined with `repository-name`.

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
| `publish-latest` | no | `false` | Also publish the same artifact with the `latest` tag. |
| `api-url` | no | hosted API | API endpoint used for login and registry token exchange. |
| `profile` | no | `publish-action` for token/OAuth; CLI default for existing | CLI credential profile. |
| `auth-mode` | no | `token` | `token` for a service account, `oauth` for device approval, or `existing` for preconfigured credentials. |
| `token` | with token auth | — | Service-account token supplied through a Depot CI or GitHub Actions secret. |
| `client-name` | no | `Adversary publish action` | Name shown on the OAuth device-approval screen. |
| `registry-host` | no | — | Registry host override. |
| `registry-namespace` | with token auth* | — | Team registry namespace. May be omitted when `remote-reference` is explicit. |

### Outputs

| Output | Description |
| --- | --- |
| `reference` | Canonical published registry reference. |
| `digest` | Published OCI image manifest digest. |
| `manifest-digest` | Published adversary-manifest referrer digest. |
| `local-reference` | Canonical reference produced by the package step. |
| `latest-reference` | Published `latest` reference when `publish-latest` is enabled. |

## Security model

- Target source is built because publishing necessarily packages the adversary. Use this action only on reviewed code and protected release refs.
- The CLI archive is checksum-verified before execution. Pin `cli-version` in the caller workflow when exact toolchain reproducibility is required.
- Validation, dependency installation, and packaging finish before authentication, so target build and lifecycle scripts never run with the service-account token.
- The service-account token is passed through standard input, removed from the environment before `push`, and its temporary CLI profile is removed afterward.
- The action requires no write permission for the caller repository. Registry authority comes only from the supplied credential flow.
- Publishing is intentionally separate from the future read-only `run` action so release credentials never enter ordinary review jobs.

## Development

Run the deterministic shell test suite locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Adversary Labs or publish artifacts.
