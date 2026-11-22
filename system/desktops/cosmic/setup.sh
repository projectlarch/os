#!/bin/bash
# system/desktops/cosmic/setup.sh — COSMIC-specific configuration
# Runs inside the desktop's build root after its packages.list is installed
# (scripts/setup-desktop.sh, system stage 7). The COSMIC config files
# themselves are in ./rootfs-overlay (default wallpaper, dock).

set -euo pipefail

# cosmic-greeter (on greetd) is the display manager (display-manager.service).
systemctl enable cosmic-greeter

# The rootfs-overlay's COSMIC defaults (system-wide, under /usr/share/cosmic;
# each user's changes go to ~/.config/cosmic):
#   com.system76.CosmicBackground/v1/all  the larch wallpaper, as GNOME's
#                                        (cosmic-bg's default is a wallpaper
#                                        clean-rootfs.sh deletes)
#   com.system76.CosmicAppList/v1/favorites  the dock: Files, Sawmill, Settings
#                                        (Fedora's lists apps the image doesn't ship)
