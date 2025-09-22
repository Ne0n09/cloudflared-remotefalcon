[cloudflared-remotefalcon](https://github.com/Ne0n09/cloudflared-remotefalcon/tree/main) helps you self host [Remote Falcon](https://remotefalcon.com/) through guided setup and configuration using [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) and your own server capable of running [Docker](https://www.docker.com/) through the use of various helper [scripts](about/scripts.md).

Ready to get [started](install/index.md)?

Check out the [Remote Falcon Docs](https://docs.remotefalcon.com/) to learn more about Remote Falcon.

![Demo slide show](./images/slide_show_9_8_25.gif)

## Architecture

Adding a bit to the Remote Falcon architecture diagram from [here](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture), we have Cloudflared and MinIO.

All web traffic goes through [Cloudflared](about/containers.md#cloudflared){ data-preview } directly into [NGINX](about/containers.md#nginx){ data-preview }.

Then we also have [MinIO](about/containers.md#minio){ data-preview } to provide object storage. The [control-panel](about/containers.md#control-panel){ data-preview } connects directly to MinIO and MinIO is connected to NGINX to allow for images to be viewable when used on the viewer page.

### cloudflared-remotefalcon flowchart

```mermaid
---
config:
  layout: fixed
---
flowchart LR
  %% RF containers
  control_panel([remote-falcon-control-panel])
  viewer([remote-falcon-viewer])
  plugins_api([remote-falcon-plugins-api])
  external_api([remote-falcon-external-api])
  ui([remote-falcon-ui])

  %% Non-RF containers
  nginx([nginx])
  cloudflared([cloudflared])
  mongo([MongoDB])
  minio([MinIO])
  fpp(["FPP/xSchedule"]) 

  %% Connections based on depends_on and service usage
  control_panel --> mongo
  control_panel --> minio
  viewer --> mongo
  plugins_api --> mongo
  external_api --> mongo
  external_api --> viewer
  ui --> control_panel
  ui --> viewer
  nginx --> control_panel
  nginx --> viewer
  nginx --> plugins_api
  nginx --> external_api
  nginx --> ui
  nginx --> minio
  cloudflared --> nginx
  fpp --> plugins_api

  click control_panel href "about/containers#control-panel" "Control Panel Container"
  click viewer href "about/containers#viewer" "Viewer Container"
  click plugins_api href "about/containers#plugins-api" "Plugins API Container"
  click external_api href "about/containers#external-api" "External API Container"
  click ui href "about/containers#ui" "UI Container"
  click nginx href "about/containers#nginx" "NGINX Container"
  click cloudflared href "about/containers#cloudflared" "Cloudflared Container"
  click minio href "about/containers#minio" "MinIO Container"
  click mongo href "about/containers#mongo" "MongoDB Container"


```