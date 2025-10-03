#!/bin/bash
# Knulli/Batocera — Tailscale client installer/updater (no subnet-router bits)
# - Installs/updates both binaries from tailscale_latest_$arch.tgz (wget only)
# - Preserves /userdata/tailscale/state
# - Service starts only tailscaled (no interactive 'up' on boot)
# - First-run bring-up: uses TS_AUTHKEY if provided, otherwise prints a manual command

set -euo pipefail

DEST="/userdata/tailscale"
BIN_TS="$DEST/tailscale"
BIN_TSD="$DEST/tailscaled"
SERVICE_DIR="/userdata/system/services"
SERVICE_FILE="$SERVICE_DIR/tailscale"

TMP="/userdata/temp-ts"
OUT="$TMP/tailscale_latest.tgz"

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { warn "$*"; exit 1; }
on_err(){ warn "Failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"; }
trap on_err ERR

mkdir -p "$TMP" "$DEST"

# ----- ARCH DETECTION -----
case "$(uname -m)" in
  x86_64|amd64)  arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  armv7l|armv7)  arch="arm" ;;
  riscv64)       arch="riscv64" ;;
  i386|i686|x86) arch="386" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
log "Detected arch: ${arch}"

# ----- DOWNLOAD LATEST -----
URL="https://pkgs.tailscale.com/stable/tailscale_latest_${arch}.tgz"
log "Downloading: ${URL}"
log "Saving to:   ${OUT}"

attempt=1; max_attempts=3
while :; do
  if wget --server-response --progress=dot:giga -O "$OUT" "$URL" 2>&1; then
    break
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    if [ "${TS_INSECURE:-0}" = "1" ]; then
      warn "Retrying once with --no-check-certificate (INSECURE)…"
      wget --no-check-certificate --progress=dot:giga -O "$OUT" "$URL" \
        || die "Download failed even with --no-check-certificate."
      break
    fi
    die "Download failed after $attempt attempts. Set TS_INSECURE=1 to allow an insecure retry, or check clock/network."
  fi
  attempt=$((attempt+1))
  warn "Download failed; retrying ($attempt/$max_attempts)…"
  sleep 2
done

[ -s "$OUT" ] || die "Downloaded file is empty: $OUT"

# Verify gzip magic (1f 8b)
if ! dd if="$OUT" bs=2 count=1 2>/dev/null | od -An -t x1 | grep -qi '1f 8b'; then
  warn "Downloaded file does not look like a gzip archive: $OUT"
  warn "HEAD response:"
  wget -S --spider "$URL" 2>&1 | sed 's/^/[HDR] /'
  die "Bad download (not a .tgz). Check TLS/certs/clock or use TS_INSECURE=1."
fi

# ----- FIND TOP DIR (BUSYBOX-SAFE) -----
TS_TOPDIR=""
if TS_TOPDIR="$(tar tf "$OUT" 2>/dev/null | head -1 | cut -d/ -f1)"; then :; fi
if [ -z "${TS_TOPDIR}" ]; then
  warn "tar list failed; extracting to discover top directory…"
  EXTRACT_DIR="$TMP/extract"
  rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
  if ! tar -xf "$OUT" -C "$EXTRACT_DIR" 2>/dev/null; then
    tar -xzf "$OUT" -C "$EXTRACT_DIR" || die "Extraction failed (tar could not read $OUT)."
  fi
  TS_TOPDIR="$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "tailscale_*_${arch}" -printf "%f\n" | head -1 || true)"
  [ -n "$TS_TOPDIR" ] || die "Could not locate extracted tailscale directory."
  SRC_DIR="$EXTRACT_DIR/$TS_TOPDIR"
else
  log "Archive folder: ${TS_TOPDIR}"
  rm -rf "$TMP/$TS_TOPDIR"
  if ! tar -xf "$OUT" -C "$TMP" 2>/dev/null; then
    tar -xzf "$OUT" -C "$TMP" || die "Extraction failed (tar)."
  fi
  SRC_DIR="$TMP/$TS_TOPDIR"
fi

# Sanity check binaries
[ -x "$SRC_DIR/tailscale" ]  || die "tailscale binary not found in archive"
[ -x "$SRC_DIR/tailscaled" ] || die "tailscaled binary not found in archive"

# ----- STOP SERVICE / DAEMON -----
log "Stopping existing tailscale (if running)…"
batocera-services stop tailscale >/dev/null 2>&1 || true
killall tailscaled >/dev/null 2>&1 || true

# Ensure /dev/net/tun exists
if [ ! -e /dev/net/tun ]; then
  log "Creating /dev/net/tun"
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun
fi

# ----- INSTALL BINARIES (preserve state) -----
log "Installing new binaries…"
cp -a "$BIN_TS"  "${BIN_TS}.bak.$(date +%s)" 2>/dev/null || true
cp -a "$BIN_TSD" "${BIN_TSD}.bak.$(date +%s)" 2>/dev/null || true
install -m 0755 "$SRC_DIR/tailscale"  "$BIN_TS"
install -m 0755 "$SRC_DIR/tailscaled" "$BIN_TSD"

# ----- WRITE/UPDATE SERVICE (daemon only) -----
log "Writing service (daemon only) to $SERVICE_FILE…"
mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_FILE" <<'EOSVC'
#!/bin/bash
# /userdata/system/services/tailscale
# Start tailscaled only; once a node is authenticated, it auto-reconnects.

/userdata/tailscale/tailscaled -state /userdata/tailscale/state \
  >> /userdata/tailscale/tailscaled.log 2>&1 &
EOSVC
chmod +x "$SERVICE_FILE"

# ----- START DAEMON -----
log "Starting tailscale daemon…"
batocera-services start tailscale || true
sleep 2

# ----- ONE-TIME BRING-UP (non-blocking) -----
# If already authenticated, skip. Otherwise:
if "$BIN_TS" ip >/dev/null 2>&1; then
  log "Node already has a Tailscale IP; skipping 'tailscale up'."
else
  AUTH_ARG=""
  [ -n "${TS_AUTHKEY:-}" ] && AUTH_ARG="--authkey=${TS_AUTHKEY}"

  if [ -n "$AUTH_ARG" ]; then
    log "Bringing node up with auth key (non-interactive)…"
    # If prefs mismatch, retry once with --reset
    if ! "$BIN_TS" up --accept-routes --ssh=false $AUTH_ARG >/dev/null 2>&1; then
      warn "First 'tailscale up' failed; retrying with --reset"
      "$BIN_TS" up --reset --accept-routes --ssh=false $AUTH_ARG
    fi
  else
    cat <<EOF

To authenticate this device (one-time), run on the device shell:

  /userdata/tailscale/tailscale up --accept-routes --ssh=false

This will print a URL to approve in your browser, then exit. After that,
the daemon-only service will reconnect automatically on boot.
EOF
  fi
fi

echo
log "Installed versions:"
"$BIN_TS" version || true
echo
log "Download kept at: $OUT"
log "Extracted dir:   $SRC_DIR"
log "You can remove $TMP later if you want."
log "Done."
