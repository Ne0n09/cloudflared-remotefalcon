# Release Notes

## 2025.05.27.1

- Revamped pretty much everything! The configure-rf, update_containers, and update_rf_containers scripts have been updated to add colorization and simplification. 
- Image checking in the update_rf_containers script has been updated.
- Updated various things to include MinIO for object storage! This allows you to use the 'Image Hosting' tab in the Control Panel to locally store viewer page images.
- Added minio_init script to assist in configuring the minio container for pretty much a hands off setup of MinIO.
- Updated compose.yaml to include minio container.
- Updated default.conf to add /remote-falcon-images path to point to minio container.
- Updated update_containers.sh to check for minio container updates.
- Added various variables to the .env file and moved some things in the compose.yaml to the .env file.
- Updated health_check script to display MinIO server local LAN link, server status, and bucket object info.
- Various other changes.

## 2025.05.12.1

- Updated update_containers.sh
- Removed the prompt to backup and just automatically backup Mongo.
- Updated sed command in prompt_to_update().
- Extract Mongo DB name, username, and password from MONGO_URI in the .env file.
- Removed health_check from update_containers.sh to simplify the script.

## 2025.3.30.1

- Fixed the update_rf_containers script. The build context for a container would incorrectly be updated to the context of the repo of another container.
- Fixed the wrong repo being displayed on the update prompt.

## 2025.3.6.1

- Updated update_rf_containers script to set the context to the GitHub commit hash in compose.yaml when updating to new image tag:		

```yaml title="compose.yaml" linenums="1" hl_lines="3"
control-panel:
    build:
      context: https://github.com/Remote-Falcon/remote-falcon-control-panel.git#f12f5fbfa90c6f2358a2843ec340de771a7e88bf
      args:
        - OTEL_OPTS=
    image: control-panel:f12f5fb
    container_name: control-panel
```	
- Updated update_rf_containers script to update the VERSION variable to YYYY.MM.DD version format when RF images are built and deployed.
- Updated compose.yaml to change jwt.user to use new ${USER_JWT_KEY} .env variable.
- Added USER_JWT_KEY to .env file.
- Updated configure-rf script to generate random JWT keys without asking for a value.
- Fixed configure-rf script to allow = in variable.
- Fixed configure-rf script to display variables that are not assigned. 
- Updated some formatting on the update_containers script.
- Added MIXPANEL_KEY to compose.yaml and .env.
- Added MONGO_URI, OTEL_URI, OTEL_OPTS to .env.
- Added S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY to .env and compose.yaml.
- Updated NGINX default.conf viewer port from 8082 to 8080 due to change in 15ab9d4.
- Updated compose.yaml viewer section to change port to 8080 and added MONGO_URI and OTEL_URI build args.
- Updated health_check script viewer endpoint to https://$DOMAIN/remote-falcon-viewer/q/health

## 2025.1.4.1

- Everything with regards to the compose.yaml files and configuration script has been updated. The two compose.yaml scripts for published and non-published ports have been removed to just the single compose.yaml with plugins-api port 8083 published. This is exactly how I have run RF for the 2024 season without any issues. 
- Updated the configure-rf script to run outside of the 'remotefalcon' directory. It will also auto create the 'remotefalcon' directory if it is not found in the current directory.
- Added two update scripts. These scripts will display a list of changes in newer versions compared to your current container version and ask you to update. The scripts will directly modify your compose.yaml to update the image tag to the new version versus tagging the containers to 'latest'
- The update_containers.sh script can be run directly with:

!!! example "Update containers syntax"

    ```sh
      ./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]
    ```

!!! example "Update specific container"

    ```sh
      ./update_containers.sh cloudflared auto-apply health
    ```

  Running update script for container 'cloudflared'
  Checking if container 'cloudflared' is running...
  Container 'cloudflared' is running.
  Checking container 'cloudflared' current version...
  Container 'cloudflared' current version: 2024.12.2
  Latest version: 2024.12.2
  Container 'cloudflared' is at the latest version: 2024.12.2
  ```
- Added health check script that gets called from the configure-rf.sh script and the update scripts.
- The health_check.sh script can be run directly with:

```./health_check.sh```
- The health check will check/display the following:
  - sudo docker ps -a
  - Remote Falcon endpoints
  - SSL certificate and private key match validation
  - Nginx configuration
  - Any shows configured on Remote Falcon in the format of the show URL.
