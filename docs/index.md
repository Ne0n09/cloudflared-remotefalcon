# cloudflared-remotefalcon

Self hosted Remote Falcon with easy setup and configuration using Cloudflare Tunnels with a configuration script.

[Remote Falcon](https://remotefalcon.com/) is an awesome project and I thought I would help give back by creating a simplified way to run Remote Falcon for those who would like to self host it beyond just these [ways](https://docs.remotefalcon.com/docs/developer-docs/running-it/methods)

This guide assumes you already have a domain name and that you are running a fresh installation of 64-bit Debian or Ubuntu.

The MongoDB container requires a 64-bit OS.

The configuration script will check if you have Docker installed(For Debian and Ubuntu) and install it for you if not. 

It will also guide you step by step to creating and saving the origin server certificates. 

Everything will run as a 'compartmentalized' stack that is only accessible via the Cloudflare tunnel pointing to an NGINX container that handles the proxying to the Remote Falcon containers. This avoids port conflicts on your host system if you choose not to run it on a dedicated device or VM. Except the plugins-api container which has port 8083 published to allow for local LAN access from the RF plugin.

The main benefit of this method is there is no need to directly expose port 443 when going through the Cloudflare tunnel.

Cloudflare also provides a lot of other features for free.

The .env file handles the configuration variables and the configure-rf.sh script walks you through setting these variables and applying them.

We will start with the Cloudflare configuration below.