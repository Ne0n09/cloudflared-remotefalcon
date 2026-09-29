# Image workflows

## Public AMD64 and ARM64 backend workflow

`build-public-images.yml` checks out one immutable Remote Falcon platform
commit and builds `plugins-api`, `control-panel`, `viewer`, and `external-api`
from the monorepo root. The production Dockerfiles require no deployment build
arguments. Each image is published as a multi-platform manifest for
`linux/amd64` and `linux/arm64` with the same seven-digit platform commit tag.
Each architecture builds on a native Ubuntu 24.04 GitHub-hosted runner before the workflow
combines both outputs into the coordinated manifest.

Before promotion, every architecture image is pulled on its native runner and
started against a temporary MongoDB container. The smoke test verifies the
pulled architecture and requires the Remote Falcon application process to
remain running. A failed AMD64 or ARM64 smoke test prevents the coordinated
SHA, date, and `latest` tags from being published.

The date and `latest` tags are promoted only after all four matrix builds
succeed. The updater also verifies that all four immutable tags exist before an
all-service update, preventing a partially published backend release from
changing the running application stack.

Daily scheduled runs resolve the current upstream platform SHA and inspect all
four immutable image tags. A service is skipped only when its SHA tag contains
both required architectures. If all four multi-platform images exist, the
workflow performs no builds or tag promotion. Manual dispatches intentionally
rebuild all four services.

The UI is intentionally excluded because its public URLs and site settings are
build-time values. It is built locally from `apps/ui` during configuration and
upgrades.

## Deprecated private build.yml

!!! warning "Legacy compatibility only"

    Do not create a private image-builder repository for a new installation. The original setup instructions are retained in the `legacy-private-builder` documentation version.

Installations that already configure `REPO` and `GITHUB_PAT` can continue to
use the private image-builder workflow for all five application images.
`sync_repo_secrets.sh` updates its build settings and `run_workflow.sh` starts
the workflow, deploys only the selected services, and restores prior images and
Compose configuration after a failed deployment check.
