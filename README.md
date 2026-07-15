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
    runs-on: ubuntu-latest
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
          cli-version: 2026.7.9-beta.1
          path: .
          email-address: ${{ secrets.ADVERSARY_EMAIL_ADDRESS }}
          password: ${{ secrets.ADVERSARY_PASSWORD }}

      - name: Report digest
        run: echo "Published ${{ steps.publish.outputs.reference }} at ${{ steps.publish.outputs.digest }}"
```

`cli-version` is deliberately required and has no mutable default. Pin the action itself to an exact release tag or full commit SHA and pin the CLI to an exact release. The local builder installs dependencies from `package-lock.json`, `pnpm-lock.yaml`, or `yarn.lock`; configure the matching Node runtime before invoking the action.

### Authentication

For the hosted Adversary Labs registry, pass `email-address` and `password` together. The password is sent only to `adversary login --ci --password-stdin`, which requests a short-lived automation credential. The action removes the raw password from the environment before publishing and deletes its temporary CLI profile when the step exits. Pass the password from GitHub Actions secrets.

If both inputs are omitted, the action does not log in. This supports a runner with preconfigured CLI credentials or an external OCI registry authenticated through Docker’s credential store. Use `remote-reference` for an explicit registry destination:

```yaml
- uses: adversarylabs/actions/publish@v1.0.0
  with:
    cli-version: 2026.7.9-beta.1
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
| `profile` | no | `github-actions` | Isolated CLI credential profile. |
| `email-address` | no | — | Account email; must be paired with `password`. |
| `password` | no | — | Secret account password; must be paired with `email-address`. |
| `registry-host` | no | — | Registry host override. |
| `registry-namespace` | no | — | Default namespace override. |

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
- Validation, dependency installation, and packaging run in a credential-free step. Publication credentials are injected only afterward, so target build and lifecycle scripts cannot read the password from their environment.
- Passwords are never placed in command-line arguments or written by the action; pass them from GitHub Actions secrets so runner-level masking also applies.
- The action requires no write permission for the caller repository. Registry authority comes only from the supplied credential flow.
- Publishing is intentionally separate from the future read-only `run` action so release credentials never enter ordinary review jobs.

## Development

Run the deterministic shell tests locally:

```bash
bash test/test.sh
```

The tests use a local release archive and a fake CLI; they do not contact Adversary Labs or publish artifacts.
