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

RUN apk add --no-cache samba-server=~4.19 samba-common-tools=~4.19 \
 && mkdir -p /var/lib/samba /var/log/samba /run/samba

COPY smb.conf /etc/samba/smb.conf
RUN chmod 0444 /etc/samba/smb.conf

EXPOSE 445
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD smbclient -N -L //127.0.0.1 >/dev/null 2>&1 || exit 1

# smbd stays in the foreground so Docker owns the process lifecycle.
ENTRYPOINT ["/usr/sbin/smbd", "--foreground", "--no-process-group", "--debug-stdout"]
