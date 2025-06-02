**WORK IN PROGRESS**

## Script Updates

Currently there is no auto-update for the configure-rf or helper scripts so you may want to check for updates periodically.

1. The `configure-rf` script will print the existing versions on your system when it runs:
```sh
📜 Existing script versions:
🔸 configure-rf.sh           2025.6.2.1
🔸 health_check.sh           2025.5.26.1
🔸 minio_init.sh             2025.5.31.1
🔸 update_containers.sh      2025.5.31.1
🔸 update_rf_containers.sh   2025.5.27.1
```

You can check the [release notes](../release-notes.md) to see if there any updates or view the `.sh` files directly on [GitHub](https://github.com/Ne0n09/cloudflared-remotefalcon) looking for any `# VERSION` comments towards the top of each script.

2. Remove the scripts:
```sh
rm configure-rf.sh health_check.sh minio_init.sh update_containers.sh update_rf_containers.sh
```

3. The command below will re-download the configure-rf script and run it which will then re-download the helper scripts:
```sh
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh; \
chmod +x configure-rf.sh; \
./configure-rf.sh
```

    !!! note

        To check for updates to compose.yaml, .env, and default.conf check the instructions [here](../main/updating.md#updating-composeyaml-env-and-defaultconf)

## Scripts Details

Click through the tabs below to view detailed information for each script.

=== "Configure RF"

    - This script is used for the initial setup and configuration of [cloudflared-remotefalcon](https://github.com/Ne0n09/cloudflared-remotefalcon/tree/main).

    - It guides you on setting the required and some optional [.env](../architecture/files.md#env) variables.

    - It can be re-run to view or update the variables or to run the container update or health check scripts.

    - Automatically downloads other helper scripts if they are missing.

    - Automatically creates the `remotefalcon` and `remotefalcon-backups` directories.

    - Automatically downloads the [compose.yaml](../architecture/files.md#composeyaml), [.env](../architecture/files.md#.env), and [default.conf](../architecture/files.md#defaultconf) files if they are missing.

    ```sh title="Run the configure-rf script"
    ./configure-rf.sh
    ```

    ```sh title="Example output on first run"
    ⚙️ Running RF configuration script...
    Working in directory: /home/user/remotefalcon
    Found existing .env at /home/user/remotefalcon/.env.
    🔍 Parsing current .env variables:
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔹 TUNNEL_TOKEN=cloudflare_token
    🔹 DOMAIN=your_domain.com
    🔹 VIEWER_JWT_KEY=123456
    🔹 USER_JWT_KEY=123456
    🔹 HOSTNAME_PARTS=2
    🔹 AUTO_VALIDATE_EMAIL=true
    🔹 NGINX_CONF=./default.conf
    🔹 NGINX_CERT=./origin_cert.pem
    🔹 NGINX_KEY=./origin_key.pem
    🔹 HOST_ENV=prod
    🔹 VERSION=1.0.0
    🔹 GOOGLE_MAPS_KEY=
    🔹 PUBLIC_POSTHOG_KEY=
    🔹 PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
    🔹 GA_TRACKING_ID=1
    🔹 MIXPANEL_KEY=
    🔹 CLIENT_HEADER=CF-Connecting-IP
    🔹 SENDGRID_KEY=
    🔹 GITHUB_PAT=
    🔹 SOCIAL_META=<meta property='og:url' content='https://remotefalcon.com/'/><meta property='og:title' content='Remote Falcon'/><meta property='og:description' content='Create a custom website where viewers can request or vote for sequences to watch on your light show.'/><meta property='og:image' content='https://remotefalcon.com/jukebox.png'/>
    🔹 SEQUENCE_LIMIT=200
    🔹 MONGO_PATH=/home/mongo-volume
    🔹 MONGO_INITDB_ROOT_USERNAME=root
    🔹 MONGO_INITDB_ROOT_PASSWORD=root
    🔹 MONGO_URI=mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/remote-falcon?authSource=admin
    🔹 MINIO_PATH=/home/minio-volume
    🔹 MINIO_ROOT_USER=12345678
    🔹 MINIO_ROOT_PASSWORD=12345678
    🔹 S3_ENDPOINT=http://minio:9000
    🔹 S3_ACCESS_KEY=123456
    🔹 S3_SECRET_KEY=123456
    🔹 OTEL_URI=
    🔹 OTEL_OPTS=
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ❓ Change the .env file variables? (y/n) [n]:
    ```

=== "Update RF Containers"

    - This script will update the Remote Falcon containers to the latest available commit on the [Remote Falcon Github](https://github.com/Remote-Falcon).
    
    - The [compose.yaml](../architecture/files.md#composeyaml) build context hash is updated to the latest commit for the container.

    - The image tag for the container is updated in the compose.yaml to the short-hash:
    ```yaml linenums="50" hl_lines="3 6"
      plugins-api:
        build:
          context: https://github.com/Remote-Falcon/remote-falcon-plugins-api.git#cc1593aab27dc195a4c55b5b1410ddc06e96a60c
          args:
            - OTEL_OPTS=${OTEL_OPTS}
        image: plugins-api:cc1593a
        container_name: plugins-api
    ```

    - A backup of the compose.yaml is created when any of the containers are updated.

    - The script accepts two arguments:

        1. `[dry-run|auto-apply|interactive]`

            - `dry-run`: Displays if any updates are available or if up to date.

            - `auto-apply`: Automatically update all RF containers if any updates are found.

            - `interactive/no argument`: Display if update is available and prompt for confirmation before updating each container.

        2. `[health]`

            - Add `health` after the first argument to automatically run the health_check script.

    ```sh title="update_rf_containers script syntax examples" 
    ./update_rf_containers.sh [dry-run|auto-apply|interactive] [health]
    ./update_rf_containers.sh
    ./update_rf_containers.sh dry-run health
    ./update_rf_containers.sh auto-apply
    ```

    ```sh title="Example output on first run of ./update_rf_containers.sh"
    ⚙️ Checking for Remote Falcon container updates...
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: external-api
    ⚠️ No context hash found for external-api; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: f7e09fe - Latest commit: f7e09fe74b8e064867795cda080da8c8d665ddec
    📜 external-api Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-external-api/commits/main
    ❓ Update external-api to f7e09fe? (y/n): y
    ✔ Backed up /home/user/remotefalcon/compose.yaml to /home/user/remotefalcon-backups/compose.yaml.backup-2025-06-01_11-46-02
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: ui
    ⚠️ No context hash found for ui; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: cb19864 - Latest commit: cb19864c25d42fd49aa4ec41cbe4f0af36497458
    📜 ui Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-ui/commits/main
    ❓ Update ui to cb19864? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: plugins-api
    ⚠️ No context hash found for plugins-api; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: cc1593a - Latest commit: cc1593aab27dc195a4c55b5b1410ddc06e96a60c
    📜 plugins-api Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-plugins-api/commits/main
    ❓ Update plugins-api to cc1593a? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: viewer
    ⚠️ No context hash found for viewer; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: b7cfb2d - Latest commit: b7cfb2d54ad44264df5d04148d1bcea2bb8bcb34
    📜 viewer Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-viewer/commits/main
    ❓ Update viewer to b7cfb2d? (y/n): y
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: control-panel
    ⚠️ No context hash found for control-panel; assuming update is needed.
    - Current commit: (none)
    🔹 Latest tag: e6c110c - Latest commit: e6c110c38fb032f9399e841e3ef704e96b7b8ba9
    📜 control-panel Changelog: (no previous context hash available)
    🔗 GitHub: https://github.com/Remote-Falcon/remote-falcon-control-panel/commits/main
    ❓ Update control-panel to e6c110c? (y/n): y
    🛠️ Building containers with updated tags...
    ```

=== "Update Containers"

    This script updates the non-RF containers

    - This script will update the non-Remote Falcon containers to the latest available release.
    
    - The [compose.yaml](../architecture/files.md#composeyaml) container image tag is updated to the latest release.

    - A backup of the compose.yaml is created when any of the containers are updated.

    - The script accepts three arguments:

        1. `[all|mongo|minio|nginx|cloudflared]`

            - `container_name`: You can specify an individual container or all. If left blank with no other arguments it will check all containers in interactive mode.

        2. `[dry-run|auto-apply|interactive]`: 

            - `dry-run`: Displays if any updates are available or if up to date.

            - `auto-apply`: Automatically update all RF containers if any updates are found.

            - `interactive/no argument`: Display if update is available and prompt for confirmation before updating each container.

        3. `[health]`

            - Add `health` after the first two arguments to automatically run the health_check script.

    ```sh title="update_containers script syntax examples" 
    ./update_containers.sh [all|mongo|minio|nginx|cloudflared] [dry-run|auto-apply|interactive] [health]
    ./update_containers.sh
    ./update_containers.sh all dry-run health
    ./update_containers.sh all auto-apply
    ```

    ```sh title="Example output of ./update_containers.sh"
    ⚙️ Checking for non-RF container updates...
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: mongo
    🔸 Current version: 8.0.9
    🔹 Latest version: 8.0.9
    ✅ mongo is up-to-date.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: minio
    🔸 Current version: RELEASE.2025-05-24T17-08-30Z
    🔹 Latest version: RELEASE.2025-05-24T17-08-30Z
    ✅ minio is up-to-date.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: nginx
    🔸 Current version: 1.27.5
    🔹 Latest version: 1.27.5
    ✅ nginx is up-to-date.
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🔄 Container: cloudflared
    🔸 Current version: 2025.5.0
    🔹 Latest version: 2025.5.0
    ✅ cloudflared is up-to-date.
    🚀 Done. Non-RF container update process complete.
    ```

=== "Health Check"

    This script will perform a 'health check' and display issues that are found.

    ```sh title="update_containers.sh" linenums="1" hl_lines="3"
    # Run a health check directly:
    
    ./health_check.sh
    ```

=== "Generate JWT"

    This is to be able to make use of the External API.

    Assists with getting your API access token and secret key from your Remote Falcon show in the MongoDB database if you don't have email configured(Sendgrid seems impossible to get an account created). 

    Then the script generates a JWT for you to use.

    ```sh title="generate_jwt.sh" linenums="1" hl_lines="3"
    # Retrieves external API access info and generates JWT:
    
    ./generate_jwt.sh
    ```

=== "Make Admin"

    This script will display shows that have admin access and allow you to toggle admin access when the show subdomain is passed as an argument.

    Run the script with no arguments to display currently configured showRole(USER/ADMIN).

    This basically lets you see and edit MongoDB information from within Remote Falcon.

    ```sh title="make_admin.sh" linenums="1" hl_lines="3"
    # ./make_admin.sh [yoursubdomain]:
    
    ./make_admin.sh
    ```

=== "MinIO Init"

    This script will configure MinIO. Minio is a lightweight object storage server.

    The script is called when 'configure-rf.sh' is run and if certain default values are found in the .env file and is pretty much a hands-off configuration.

    The minio container is configured for local direct access to the control-panel container.

    This lets you use the Image Hosting tab in the Control Panel which allows you to self host your viewer page images.

    The script can be run again manually with no ill-effects to ensure MinIO is configured properly.

    ```sh title="minio_init.sh" linenums="1" hl_lines="3"
    # ./minio_init.sh:
    
    ./minio_init.sh
    ```

=== "Shared Functions"

    This is a helper script for functions that are re-used across the other scripts. 