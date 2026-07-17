# Adversary Actions

Reusable GitHub Actions for publishing and running Adversary Labs adversaries.

| Action | Status | Purpose |
| --- | --- | --- |
| [`publish`](publish) | Available | Validate, build, package, and publish an adversary to an OCI registry. |
| `run` | Planned | Run one or more adversaries against the checked-out repository. |

## Publish an adversary

The publish action installs an exact Adversary CLI release, verifies the release archive against `checksums.txt`, validates the project, packages it, and pushes both the OCI image manifest and adversary-manifest referrer.

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
          cli-version: ${{ vars.ADVERSARY_CLI_VERSION }}
          path: .
          token: ${{ secrets.ADVERSARY_SERVICE_ACCOUNT_TOKEN }}
          registry-namespace: your-team-slug

      - name: Report digest
        run: echo "Published ${{ steps.publish.outputs.reference }} at ${{ steps.publish.outputs.digest }}"
```

`cli-version` is deliberately required and has no mutable default. Set `ADVERSARY_CLI_VERSION` to an exact CLI release containing service-account `--token-stdin` support. Pin the action itself to an exact release tag or full commit SHA. The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action.

### Authentication

The default `auth-mode: token` accepts an Adversary Labs service-account token. Create a token with `registry:push`, store it as `ADVERSARY_SERVICE_ACCOUNT_TOKEN` in Depot CI or GitHub Actions, and pass your team slug as `registry-namespace`. The action sends the token to `adversary login --token-stdin`, removes it from the environment before publishing, and deletes the temporary CLI profile afterward.

For an interactive run, set `auth-mode: oauth`. The CLI prints a device-login URL and code and waits for approval through your normal OAuth login. The device request currently expires after ten minutes.

Set `auth-mode: existing` to skip login. This supports a runner with a preconfigured CLI profile or an external OCI registry authenticated through Docker’s credential store. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: adversarylabs/actions/publish@v1.0.0
  with:
    cli-version: 2026.7.9-beta.1
    auth-mode: existing
    remote-reference: ghcr.io/acme/dockerfile:0.1.0
```

### Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cli-version` | yes | — | Exact Adversary CLI release tag. |
| `path` | no | `.` | Adversary project directory. |
| `builder` | no | `local` | `local` or `docker` package builder. |
| `install-dependencies` | no | `true` | Install dependencies from a supported lockfile before local packaging. Set to `false` when already installed; ignored by the Docker builder. |
| `name` | no | — | Local artifact-name override. |
| `remote-reference` | no | — | Fully qualified OCI destination. |
| `api-url` | no | hosted API | API endpoint used for login and registry token exchange. |
| `profile` | no | `publish-action` | Isolated CLI credential profile. |
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

## Security model

- Target source is built because publishing necessarily packages the adversary. Use this action only on reviewed code and protected release refs.
- The CLI archive is checksum-verified before execution. The exact CLI version remains part of the caller’s reviewed workflow.
- Validation, dependency installation, and packaging finish before authentication, so target build and lifecycle scripts never run with the service-account token.
- The service-account token is passed through standard input, removed from the environment before `push`, and its temporary CLI profile is removed afterward.
- The action requires no write permission for the caller repository. Registry authority comes only from the supplied credential flow.
- Publishing is intentionally separate from the future read-only `run` action so release credentials never enter ordinary review jobs.

## Development

Run the deterministic shell tests locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Adversary Labs or publish artifacts.
