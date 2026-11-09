# Reproducible build environment for the Windows 11 slim-image toolkit.
#
# The image only contains the command-line tooling. The repository itself is
# bind-mounted at /repo by build-win11-docker.sh, so no source is baked in.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      p7zip-full \
      xorriso \
      wimtools \
      python3 \
      coreutils \
      findutils \
      gawk \
      sed \
      grep \
      ntfs-3g \
      chntpw \
      libhivex-bin \
 && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/windows-image-entrypoint
RUN chmod 0755 /usr/local/bin/windows-image-entrypoint

WORKDIR /repo/windows

ENTRYPOINT ["/usr/local/bin/windows-image-entrypoint"]
CMD ["bash"]
