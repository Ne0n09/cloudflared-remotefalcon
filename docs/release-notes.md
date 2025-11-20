# Release Notes

## 2025.11.20.1

- Updated run_workflow.sh and configure-rf.sh to fix images not being pulled from GHCR if rebuilding at current version.

- run_workflow.sh will now just do 'sudo docker compose -f "$COMPOSE_FILE" pull' and 'sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate' to ensure any ARG changes are applied.

## 2025.11.9.1

- Updated configure-rf.sh to ask for Cloudflare API token for automatic Cloudflare installation

- Removed CLARITY_PROJECT_ID arg from compose.yaml and configure-rf.sh.

- Updated setup_cloudflare.sh to support passing the Cloudflare API token via arg either interactively or non-interactively.

- This allows for even simpler automatic installation: 
  
    ```sh
    ./configure-rf.sh -y --no-updates \
    --set DOMAIN=<yourdomain.com> \
    --set CF_API_TOKEN=<your_Cloudflare_API_token> \
    --set GITHUB_PAT=<GitHub_PAT_for_image_builder>
    ```

- Updated setup_cloudflare.sh to fix a typo in the cloudflared container check.

- Updated shared_function.sh to properly tag coollabs/minio images when replace_compose_tag is called. 

- Other misc configure-rf.sh fixes.

## 2025.11.8.1

- Many updates to configure-rf.sh to support running it non-interactively to automate deployment: 

    ```sh
    ./configure-rf.sh [-y|--non-interactive] [--update-all|--update-scripts|--update-files|--update-workflows|--no-updates] [--set KEY=VALUE ...]
    ```

- Updated setup_cloudflare.sh to add flags to run the script automatically: 

    ```sh
    ./setup_cloudflare.sh [-y|--non-interactive] [--domain <domain.com>] [--api-token <api-token>]
    ```

- Example of combining both to spin up a basic installation automatically that uses GitHub for image building: 

    ```sh
    ./setup_cloudflare.sh -y --domain <yourdomain.com> --api-token <your_Cloudflare_API_token> && ./configure-rf.sh -y --no-updates --set GITHUB_PAT=<GitHub_PAT_for_image_builder>
    ```

- Updated compose.yaml to use coollabsio/minio image since MinIO is no longer providing builds and added health check.

- Updated compose.yaml to change the environmental variables for control-panel and external-api.

- Updated update_containers.sh to use coollabsio/minio for MinIO updates.

- Updated share_functions.sh to remove yellow coloring from the existing .env variable display.

- Udpated minio_init.sh to check if the container is ready via host curl instead of docker exec curl.

- Other misc changes.

## 2025.10.24.1

- Updated configure-rf to force image build for all images if GH REPO set and all images are still tagged to latest in compoes.yaml.

- Updated run_workflow to only pull images for individual containers instead of all containers.

- Updated setup_cloudflare to auto download .env in order to populate the DOMAIN and TUNNEL_TOKEN for initial installs where configure-rf has not yet been run

- Updated update_containers to pin MinIO to release RELEASE.2025-09-07T16-13-09Z as the latest release since MinIO no longer producing images:
https://github.com/minio/minio/issues/21647#issuecomment-3418675115

## 2025.10.22.1

- Easier updates! When running configure-rf.sh it will display current local versions of [scripts](about/scripts.md), [files](about/files.md), and workflow versions and compare them to the latest available versions on GitHub.

