# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
FROM ghcr.io/ublue-os/bazzite-dx-nvidia:latest
## Other possible base images include:
# FROM ghcr.io/ublue-os/bazzite-dx-nvidia:stable
# FROM ghcr.io/ublue-os/aurora-dx-nvidia-open:stable
# FROM ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable
# 
# ... and so on, here are more base images
# Universal Blue Images: https://github.com/orgs/ublue-os/packages
# Fedora base image: quay.io/fedora/fedora-bootc:44
# CentOS base images: quay.io/centos-bootc/centos-bootc:stream10

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## We make /opt a real directory: see the "[IM]MUTABLE /opt" block in build_files/build.sh.

### CI-INJECTED RPM URLS
## Optional overrides so CI can resolve the latest upstream rpm through an authenticated
## GitHub API call instead of the rate-limited anonymous fallback inside build.sh.
ARG CLASH_VERGE_RPM_URL=""
ARG V2RAYA_RPM_URL=""

### VERSION METADATA
## BUILD_VERSION is "<upstream version>.v<build_files/VERSION>.t<N>", computed by `just build`
## (the .tN part is the per-version build serial, counted from existing registry tags).
## `bootc status` reads org.opencontainers.image.version from the image config, so it has
## to be known before the build; build.sh derives the same string and fails on mismatch.
ARG BUILD_VERSION="dev"
ARG BUILD_REVISION="unknown"
ARG BUILD_CREATED="1970-01-01T00:00:00Z"

LABEL org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.created="${BUILD_CREATED}"

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
