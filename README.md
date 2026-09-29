# cloudflared-remotefalcon

> This repository tracks the current Remote Falcon platform monorepo. Public, checksummed releases support installation and script updates without a GitHub account.

## Install

```sh
curl -fsSLO https://raw.githubusercontent.com/Ne0n09/cloudflared-remotefalcon/main/install.sh
chmod +x install.sh
./install.sh
```

The prior standalone `configure-rf.sh` installation command remains compatible and bootstraps the same verified release.

[cloudflared-remotefalcon](https://github.com/Ne0n09/cloudflared-remotefalcon/tree/main) helps you self host [Remote Falcon](https://remotefalcon.com/) through guided setup and configuration using [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) and your own server capable of running [Docker](https://www.docker.com/) through the use of various helper [scripts](https://ne0n09.github.io/cloudflared-remotefalcon/about/scripts/).

For full details, check the [cloudflared-remotefalcon documentation](https://ne0n09.github.io/cloudflared-remotefalcon/).

To learn more about Remote Falcon, see the [Remote Falcon documentation](https://docs.remotefalcon.com/).

Installation is a two-step process. There is no separate GitHub account, repository, or image-builder setup step:

1. [Configure Cloudflare](https://ne0n09.github.io/cloudflared-remotefalcon/install/cloudflare/).
2. [Install Remote Falcon](https://ne0n09.github.io/cloudflared-remotefalcon/install/remotefalcon/).

AMD64 and ARM64 installations pull the four public backend images anonymously and build the deployment-specific UI locally. End users do not need a GitHub account or private image-builder repository.

You may refer to the [release notes](https://ne0n09.github.io/cloudflared-remotefalcon/release-notes/) for updates to the scripts and files.
