# common-github-workflows

Common GitHub workflows used by sdr-enthusiasts' CI/CD workflows.

## Build & Push Docker Images

This action will perform a build & push of docker images.

### Example

```yaml
---
name: ci

on:
  workflow_dispatch:

jobs:

  build_and_push:
    uses: sdr-enthusiasts/common-github-workflows/.github/workflows/build_and_push_image.yml@main
    with:
      push_enabled: true
      ghcr_repo_owner: ${{ github.repository_owner }}
      ghcr_repo: ${{ github.repository }}
      platform_linux_arm32v6_enabled: true
      platform_linux_i386_enabled: true
    secrets:
      ghcr_token: ${{ secrets.GITHUB_TOKEN }}
```

### Inputs

| Input | Description | Required | Default |
| ----- | ----------- | -------- | ------- |
| `docker_build_context` | Path to docker build context | `false` | `.` |
| `docker_build_file` | Path to the dockerfile within `docker_build_context` | `false` | `./Dockerfile` |
| `push_enabled` | Set to `true` to push the image | `false` | `false` |
| `push_destinations` | Expects `;` separated list containing one or more of `ghcr.io`, `dockerhub` | `false` | `ghcr.io` |
| `dockerhub_profile` | The dockerhub username/profile/organisation the image should be pushed to | `false` | |
| `dockerhub_username` | The dockerhub username (if different to `dockerhub_profile`). If not given, reverts to `dockerhub_profile` | |
| `dockerhub_repo` | The dockerhub repository the image should be pushed to | `false` | |
| `ghcr_repo_owner` | The github username/profile/organisation the repo to be pushed to belongs to | `false` | |
| `ghcr_repo` | The ghcr.io repository the image should be pushed to | `false` | |
| `platform_linux_arm32v6_enabled` | Set to true to build for the `linux/arm/v6` platform | `false` | `false` |
| `platform_linux_arm32v7_enabled` | Set to true to build for the `linux/arm/v7` platform | `false` | `true` |
| `platform_linux_arm64v8_enabled` | Set to true to build for the `linux/arm64` platform | `false` | `true` |
| `platform_linux_amd64_enabled` | Set to true to build for the `linux/amd64` platform | `false` | `true` |
| `platform_linux_i386_enabled` | Set to true to build for the `linux/i386` platform | `false` | `false` |
| `build_enabled` | Set to `true` to build images | `false` | `true` |
| `build_platform_specific` | Set to `true` to also build platform specific images | `false` | `true` |
| `build_latest` | Set to `true` to include a latest tag | `false` | `true` |
| `build_version_specific` | Set to `true` to include a version tag | `false` | `true` |
| `build_nohealthcheck` | Set to true to build a nohealthcheck version | `false` | `true` |

### Secrets

| Input | Description |
| ----- | ----------- |
| `dockerhub_token` | If pushing to dockerhub, this should be a token for `dockerhub_profile` |
| `ghcr_token` | If pushing to ghcr.io, this should be a github token |
