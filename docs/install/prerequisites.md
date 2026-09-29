You will need your own domain name and server capable of running Docker and MongoDB.

## Domain Name

- I recommended [porkbun](https://porkbun.com/) if you do not already have a domain name.

## Server Hardware

- 2 CPUs/cores, minimum.

- 4 GB RAM minimum for the default AMD64 or ARM64 deployment. The four backend images are pulled from the public registry and only the UI is built locally.

    !!! warning
        Public backend images target 64-bit AMD64 and ARM64. Other architectures fall back to local JVM builds and may require substantially more memory.

- 80 GB disk storage, although you may be able to get away with less.

## Server OS

- 64-bit AMD64 or ARM64 [Debian](https://www.debian.org/distrib/) for the default public-image path.

- 64-bit AMD64 or ARM64 [Ubuntu](https://ubuntu.com/download/server) for the default public-image path.

- Other 64-bit operating systems that can run Docker will require Docker to be manually installed if it is not already.

- MongoDB requires a [64-bit OS](https://www.mongodb.com/docs/manual/installation/#supported-platforms). MongoDB 5.0+ requires [AVX instructions on x86-64](https://www.mongodb.com/docs/manual/administration/production-notes/#x86-64) and ARMv8.2-A or later on ARM64.

    !!! note
        On an x86-64 VM, ensure the VM CPU type exposes AVX. If AVX is unavailable, the scripts pin MongoDB to `4.4.29` and do not offer newer MongoDB releases.

## Root or sudo access

### Debian

To install and add a user to the sudo group follow the steps below.

1. Switch to the root user `su -`

2. Install sudo `apt install sudo`

3. Add user to sudo group `usermod -aG sudo {username-here}`

If you meet the prerequisites you can move on to the [Cloudflare](cloudflare.md) setup!
