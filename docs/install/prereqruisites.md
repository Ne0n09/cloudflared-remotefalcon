You will need your own domain name and server capable of running Docker and MongoDB.

## Domain Name

- I recommended [porkbun](https://porkbun.com/) if you do not already have a domain name.

## Server Hardware

- 2 CPUs/cores, minimum.

- 4 GB RAM, minimum if you configure [GitHub](../main/install/github.md) to remotely build Remote Falcon images.

    !!! warning
        16 GB or more RAM is required to locally build the Remote Falcon [viewer](http://127.0.0.1:8000/cloudflared-remotefalcon/docs/architecture/containers/#viewer) or [plugins-api](http://127.0.0.1:8000/cloudflared-remotefalcon/docs/architecture/containers/#plugins-api) images.

- 80 GB disk storage, although you may be able to get away with less.

## Server OS

- 64-bit Debian

- 64-bit Ubuntu

- Other 64-bit operating systems that can run Docker will require Docker to be manually installed if it is not already.

- MongoDB requires a [64-bit OS](https://www.mongodb.com/docs/manual/installation/#supported-platforms) and a CPU that supports [AVX instructions](https://www.mongodb.com/community/forums/t/mongodb-5-0-cpu-intel-g4650-compatibility/116610).

    !!! note
        If running in a VM ensure the VM's CPU type supports AVX.

If you meet the prerequisites you can move on to the [Cloudflare](cloudflare.md) setup!
