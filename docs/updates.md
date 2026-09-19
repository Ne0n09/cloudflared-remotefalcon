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

The updater downloads `cloudflared-remotefalcon.tar.gz` and `SHA256SUMS` from the latest GitHub Release, verifies the archive, runs shell syntax checks and the test suite, and backs up installed scripts before replacing them.

An update preserves `remotefalcon/.env`, the active `compose.yaml`, and `default.conf`. New configuration templates are written as `compose.yaml.new` and `default.conf.new` for review. Run `./health_check.sh 0s` after applying any template changes.

The image builder uses the unified `build.yml` workflow. `run_workflow.sh` deploys only built Remote Falcon app services and restores prior images and Compose configuration after a failed deployment check.
