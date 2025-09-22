Below you will find a summary of each file that is in the `remotefalcon` directory.

The [configure-rf](scripts.md#configure-rfsh) script will download these automatically if they do not exist.

## compose.yaml

The [compose.yaml](https://github.com/Ne0n09/cloudflared-remotefalcon/blob/main/remotefalcon/compose.yaml) defines all the containers and makes heavy use of the .env file.

There is typically no need to manually edit this file. 

Most of the ports in the compose are not 'published' to help isolate the containers from the local network.

The exceptions are plugins-api(8083:8083) and MinIO(9000:9000,9001:9001) which allows for direct LAN access to these containers. 

=== "plugins-api"

    ```yaml title="compose.yaml" linenums="50" hl_lines="10"
    plugins-api:
        build:
        context: https://github.com/Remote-Falcon/remote-falcon-plugins-api.git
        args:
            - OTEL_OPTS=${OTEL_OPTS}
        image: plugins-api:latest
        container_name: plugins-api
        restart: always
        ports:
        - "8083:8083"
    ```
=== "minio"

    ```yaml title="compose.yaml" linenums="35" hl_lines="6-7"
    minio:
        image: minio/minio:latest
        container_name: remote-falcon-images.minio
        restart: always
        ports:
        - '9000:9000'
        - '9001:9001'
    ```

## .env

The [.env](https://github.com/Ne0n09/cloudflared-remotefalcon/blob/main/remotefalcon/.env) file specifies all the variables that are used in the compose.yaml.

Some of these are updated by the [configure-rf](scripts.md#configure-rfsh) script.

The .env file can be edited manually with `nano remotefalcon/.env`.

???+ info ".env variables"

    `REPO`

    :   The configure-rf script guides on setting this. This lets you run a [GitHub Actions workflow](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows) to build Remote Falcon images and store them on the GitHub Container Registry. Also required the GITHUB_PAT to be configured.

    `TUNNEL_TOKEN`

    :   The configure-rf script guides on setting this. Change to the Cloudfare tunnel token from the overview page of the tunnel.

    `DOMAIN`

    :   The configure-rf script guides on setting this. Change "your_domain.com" to your real domain.

    `VIEWER_JWT_KEY`

    :   The configure-rf script will generate a random value for both of these when it is run.

    `USER_JWT_KEY`

    :   The configure-rf script will generate a random value for both of these when it is run.

    `HOSTNAME_PARTS`

    :   Change this to the number of parts in your hostname. For example, domain.com would be two parts ('domain' and 'com'), and sub.domain.com would be 3 parts ('sub', 'domain', and 'com'). For cloudflare 3 parts will not work unless you purchase [Advanced Certificate Manager](https://www.cloudflare.com/application-services/products/advanced-certificate-manager/).

    `AUTO_VALIDATE_EMAIL`

    :   The configure-rf script guides on setting this. Without a [SendGrid](https://sendgrid.com/) key emails will not be sent so this option allows you to auto validate sign ups without sending an email.

    `NGINX_CONF`

    :   Specifies the path to the NGINX default.conf file. There is no need to modify this.

    `NGINX_CERT`

    :   The configure-rf script guides on setting this. Specifies the path to the [SSL certifcate](../install/cloudflare/#__tabbed_1_4) used by NGINX.

    `NGINX_KEY`

    :   The configure-rf script guides on setting this. Specifies the path to the [SSL private key](../install/cloudflare/#__tabbed_1_4) used by NGINX.

    `HOST_ENV`

    :   There is no need to change this from 'prod'.

    `VERSION`

    :   The update_rf_containers script updates this when it is run and one of the RF containers gets updated. This changes the version displayed in the lower left of the Control Panel in the YYYY.MM.DD format.

    `GOOGLE_MAPS_KEY`

    :   This is used for the Remote Falcon Shows Maps on the Control Panel.

    `PUBLIC_POSTHOG_KEY`

    :   This is used for analytics. You can create a free account at Create this at [PostHog](https://posthog.com/)

    `PUBLIC_POSTHOG_HOST`

    :   This specifies the PostHog host to use from your Posthog [settings](https://us.posthog.com/settings/project) page.

    `GA_TRACKING_ID`

    :   [Google Analytics](https://analytics.google.com/) Measurement ID/gtag.

    `MIXPANEL_KEY`

    :   [Mixpanel](https://mixpanel.com) analytics key. 

    `CLIENT_HEADER`

    :   [CF-Connecting-IP](https://developers.cloudflare.com/fundamentals/reference/http-headers/) is used for Cloudflare to get the actual client IP address for viewer statistics. For Non-Cloudflare you may need to change to X-Forwarded-For or X-Real-IP

    `SENDGRID_KEY`

    :   For sending validation email if you have a [SendGrid](https://sendgrid.com/) account.

    `GITHUB_PAT`

    :   [GitHub Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens). This is required if you would like to build Remote Falcon images via a [GitHub Actions workflow](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows).

    `SOCIAL_META`

    :   The configure-rf script gives the option of setting this. Check the [Remote Falcon Developer Docs](https://docs.remotefalcon.com/docs/developer-docs/running-it/digitalocean-droplet?#update-docker-composeyaml) for more details.

    `SEQUENCE_LIMIT`

    :   This is the sequence limit for the number of sequences that a show can sync with Remote Falcon. The default is 200.

    `MONGO_PATH`

    :   This specifies the path where the MongoDB container data is stored on your server. The default is: `#!sh /home/mongo-volume`. The configure-rf script does NOT modify this.

    `MONGO_INITDB_ROOT_USERNAME`

    :   Specifies the root username for MongoDB. The configure-rf script currently does NOT modify this.

    `MONGO_INITDB_ROOT_PASSWORD`

    :   Specifies the root password for MongoDB. The configure-rf script currently does NOT modify this.

    `MONGO_URI`

    :   Combines the MongoDB root username and password together into the URI path. There is no need to modify this.

    `MINIO_PATH`

    :   This specifies the path where the MinIO container data is stored on your server. The default is: `#!sh /home/minio-volume`. The configure-rf script does NOT modify this.

    `MINIO_ROOT_USER`

    :   Specifies the root user for MinIO. The [minio_init](scripts.md#minio_initsh) script will automatically update the default value to a random value.

    `MINIO_ROOT_PASSWORD`

    :   Specifies the root password for MinIO. The [minio_init](scripts.md#minio_initsh) script will automatically update the default value to a random value.

    `S3_ENDPOINT`

    :   Specifies the S3 endpoint URL for the [control-panel](containers.md#control-panel){ data-preview } container to use for Image Hosting.

    `S3_ACCESS_KEY`

    :   Specifies the S3 access key for MinIO 'remote-falcon-images' bucket. The [minio_-_init](scripts.md#minio_initsh) script will automatically update the default value to a random value.

    `S3_SECRET_KEY`

    :   Specifies the S3 seceret key for MinIO 'remote-falcon-images' bucket. The [minio_init](scripts.md#minio_initsh) script will automatically update the default value to a random value.

    `OTEL_URI`

    :   This is used for OpenTelemry.

    `OTEL_OPTS`

    :   This is used for OpenTelemry.

    `SWAP_CP`

    :   The configure-rf script guides on setting this. When set to 'true' and `VIEWER_PAGE_SUBDOMAIN` is set to a valid subdomain then the Viewer Page Subdomain will be accessible at https://yourdomain.com and the Control Panel will be accessible at https://controlpanel.yourdomain.com.

    `VIEWER_PAGE_SUBDOMAIN`

    :   The configure-rf script guides on setting this. This is used with `SWAP_CP` to swap the Control Panel with the subdomain that is defined here.

## default.conf

The [default.conf](https://github.com/Ne0n09/cloudflared-remotefalcon/blob/main/remotefalcon/default.conf) is used for [NGINX](containers.md#nginx) and defines its configuration.