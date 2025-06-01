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
