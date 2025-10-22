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

## Updating Mongo, MinIO, NGINX, and Cloudflared containers

Run the [update_containers](about/scripts.md#update_containerssh) script: 

```sh 
./update_containers.sh
```

- Displays the latest available releases for the containers.

- If an update is available a prompt will be displayed to update along with a link to the release notes.

- When an update is accepted, a backup of your current compose.yaml is created and place in the remotefalcon-backups directory.

- The script directly checks the versions in the containers themselves so it does not rely on the image tags in the [compose.yaml](about/files.md#composeyaml), but it does update the image tag in order to allow rolling back to previous versions if needed.

## Updating compose.yaml, .env, and default.conf

- As of [configure-rf](about/scripts.md#configure-rfsh) script version 10.20.2025.1 it will check and display local and remote file versions and prompt to update if the local versions do not match.

- The current files will backed up to the `remotefalcon-backups` directory before the new versions are downloaded.

- Current values in the [.env](about/files.md#env) file will be copied to the new .env.

- Current image versions and build context lines in the [compose.yaml](about/files.md#composeyaml) will be copied to the new compose.yaml.

- The [default.conf](about/files#defaultconf) has no values that are copied and will be replaced completely.

- You can check the [release notes](release-notes.md) to see what is updated.

1. Run the [configure-rf](about/scripts.md#configure-rfsh) script:
```sh
./configure-rf.sh
```
```sh
🧩 Checking for file updates...

File                      Local Version   Remote Version  Status
───────────────────────── ─────────────── ─────────────── ───────
🔸 compose.yaml            2025.10.12.1    2025.10.14.1    🔄 Update
🔸 .env                    2025.10.10.1    2025.10.13.1    🔄 Update
🔸 default.conf            2025.9.5.1      2025.9.8.1      🔄 Update
───────────────────────── ─────────────── ─────────────── ───────
❓ Would you like to update all outdated files now? (y/n) [n]:
```

2. Answer y to update all out of date files.

## Script Updates

### 10.19.2025.1 configure-rf auto-update

- This version will display any outdated versions and prompt to download the updates.

- Current script versions will be backed up to the `remotefalcon-backups` directory before the new versions are downloaded.

1. Run the [configure-rf](about/scripts.md#configure-rfsh) script:
```sh
./configure-rf.sh
```
```sh
📜 Checking for script updates...

File                      Local Version   Remote Version  Status
───────────────────────── ─────────────── ─────────────── ───────
🔸 shared_functions.sh     2025.9.8.1      2025.9.8.1      ✅ OK
🔸 update_containers.sh    2025.9.8.1      2025.9.8.1      ✅ OK
🔸 health_check.sh         2025.10.19.1    2025.10.19.1    ✅ OK
🔸 sync_repo_secrets.sh    2025.10.12.1    2025.10.13.1    🔄 Update
🔸 minio_init.sh           2025.5.31.1     2025.5.31.1     ✅ OK
🔸 run_workflow.sh         2025.10.12.1    2025.10.13.1    🔄 Update
🔸 configure-rf.sh         2025.10.19.1    2025.10.19.1    ✅ OK
───────────────────────── ─────────────── ─────────────── ───────
❓ Would you like to update all outdated scripts now? (y/n) [n]:
```

2. Answer y to update all out of date files.

### Previous versions of configure-rf manual update

1. Remove the scripts:
```sh
rm configure-rf.sh shared_functions.sh health_check.sh minio_init.sh update_containers.sh update_rf_containers.sh run_workflow.sh sync_repo_secrets.sh
```

2. The command below will re-download the configure-rf script and run it which will then re-download the helper scripts:
```sh
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
chmod +x configure-rf.sh; \
./configure-rf.sh
```

## Updating Remote Falcon Image Builder Workflows

- As of configure-rf script version 2025.10.22.1 automatic workflow updates are possible.

- This feature requires that your GitHub Personal Access Token has the `workflow` permission. 

- If you previously created a GitHub PAT you may not have this permission and will have to follow the [GitHub](install/github.md#create-personal-access-token) setup to configure a new GitHub PAT and save it to your .env

```sh
📜 Checking for image builder workflow updates...
🔗 https://github.com/Ne0n09/remote-falcon-image-builder/

Workflow                  Your Version    Template Version Status
───────────────────────── ─────────────── ─────────────── ───────
🔸 build-all.yml           2025.8.25.1     2025.10.13.1    🔄 Update
🔸 build-container.yml     2025.8.25.1     2025.10.13.1    🔄 Update
───────────────────────── ─────────────── ─────────────── ───────
❓ Would you like to update all image builder workflows now? (y/n) [n]:
```