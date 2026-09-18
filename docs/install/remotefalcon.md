# Install Remote Falcon

Use this complete, maintained checkout. The archived Ne0n09 repository contains older scripts, so a single downloaded `configure-rf.sh` is insufficient.

1. Copy the checkout to your Debian host. Keep `configure-rf.sh`, the helper scripts, and the `remotefalcon/` templates together.
2. Run `chmod +x ./*.sh` and then `./configure-rf.sh` from the checkout root.
3. Enter the Cloudflare Tunnel token and origin certificate details when prompted. If you build images in GitHub, also enter a GitHub personal access token.
4. Run `./health_check.sh 0s` after setup. It exits with a failure code when a required check fails.

The configurator creates `remotefalcon/.env` from the local example when needed. Keep this file private. For scripted setup, fill in `.env` before running `./configure-rf.sh -y`; avoid passing tokens as command line arguments.

You can rerun `./configure-rf.sh` to adjust settings or use `./update_containers.sh` for image updates. See [GitHub image builds](github.md) and [troubleshooting](../troubleshooting.md) for the next steps.
