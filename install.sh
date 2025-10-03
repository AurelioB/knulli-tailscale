#!/bin/bash
# Knulli/Batocera — Tailscale client installer/updater
# - Installs/updates both binaries from tailscale_latest_$arch.tgz
# - Preserves /userdata/tailscale/state
# - Creates/updates a simple service that runs Tailscale as a client
# - Tries "tailscale up" once; if prefs conflict, retries with --reset
# - Optional: export TS_AUTHKEY='tskey-...' before running for hands-off login

set -euo pipefail

DEST="/userdata/tailscale"
BIN_TS="$DEST/tailscale"
BIN_TSD="$DEST/tailscaled"
SERVICE_DIR="/userdata/system/services"
SERVICE_FILE="$SERVICE_DIR/tailscale"

log() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

# ----- ARCH DETECTION -----
case "$(uname -m)" in
  x86_64|amd64)  arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  armv7l|armv7)  arch="arm" ;;
  riscv64)       arch="riscv64" ;;
  i386|i686|x86) arch="386" ;;
  *)
    warn "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac
log "Detected arch: ${arch}"

# ----- DOWNLOAD LATEST -----
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

URL="https://pkgs.tailscale.com/stable/tailscale_latest_${arch}.tgz"
log "Downloading: ${URL}"
if command -v wget >/dev/null 2>&1; then
  wget -q -O tailscale_latest.tgz "$URL"
else
  curl -fsSL -o tailscale_latest.tgz "$URL"
fi

# Determine versioned top directory, then extract
TS_TOPDIR="$(tar tzf tailscale_latest.tgz | head -1 | cut -d/ -f1)"
if [ -z "${TS_TOPDIR}" ]; then
  warn "Could not read top-level path from archive"
  exit 1
fi
log "Archive folder: ${TS_TOPDIR}"
tar xzf tailscale_latest.tgz

# Sanity check
if [ ! -x "${TS_TOPDIR}/tailscale" ] || [ ! -x "${TS_TOPDIR}/tailscaled" ]; then
  warn "Binaries not found after extraction"
  exit 1
fi

# ----- STOP SERVICE / DAEMON -----
log "Stopping existing tailscale (if running)..."
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
log "Installing new binaries..."
mkdir -p "$DEST"
# Back up existing binaries if present
cp -a "$BIN_TS"  "${BIN_TS}.bak.$(date +%s)" 2>/dev/null || true
cp -a "$BIN_TSD" "${BIN_TSD}.bak.$(date +%s)" 2>/dev/null || true

install -m 0755 "${TS_TOPDIR}/tailscale"  "$BIN_TS"
install -m 0755 "${TS_TOPDIR}/tailscaled" "$BIN_TSD"

# ----- WRITE/UPDATE SERVICE (client-only) -----
log "Writing service..."
mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_FILE" <<'EOSVC'
#!/bin/bash
# /userdata/system/services/tailscale
# Start tailscaled, then bring the node up as a client.

/userdata/tailscale/tailscaled -state /userdata/tailscale/state \
  >> /userdata/tailscale/tailscaled.log 2>&1 &

# Small delay to allow the daemon socket to come up
/bin/sleep 2

# Bring up as a client
/userdata/tailscale/tailscale up \
  --accept-routes \
  --ssh=false
EOSVC
chmod +x "$SERVICE_FILE"

# ----- START SERVICE -----
log "Starting service..."
batocera-services start tailscale || true

# Give it a moment, then check status; if "up" failed due to saved prefs, retry with --reset
sleep 2

if ! "$BIN_TS" status >/dev/null 2>&1; then
  warn "tailscale status not ready; attempting direct bring-up..."
  # Start daemon in case service didn't
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    "$BIN_TSD" -state "$DEST/state" >> "$DEST/tailscaled.log" 2>&1 &
    sleep 2
  fi

  # Prefer using an auth key if provided at install time
  AUTH_ARG=""
  if [ -n "${TS_AUTHKEY:-}" ]; then
    AUTH_ARG="--authkey=${TS_AUTHKEY}"
  fi

  if ! "$BIN_TS" up --accept-routes --ssh=false $AUTH_ARG >/dev/null 2>&1; then
    warn "first 'tailscale up' failed; retrying with --reset (one-time)"
    "$BIN_TS" up --reset --accept-routes --ssh=false $AUTH_ARG
  fi
fi

# Final report
echo
log "Installed versions:"
"$BIN_TS" version || true
echo
log "Service file: $SERVICE_FILE"
log "Done."
