**WORK IN PROGRESS**

## Updating and pulling new Remote Falcon images

Run the update_rf_containers.sh script:

```sh
./update_rf_containers.sh
```

If your images are tagged to the commit short hash the script will compare your current hash to the GitHub hash. If any changes are found they will be displayed along with a prompt to update the container(s). Otherwise, if they are current the script will let you know there are no updates.

This allows for RF containers to be 'tagged' to a hash versus just being tagged to 'latest' which makes it difficult to tell if your containers are outdated and also allows for the ability to roll back the containers if a new update happens to cause something to break or not work as expected.

## Updating Mongo, MinIO, NGINX, and Cloudflared containers

Run the `#!sh update_containers.sh` script with no container name or 'all' at the end to cycle through updating all non-RF containers or specify the specific container:

```sh title="update_containers.sh"
    # 1st argument: container name or all
    # 2nd argument: dry-run - checks and displays updates only, auto-apply will automatically apply any updates, interactive prompts for update
    # 3rd argument: health - add this at the end to automatically run the health check script after update
    ./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]

```

  ```sh
  ./update_containers.sh 
  ./update_containers.sh cloudflared
  ./update_containers.sh nginx
  ./update_containers.sh mongo
  ```

The script directly checks the versions in the containers themselves so it does not rely on the image tags in the compose.yaml.