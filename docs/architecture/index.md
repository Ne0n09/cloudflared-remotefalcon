**WORK IN PROGRESS**

Adding a bit to the Remote Falcon architecture diagram from [here](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture), we have Cloudflared and MinIO.

All web traffic goes through [Cloudflared](containers.md#cloudflared){ data-preview } directly into [NGINX](containers.md#nginx){ data-preview }.

Then we also have [MinIO](containers.md#minio){ data-preview } to provide object storage. The [control-panel](containers.md#control-panel){ data-preview } connects directly to MinIO and MinIO is connected to NGINX to allow for images to be viewable on the viewer page.

## cloudflared-remotefalcon flowchart

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

  click control_panel href "containers#control-panel" "Control Panel Container"
  click viewer href "containers#viewer" "Viewer Container"
  click plugins_api href "containers#plugins-api" "Plugins API Container"
  click external_api href "containers#external-api" "External API Container"
  click ui href "containers#ui" "UI Container"
  click nginx href "containers#nginx" "NGINX Container"
  click cloudflared href "containers#cloudflared" "Cloudflared Container"
  click minio href "containers#minio" "MinIO Container"
  click mongo href "containers#mongo" "MongoDB Container"


```