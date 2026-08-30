# =====================================================================
# FORGE-AI read-only SMB export of the Windows installation media
# =====================================================================
# WinPE taken from a Windows Server ISO ships net.exe but not
# necessarily curl.exe, and it certainly cannot mount HTTP. SMB is the
# only transport guaranteed to be present for pulling a multi-gigabyte
# install.wim, which is why this service exists.
#
# The export is READ-ONLY and anonymous. It carries no secret: the
# per-host answer file travels through wimboot, never through this
# share. Exposure is limited to the isolated provisioning network.
FROM alpine:3.20.3

LABEL org.opencontainers.image.title="forge-winmedia" \
      org.opencontainers.image.description="Read-only SMB export of operator-supplied Windows installation media" \
      org.opencontainers.image.licenses="Apache-2.0"

# No `=~<version>` constraints here on purpose. The base image is pinned
# to a patch tag (alpine:3.20.3), and that tag fixes the package index it
# resolves against, so the installed versions are already deterministic.
# A fuzzy constraint layered on top adds no reproducibility -- it only
# adds a way for the build to break when the 3.20 branch moves Samba to
# the next minor. Record the resolved versions with
# `docker run --rm forge-winmedia apk list --installed`; docs/COMPATIBILITY.md
# carries the tested set.
#
# samba-client supplies smbclient, which the HEALTHCHECK below invokes;
# samba-server alone does not pull it in.
RUN apk add --no-cache samba-server samba-client samba-common-tools \
 && mkdir -p /var/lib/samba /var/log/samba /run/samba

COPY smb.conf /etc/samba/smb.conf
RUN chmod 0444 /etc/samba/smb.conf

EXPOSE 445
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD smbclient -N -L //127.0.0.1 >/dev/null 2>&1 || exit 1

# smbd stays in the foreground so Docker owns the process lifecycle.
ENTRYPOINT ["/usr/sbin/smbd", "--foreground", "--no-process-group", "--debug-stdout"]
