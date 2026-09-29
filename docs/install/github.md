# Remote Falcon container images

AMD64 installations use public backend images published by this project. The
`plugins-api`, `control-panel`, `viewer`, and `external-api` images are pulled
anonymously from GitHub Container Registry. End users do not need a GitHub
account, repository, Personal Access Token, or Actions configuration.

The `ui` image is built locally because its domain, API URLs, hostname layout,
map settings, and optional analytics settings are compiled into the browser
bundle. Those deployment-specific values are never placed in the public
backend images.

The public workflow builds only `linux/amd64`. Other architectures currently
fall back to local JVM backend builds.

## Legacy private image builder

Existing installations with both `REPO` and `GITHUB_PAT` configured continue
to use their private image-builder repository for all five application images.
This is an advanced compatibility option, not a requirement for a normal
AMD64 installation.

The private workflow and helper scripts remain documented under
[workflows](../about/workflows.md). Keep tokens only in the private `.env`
file. New installations should leave `REPO=username/repo` and `GITHUB_PAT`
empty to use the public backend images.
