# Documentation versions

The documentation is published with each tagged cloudflared-remotefalcon release. Use the version selector in the page header to match the documentation to the version installed on your server.

The `latest` alias always points to the newest tagged release. Publishing a new release adds a new immutable documentation version without replacing older versions.

## Legacy private-builder documentation

The last documentation release that describes the retired GitHub account and private image-builder setup is designated as `2026.9.27.6` with the `legacy-private-builder` alias. Run the historical-docs workflow before the first versioned release to publish that snapshot for older installations.

New AMD64 and ARM64 installations should use the current documentation. They pull the four public backend images anonymously and build only the deployment-specific UI locally.

## Maintainer deployment

Tagged releases publish their documentation automatically. Before publishing the first versioned release, run the **Deploy historical documentation** workflow once with its defaults to archive the last private-builder-era documentation.
