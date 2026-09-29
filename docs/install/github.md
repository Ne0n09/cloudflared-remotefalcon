# Deprecated GitHub image-builder setup

!!! warning "Deprecated compatibility documentation"

    New installations must not create a private image-builder repository or Personal Access Token. This page remains only as a pointer for installations that already use the legacy workflow.

AMD64 installations pull `plugins-api`, `control-panel`, `viewer`, and `external-api` anonymously from this project's public GitHub Container Registry packages. The deployment-specific `ui` image is built locally. No GitHub account is required.

Existing installations with both `REPO` and `GITHUB_PAT` configured can continue using the deprecated private image-builder compatibility path until they migrate. Refer to the matching historical documentation version in the version selector for its original setup instructions.

To use the current public-image path, leave `REPO=username/repo` and `GITHUB_PAT` empty, then follow the current [Remote Falcon installation](remotefalcon.md) documentation.
