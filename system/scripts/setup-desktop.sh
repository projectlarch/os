#!/bin/bash
# scripts/setup-desktop.sh — runs INSIDE a desktop's copy of the base rootfs
# Called by system/build.sh (stage 7) as:
#   chroot work/merged/<desktop> /setup-desktop.sh   (the desktop layer's build root)
# after the builder's dnf installed system/desktops/<desktop>/packages.list,
# with the desktop's setup.sh (if any) as /desktop-setup.sh.

set -euo pipefail

log() { echo "  [desktop] $*"; }

if [ -f /desktop-setup.sh ]; then
    log "Running the desktop's setup.sh"
    bash /desktop-setup.sh
    rm -f /desktop-setup.sh
fi

# The display manager the desktop enabled must be the only one.
[ -L /etc/systemd/system/display-manager.service ] \
    || { echo "ERROR: the desktop enabled no display manager (display-manager.service)" >&2; exit 1; }

rm -f /setup-desktop.sh
log "Desktop setup complete"
