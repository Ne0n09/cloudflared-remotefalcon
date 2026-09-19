# Install Remote Falcon

The installer downloads the latest public GitHub Release, verifies its SHA-256 checksum, installs the complete script set, and starts configuration. A GitHub account is not required.

```sh
curl -fsSLO https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh
chmod +x install.sh
./install.sh
```

The original single-file command remains supported. A standalone `configure-rf.sh` now invokes the same release installer when its companion files are missing:

```sh
curl -O https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/configure-rf.sh
chmod +x configure-rf.sh
./configure-rf.sh
```

## Docker access

On a dedicated VM, the configurator defaults to adding the current user to the `docker` group when Docker is installed but inaccessible. The script stops afterward so the user can log out and back in. Docker documents that membership in this group grants root-level privileges.

Use `./configure-rf.sh --docker-mode manual` to manage socket access yourself. Rootless Docker is supported only when it has already been configured and `docker info` works for the current user:

```sh
./configure-rf.sh --docker-mode rootless
```

The configurator does not automatically convert an existing rootful installation because rootless Docker has separate storage, networking, systemd, and migration considerations. Follow the official rootless Docker instructions first.

## Noninteractive configuration

Keep tokens in the private `remotefalcon/.env` file or enter them at hidden interactive prompts. Avoid putting credentials in command-line arguments. After preparing `.env`, run:

```sh
./configure-rf.sh -y --set DOMAIN=example.com
```

Run `./health_check.sh 0s` after setup. It exits with a failure code if a required service or endpoint check fails.
