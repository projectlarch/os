#!/bin/bash
# system/drivers/nvidia/setup.sh — runs INSIDE the nvidia layer's build root
# (system/build.sh stage 6), after its kmod and userspace packages are installed.
set -euo pipefail

# Save and restore video memory around suspend (modprobe.d/larch-nvidia.conf's
# NVreg_PreserveVideoMemoryAllocations); xorg-x11-drv-nvidia-580xx-power.
systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate
