# sdr-enthusiasts/common-github-workflows

Common GitHub workflows used by sdr-enthusiasts' CI/CD workflows.

* [sdr-enthusiasts/common-github-workflows](#sdr-enthusiastscommon-github-workflows)
  * [Build & Push Docker Images](#build--push-docker-images)
    * [Example](#example)
    * [Inputs](#inputs)
      * [`get_version_method`](#get_version_method)
        * [Method: `cargo_toml_file_in_image`](#method-cargo_toml_file_in_image)
        * [Method: `cargo_toml_file_in_repo`](#method-cargo_toml_file_in_repo)
        * [Method: `file_in_container`](#method-file_in_container)
        * [Method: `git_commit_hash_short`](#method-git_commit_hash_short)
    * [Secrets](#secrets)

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
| `get_version_method` | See below | `false` | `file_in_container:file=/IMAGE_VERSION` |
| `build_nohealthcheck` | Set to true to build a nohealthcheck version | `false` | `true` |
| `build_with_tmpfs` | Set to true to use [`docker-on-tmpfs`](https://github.com/marketplace/actions/docker-on-tmpfs) | `false` | `false` |
| `cache_enabled` | Utilise the [GitHub action cache](https://github.com/marketplace/actions/cache) | `false` | `false` |
| `cache_path` | Should match the `path:` input to the `actions/cache` step in a previous job | `false` | |
| `cache_key` | Should match the `key:` input to the `actions/cache` step in a previous job | `false` | |

#### `get_version_method`

The syntax is `method[:argument=value]`

##### Method: `cargo_toml_file_in_image`

Takes argument `file`, pointing to a `Cargo.toml` file inside the image. This file does not need to exist in the image before it is built (ie: it can be generated during the build process).

Example:

```yaml
  build_and_push:
    uses: sdr-enthusiasts/common-github-workflows/.github/workflows/build_and_push_image.yml@main
    with:
      get_version_method: cargo_toml_file_in_image:file=/Cargo.toml
```

The syntax above will read the version from the `version =` directive, inside the `[package]` section of `/Cargo.toml` after the image is built.

##### Method: `cargo_toml_file_in_repo`

Takes argument `file`, pointing to a `Cargo.toml` file inside the repo.

Example:

```yaml
  build_and_push:
    uses: sdr-enthusiasts/common-github-workflows/.github/workflows/build_and_push_image.yml@main
    with:
      get_version_method: cargo_toml_file_in_repo:file=/Cargo.toml
```

The syntax above will read the version from the `version =` directive, inside the `[package]` section of `/Cargo.toml` in the repo.

##### Method: `file_in_container`

Takes argument `file`, pointing to a file inside the image. This file does not need to exist in the image before it is built (ie: it can be generated during the build process).

Example:

```yaml
  build_and_push:
    uses: sdr-enthusiasts/common-github-workflows/.github/workflows/build_and_push_image.yml@main
    with:
      get_version_method: file_in_container:file=/IMAGE_VERSION
```

The syntax above will read the contents of the file `/IMAGE_VERSION` after the image is built.

##### Method: `git_commit_hash_short`

Takes no arguments. Will use the first 7 characters from the git commit hash. This is retrieved by running `git rev-parse HEAD` on the checked-out repository.

Example:

```yaml
  build_and_push:
    uses: sdr-enthusiasts/common-github-workflows/.github/workflows/build_and_push_image.yml@main
    with:
      get_version_method: git_commit_hash_short
```

### Secrets

| Input | Description |
| ----- | ----------- |
| `dockerhub_token` | If pushing to dockerhub, this should be a token for `dockerhub_profile` |
| `ghcr_token` | If pushing to ghcr.io, this should be a github token |
