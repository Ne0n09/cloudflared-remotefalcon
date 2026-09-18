If you configured GitHub during `configure-rf.sh`, your private repository was created from the Remote Falcon image builder template.

## build.yml

The unified workflow builds all five Remote Falcon app images or a selected service from the platform repository. The platform commit SHA is used as the image tag. It can be run manually in GitHub Actions or through `run_workflow.sh`.

`run_workflow.sh` syncs build secrets, starts the workflow, and deploys only the built app services after the workflow succeeds. It checks the deployment and restores the prior images and Compose file on failure.

## Secrets

The workflow reads secrets from your private repository. Use `sync_repo_secrets.sh` to update them from the VM's private `.env` file, or edit them under repository Settings → Secrets and variables → Actions.