- Updated configure-rf.sh to prompt for [compose.yaml, .env, and default.conf updates](updates.md#updating-composeyaml-env-and-defaultconf) to assist with downloading new config file updates.

- Updated configure-rf.sh to prompt for [Remote Falcon Image Builder workflow updates](updates.md#updating-remote-falcon-image-builder-workflows).

- Removed ghcr.io/${REPO}/ from the default compose.yaml. This will automatically get updated by update_compose_image_path in shared_function.sh when update_container.sh or configure-rf.sh is run.

## 2025.10.19.1

- Added [setup_cloudflare.sh](install/cloudflare.md#automatic-configuration) to assist with automatic Cloudflare domain, certificate, SSL/TLS, tunnel, and DNS settings for initial or existing installations.

- Updated health_check.sh to include check for plugins-api and viewer not connecting to mongo.

- Updated health_check.sh to include 000 error code if DNS records are missing.

- Updated health_check.sh NGINX health check so if on-disk cert/key is changed NGINX will be restarted if it is running.

- Updated configure-rf.sh to display a prompt for [script updates](updates.md#script-updates) to assist in downloading new script updates.

## 2025.10.14.1

- Moved MONGO_URI back as a build arg for plugins-api and viewer.

## 2025.10.13.1

- Added configuration question for Microsoft Clarity to configure-rf.sh.

- Updated .env to add CLARITY_PROJECT_ID.

- Updated compose.yaml to add CLARITY_PROJECT_ID.

- Updated sync_repo_secrets.sh to add CLARITY_PROJECT_ID.

- Added CLARITY_PROJECT_ID to build-all.yml and build-container.yml in the remote-falcon-image-builder template repo.

- Removed MONGO_URI as build arg for plugins-api and viewer and set it as env var.

## 2025.09.8.1

- **GitHub Actions integration!** This will allow you to easily configure a GitHub repo to build images via GitHub Actions workflows. 

- The configure-rf and update_containers scripts have been completely overhauled to add this along with other improvements.

- Removed the update_rf_containers script as it is all integrated into the update_containers script.

- Added sync_repo_secrets and run_workflow scripts to facilitate building images on GitHub.

- Created a [template repository](https://github.com/Ne0n09/remote-falcon-image-builder) with the workflows that the configure-rf script will use to create a new private repo to run the GitHub Actions workflows.

- If a REPO is configured in the .env the configure-rf, update_containers, or run_workflow scripts will automatically add ```ghcr.io/${REPO}``` to the image path in compose.yaml.

- If a REPO is not configured it will also automatically remove it from the image path.

- Updated FPP 9 plugin configuration [steps](post-install.md#fpp-9-and-above-update-the-fpp-plugin-settings).

- Additional health checks in the health_check script.

- Various other changes

## 2025.06.16.1

- Updated configure-rf .env file version would not display if .env didn't already exist.

- Added FPP 9 configuration steps [here](post-install.md#fpp-9-and-above-update-the-fpp-plugin-settings).

- Updated update_rf_containers again to fix the current_ctx not being found properly.

## 2025.06.9.1

- Updated health_check errors and formatting. Added retry for RF container checks.

- Updated shared_functions to add MongoDB version during backup.

- Fixed update_rf_containers not displaying current image tag.

## 2025.06.6.1

- Updated health_check errors and formatting for RF container checks.

- Updated configure-rf list_file_versions placement in script.

- Updated update_containers formatting.

- Updated make_admin to allow selecting by number and updated formatting and coloring.

- Updated generate_jwt to allow selecting by number and updated formatting and coloring.

- Added revert script to assist with reverting back to previous compose.yaml, .env, or MongoDB backups. 

## 2025.06.2.1

- Fixed some coloring on output in health_check.sh and configure-rf.

- Moved mongo_backup function to shared_functions.sh.

- configure-rf.sh now displays existing script versions to help keep track of updates.

## 2025.05.31.1

- configure-rf - Moved shared_functions.sh to source it earlier to ensure coloring takes effect.

- configure-rf - Moved service running check to only run if env update is accepted

- minio_init - Fixed parse_env_file "$ENV_FILE" to parse_env "$ENV_FILE" as this was causing duplicate variables.

- update_containers - Update image tag if container version is on latest and the compose version is not in a valid version tag format(such as 'latest'). This will allow for rolling back to backed up compose file.

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

- Updated compose.yaml viewer section to add MONGO_URI and OTEL_URI build args.

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

    ```
      ./update_containers.sh cloudflared auto-apply health
      ⚙️ Checking for non-RF container updates...
      ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      🔄 Container: cloudflared
      🔸 Current version: 2025.5.0
      🔹 Latest version: 2025.5.0
      ✅ cloudflared is up-to-date.
      🚀 Done. Non-RF container update process complete.
    ```

- Added health check script that gets called from the configure-rf.sh script and the update scripts.

- The health_check.sh script can be run directly with:

    `#!sh ./health_check.sh`

- The health check will check/display the following:

  - sudo docker ps -a

  - Remote Falcon endpoints

  - SSL certificate and private key match validation

  - Nginx configuration

  - Any shows configured on Remote Falcon in the format of the show URL.