Below is a summary of each container and/or links to also learn more about them.

## mongo

[MongoDB](https://hub.docker.com/_/mongo) provides the database that stores show information.

- [Remote Falcon Developer Docs - MongoDB](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture#mongodb)

## external-api

The [External API](https://github.com/Remote-Falcon/remote-falcon-external-api) allows you to create your own viewer page outside of the Remote Falcon viewer pages. See the [API documentation](https://app.swaggerhub.com/apis/whitesoup12/RemoteFalcon/20241115.1), [examples](https://github.com/Remote-Falcon/remote-falcon-issue-tracker/tree/main/external-api-sample), and [here](../extra/index.md).

- [GitHub - external-api](https://github.com/Remote-Falcon/remote-falcon-external-api)

## ui

- [Remote Falcon Developer Docs - ui](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture#remote-falcon-ui)

- [GitHub - ui](https://github.com/Remote-Falcon/remote-falcon-ui)

## plugins-api

- [Remote Falcon Developer Docs - plugins-api](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture#remote-falcon-plugins-api)

- [GitHub - plugins-api](https://github.com/Remote-Falcon/remote-falcon-plugins-api)

## viewer

- [Remote Falcon Developer Docs - viewer](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture#remote-falcon-viewer)

- [GitHub - viewer](https://github.com/Remote-Falcon/remote-falcon-viewer)

## control-panel

- [Remote Falcon Developer Docs - control-panel](https://docs.remotefalcon.com/docs/developer-docs/how-it-works/architecture#remote-falcon-control-panel)

- [GitHub - control-panel](https://github.com/Remote-Falcon/remote-falcon-control-panel)

## minio

[MinIO](https://hub.docker.com/r/minio/minio) provides object storage that can be used to store viewer page images.

## nginx

[NGINX](https://hub.docker.com/_/nginx) is the reverse porxy server that provides access to the Remote Falcon containers.

## cloudflared

[Cloudflared](https://hub.docker.com/r/cloudflare/cloudflared) is a client for Cloudflare Tunnel which allows us to route all web traffic through Cloudflare to NGINX. 

