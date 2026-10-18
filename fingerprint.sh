#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fedora 44 / GNOME adapter for the upstream Goodix 27c6:5125 libfprint driver.
# Upstream project: https://github.com/sorguido/goodix-27c6-5125
set -Eeuo pipefail

UPSTREAM_URL='https://github.com/sorguido/goodix-27c6-5125.git'
INSTALL_DIR='/usr/local/lib64/goodix-27c6-5125'
OVERRIDE='/etc/systemd/system/fprintd.service.d/90-goodix-5125-runtime.conf'
STATE_DIR='/var/lib/fprint/goodix-5125-state-v2'
MARKER='Managed by goodix-fingerprint-fedora-gnome'
WORK=''
STAGING=''
INSTALL_STARTED=0

say() { printf '[goodix-gnome] %s\n' "$*"; }
fail() { printf '[goodix-gnome] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage: bash fingerprint.sh {install|status|uninstall|help}

  install     Build upstream libfprint and configure ONLY fprintd for Goodix
  status      Display sensor, driver, service and PAM status
  uninstall   Remove files managed by this script (keep biometric state)

Run as your regular user, not with sudo. 'install' supports Fedora 44 x86_64
with USB sensor 27c6:5125 only. Read README.md before installation.
HELP
}

cleanup() {
  local code=$?
  trap - EXIT
  if (( code != 0 && INSTALL_STARTED == 1 )); then
    say 'Installation failed; attempting to restore stock fprintd...'
    sudo rm -f -- "$OVERRIDE" || true
    sudo rm -rf -- "$INSTALL_DIR" || true
    [[ -z "$STAGING" ]] || sudo rm -rf -- "$STAGING" || true
    sudo systemctl daemon-reload || true
    sudo systemctl restart fprintd.service || true
    say 'Existing fingerprint templates and pairing state were not removed.'
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

require_user() {
  [[ "${EUID}" -ne 0 ]] || fail 'Run as your normal user (bash fingerprint.sh ...), not sudo.'
  command -v sudo >/dev/null || fail 'sudo is required.'
}

require_fedora44() {
  [[ -f /etc/os-release ]] || fail '/etc/os-release not found.'
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == 'fedora' && "${VERSION_ID:-}" == '44' && "$(uname -m)" == 'x86_64' ]] || \
    fail 'Only Fedora 44 x86_64 is supported by this upstream build.'
}

path_exists() { sudo test -e "$1" || sudo test -L "$1"; }

status() {
  say 'USB reader:'
  if command -v lsusb >/dev/null; then
    lsusb -d 27c6:5125 || true
  else
    say 'Install usbutils for lsusb detection.'
  fi
  say 'fprintd environment:'
  systemctl show fprintd.service -p Environment --no-pager || true
  if [[ -f "$OVERRIDE" ]]; then
    say "Override exists: $OVERRIDE"
  else
    say 'No Goodix override found.'
  fi
  if [[ -f "$INSTALL_DIR/libfprint-2.so.2.0.0" ]]; then
    say 'Private Goodix libfprint is installed.'
  else
    say 'Private Goodix libfprint is not installed.'
  fi
  if command -v authselect >/dev/null; then
    say 'authselect:'
    authselect current || true
  fi
  say 'To verify an enrolled finger: fprintd-verify'
}

