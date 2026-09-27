## Updating Remote Falcon images

Run the [update_containers](about/scripts.md#update_containerssh) script:

```sh
./update_containers.sh
```

- The script tags images to the commit from the [Remote Falcon GitHub](https://github.com/Remote-Falcon).

- If any newer changes are found from the current container(s) commit tag they will be displayed along with a prompt to update the container(s).

- If the tags are current the script will let you know there are no updates.

- When an update is accepted, a backup of your current compose.yaml is created and placed in the `remotefalcon-backups` directory.

- This allows for versioning of the RF containers and the ability to roll back the [compose.yaml](about/files.md#composeyaml) if an update breaks your Remote Falcon server.

- If [GitHub](install/github.md) is configured the images will be pulled from GHCR if they exist or they can be built manually if they do not exist.

- Otherwise the images are built locally.

## Updating Mongo, Versity Gateway, NGINX, and Cloudflared containers

Health checks can target one container, while the default remains all containers:

```sh
./health_check.sh                 # all services, after the default 10-second delay
./health_check.sh 0s plugins-api   # only plugins-api, without a delay
```

Image upgrades invoke the health script once for only the service being upgraded, including its public endpoint (where available), running state, and recent logs. That invocation allows up to 25 endpoint probes within a two-minute deadline, so a service can finish starting without repeatedly launching the health script. Failed checks restore the previous image and Compose file and check that restored service once. The legacy `health` argument to `update_containers.sh` remains accepted; it does not trigger an additional full-stack check. Fresh installations run their complete health check after storage and routing are initialized.

For older plugins-api and viewer Compose configurations, the image updater adds the missing `QUARKUS_MONGODB_CONNECTION_STRING` runtime setting. This prevents newer Quarkus images from defaulting to MongoDB at `127.0.0.1` inside the application container. Existing explicit Quarkus connection settings are preserved.

For older control-panel configurations, the updater adds the required `DOMAIN` runtime setting and replaces nested `IMAGES_CDN_ENDPOINT=${IMAGES_CDN_ENDPOINT}` indirection with a Compose-expanded URL. This prevents Spring from receiving unresolved `${DOMAIN}` placeholders during startup.

Run the [update_containers](about/scripts.md#update_containerssh) script: 

```sh 
./update_containers.sh
```

- Displays the latest available releases for the containers.

- If an update is available a prompt will be displayed to update along with a link to the release notes.

- When an update is accepted, a backup of your current compose.yaml is created and place in the remotefalcon-backups directory.

- The script directly checks the versions in the containers themselves so it does not rely on the image tags in the [compose.yaml](about/files.md#composeyaml), but it does update the image tag in order to allow rolling back to previous versions if needed.

## Updating scripts and configuration templates

Public releases can be checked and installed without a GitHub account:

```sh
./update_scripts.sh --check
./update_scripts.sh
```

The updater downloads `cloudflared-remotefalcon.tar.gz` and `SHA256SUMS` from the latest GitHub Release, verifies the archive, runs shell syntax checks and the test suite, and backs up installed scripts and configuration before replacing them.

An update automatically applies the current `.env`, `compose.yaml`, and `default.conf` templates. Existing `.env` values and site-specific extra keys are merged into the new example. The new Compose structure is applied while preserving every existing service image reference, including an older CPU-compatible MongoDB version and pinned Remote Falcon commits. Docker Compose validates the merged result before any active configuration is replaced. The prior files remain in the dated `remotefalcon-backups/scripts-*` directory, and any later update failure restores them automatically.

The released `default.conf` replaces the active file so routing fixes apply automatically. Custom edits made directly to `compose.yaml` outside image references, or directly to `default.conf`, must be represented in the project templates or reapplied from the dated backup.

Running `update_scripts.sh` by itself changes configuration files but does not recreate running containers. Use the complete installer command below when the new configuration and container releases should be applied together.

The image builder uses the unified `build.yml` workflow. `run_workflow.sh` deploys only built Remote Falcon app services and restores prior images and Compose configuration after a failed deployment check.

Infrastructure images use tested version tags in `compose.yaml`. Run `update_containers.sh` to check and apply newer versions with backup, deployment validation, and rollback instead of changing those tags to `latest`.

## Upgrading an installation without `update_scripts.sh`

Installations from before the release updater was added can be upgraded with the current installer. Before upgrading, make a filesystem or VM backup of the MongoDB and MinIO data directories named in `remotefalcon/.env`.

Run the following from the existing installation directory that contains `configure-rf.sh` and the `remotefalcon` directory:

```sh
cd /path/to/cloudflared-remotefalcon
curl -fsSL --retry 3 \
  -o /tmp/cloudflared-remotefalcon-install.sh \
  https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh
chmod +x /tmp/cloudflared-remotefalcon-install.sh
/tmp/cloudflared-remotefalcon-install.sh \
  --update \
  --target "$PWD"
```

The installer verifies the release archive, creates a dated configuration backup, preserves existing `.env` values and image references, and validates the merged Compose configuration before applying it. It then upgrades containers in a safe order, checks each changed service, migrates legacy MinIO objects to Versity Gateway, removes retired containers, and runs the complete health check.

When upgrading from the older per-application image repositories, the installer updates the existing GitHub image-builder repository to the unified `build.yml` workflow and synchronizes the current build settings from `.env`. All five application images are then rebuilt in one matrix workflow. Containers are deployed together only after every image builds successfully. Installations that build locally perform the five builds as one batch before replacing any running application containers.

Versity Gateway initialization is a required upgrade step. The installer creates and verifies the configured image bucket, its owner, and its public-read policy before attempting a legacy MinIO migration or running the final health check. A bucket initialization failure stops the upgrade with the source MinIO data unchanged.

If the current user cannot access Docker, the installer asks whether to add that user to the `docker` group before changing any installation files. Accepting requires the user's `sudo` password. The installer then continues the upgrade immediately as the same user; the user does not need to log out and rerun it. Docker group membership grants root-level privileges on the host, so decline the prompt if that access is not appropriate.

If a service fails its deployment check, its previous image and Compose configuration are restored. A failed MinIO migration leaves the source data unchanged; after a successful verified migration, the old data directory is retained with a dated `.migrated-*` name.

Existing `REPO` and `GITHUB_PAT` settings are reused for GitHub-built images. Without GitHub builds, application images are built locally and the upgrade can take longer.
