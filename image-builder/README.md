# Remote Falcon legacy private image builder

Normal AMD64 installations now pull four public backend images and build only the UI locally. This directory is retained for existing or advanced deployments that explicitly want all application images in a private GitHub Container Registry.

Copy `.github/workflows/build.yml` into your private image-builder repository. From the cloudflared-remotefalcon deployment, run `./sync_repo_secrets.sh` to populate its build inputs, then run `./run_workflow.sh` or start the workflow from GitHub Actions. The workflow builds plugins-api, control-panel, viewer, ui, and external-api. Its daily schedule checks for new platform commits.

Images use the current platform commit as their short-SHA tag. This also
rebuilds images when shared code in `libs/` changes, and matches the tag used
by `update_containers.sh`.
Set `RF_IMAGE_TAG_MODE=platform` in the deployment `.env` when this workflow
is installed. Existing builders without this workflow should leave the setting
unset to keep their per-service tags.

For local builds, use `DOCKERFILE=Dockerfile.dev`; these JVM builds need less memory. The GitHub workflow continues to use the upstream production Dockerfiles. Keep the `PROTOMAPS_API_KEY`, optional map styles, and host routing values in your deployment `.env` so the UI image receives them at build time.

`run_workflow.sh` updates `.github/workflows/build.yml` in an existing builder repository and synchronizes current build secrets before dispatching a build. This also upgrades repositories originally created with the legacy `build-all.yml` and `build-container.yml` workflows.