install_driver() {
  require_user
  require_fedora44
  command -v lsusb >/dev/null || fail "lsusb is missing. Install it first: sudo dnf install usbutils"
  lsusb -d 27c6:5125 | grep -Fq '27c6:5125' || \
    fail 'Goodix USB 27c6:5125 not found. Refusing to modify system.'
  if path_exists "$INSTALL_DIR" || path_exists "$OVERRIDE"; then
    fail 'An installation already exists. Do not overwrite it. Try status; see README for manual-install notes.'
  fi

  say 'Installing build dependencies (upstream source will be compiled locally)...'
  sudo dnf install -y git python3 usbutils gcc gcc-c++ meson ninja-build \
    pkgconf-pkg-config glib2-devel libgusb-devel openssl-devel opencv-devel \
    pam-devel binutils policycoreutils-python-utils fprintd fprintd-pam

  WORK="$(mktemp -d /tmp/goodix-gnome.XXXXXXXX)"
  say 'Cloning upstream source (main branch)...'
  git clone --depth 1 "$UPSTREAM_URL" "$WORK/upstream"
  say "Source commit: $(git -C "$WORK/upstream" rev-parse HEAD)"
  say 'Building a private runtime with upstream production/build-public.py...'
  (
    cd "$WORK/upstream"
    python3 production/build-public.py --output "$WORK/payload"
  )
  local runtime="$WORK/payload/runtime"
  [[ -f "$runtime/libfprint-2.so.2.0.0" && -L "$runtime/libfprint-2.so.2" ]] || \
    fail 'The build did not produce the expected libfprint runtime.'

  # Preserve sensitive state if it already exists. Never include it in a git repo.
  sudo install -d -o root -g root -m 0700 "$STATE_DIR"
  sudo restorecon -RF "$STATE_DIR"
  sudo ls -Zd "$STATE_DIR" | grep -Fq ':fprintd_var_lib_t:' || \
    fail 'Unexpected SELinux label on pairing-state directory. No system driver was changed.'

  # All preflight/build checks have passed. Changes from this point get rolled back on errors.
  INSTALL_STARTED=1
  STAGING="${INSTALL_DIR}.stage.$$"
  sudo systemctl stop fprintd.service
  sudo install -d -m 0755 "$STAGING"
  sudo cp -a "$runtime/." "$STAGING/"
  printf '%s\n' "$MARKER" | sudo tee "$STAGING/.goodix-gnome-managed" >/dev/null
  sudo chown -R root:root "$STAGING"
  sudo mv -- "$STAGING" "$INSTALL_DIR"
  STAGING=''
  sudo restorecon -RF "$INSTALL_DIR"

  sudo install -d -m 0755 /etc/systemd/system/fprintd.service.d
  printf '# %s\n[Service]\nEnvironment=LD_LIBRARY_PATH=%s\n' "$MARKER" "$INSTALL_DIR" | \
    sudo tee "$OVERRIDE" >/dev/null
  sudo restorecon -F "$OVERRIDE"
  sudo systemctl daemon-reload
  sudo systemctl restart fprintd.service
  systemctl show fprintd.service -p Environment --value | grep -Fq "LD_LIBRARY_PATH=$INSTALL_DIR" || \
    fail 'fprintd did not receive the expected environment.'
  INSTALL_STARTED=0
  say 'INSTALL=PASS. Enroll manually using: fprintd-enroll -f right-index-finger'
  say 'Do not enable fingerprint PAM until fprintd-verify returns verify-match.'
}

uninstall_driver() {
  require_user
  if path_exists "$OVERRIDE"; then
    sudo grep -Fq "$MARKER" "$OVERRIDE" || \
      fail 'Existing systemd override is not managed by this script; refusing to delete it.'
  fi
  if path_exists "$INSTALL_DIR"; then
    sudo grep -Fxq "$MARKER" "$INSTALL_DIR/.goodix-gnome-managed" || \
      fail 'Existing library directory is not managed by this script; refusing to delete it.'
  fi
  sudo systemctl stop fprintd.service
  sudo rm -f -- "$OVERRIDE"
  sudo rm -rf -- "$INSTALL_DIR"
  sudo systemctl daemon-reload
  sudo systemctl restart fprintd.service
  say 'UNINSTALL=PASS. Stock fprintd restored.'
  say 'Biometric templates, pairing state, and authselect/PAM settings were PRESERVED.'
}

case "${1:-help}" in
  install)   [[ $# -eq 1 ]] || { usage; exit 2; }; install_driver ;;
  status)    [[ $# -eq 1 ]] || { usage; exit 2; }; status ;;
  uninstall) [[ $# -eq 1 ]] || { usage; exit 2; }; uninstall_driver ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
