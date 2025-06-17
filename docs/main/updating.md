## Updating and building new Remote Falcon images

Run the [update_rf_containers](../scripts/index.md#__tabbed_1_2) script:

```sh
./update_rf_containers.sh
```

- The script tags images to the commit from the [Remote Falcon GitHub](https://github.com/Remote-Falcon).

- If any newer changes are found from the current container(s) commit tag they will be displayed along with a prompt to update the container(s).

- If the tags are current the script will let you know there are no updates.

- When an update is accepted, a backup of your current compose.yaml is created and place in the `remotefalcon-backups` directory.

- This allows for versioning of the RF containers and the ability to roll back the [compose.yaml](../architecture/files.md#composeyaml) if an update breaks your Remote Falcon server.

## Updating Mongo, MinIO, NGINX, and Cloudflared containers

Run the [update_containers](../scripts/index.md#__tabbed_1_3) script: 

```sh 
./update_containers.sh
```

- The script will fetch the latest available releases for the containers.

- If an update is available a prompt will be displayed to update along with a link to the release notes.

- When an update is accepted, a backup of your current compose.yaml is created and place in the remotefalcon-backups directory.

- The script directly checks the versions in the containers themselves so it does not rely on the image tags in the [compose.yaml](../architecture/files.md#composeyaml), but it does update the image tag in order to roll back.

## Updating compose.yaml, .env, and default.conf

Currently there are no automatic updates for these files. Sometimes there are changes or additions that will require an update.

1. The `configure-rf` script will print the existing versions on your system when it runs:
```sh
📜 Existing file versions:
🔸 compose.yaml              2025.5.27.1
🔸 .env                      2025.5.27.1
🔸 default.conf              2025.5.27.1
```
You can check the [release notes](../release-notes.md) to see if there any updates or view the files directly on [GitHub](https://github.com/Ne0n09/cloudflared-remotefalcon/tree/main/remotefalcon) looking for any `# VERSION` comments towards the top of each script.

2. Remove the files:
```sh
rm remotefalcon/compose.yaml remotefalcon/default.conf remotefalcon/.env
```

    !!! warning

        Ensure you have a backup of your .env variables.
    
3. Run the `configure-rf` script to re-download the files and to re-configure your .env variables:
```sh
./configure-rf.sh
```

    !!! note

        To check for updates to the helper scripts check the instructions [here](../scripts/index.md#script-updates)