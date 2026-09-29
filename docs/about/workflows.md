# Image workflows

## Public AMD64 backend workflow

`build-public-images.yml` checks out one immutable Remote Falcon platform
commit and builds `plugins-api`, `control-panel`, `viewer`, and `external-api`
from the monorepo root. The production Dockerfiles require no deployment build
arguments. Each image is published for `linux/amd64` with the same seven-digit
platform commit tag.

The date and `latest` tags are promoted only after all four matrix builds
succeed. The updater also verifies that all four immutable tags exist before an
all-service update, preventing a partially published backend release from
changing the running application stack.

The UI is intentionally excluded because its public URLs and site settings are
build-time values. It is built locally from `apps/ui` during configuration and
upgrades.

## Legacy private build.yml

Installations that already configure `REPO` and `GITHUB_PAT` can continue to
use the private image-builder workflow for all five application images.
`sync_repo_secrets.sh` updates its build settings and `run_workflow.sh` starts
the workflow, deploys only the selected services, and restores prior images and
Compose configuration after a failed deployment check.
