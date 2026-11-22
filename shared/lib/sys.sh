# shared/lib/sys.sh — LARCHSYS's system layers and the root they form
# Sourced by sys.initramfs, the installer, the updater (after conf.sh, for
# OVL_OPTS) and system/build.sh; not executable on its own. Defines nothing
# but variables and functions.
#
# A release's OS root is a stack of squashfs layers (system/build.sh):
#
#   base.squashfs        the stripped base, a complete root on its own
#   <driver>.squashfs    a driver layer (DRIVER_LAYERS: nvidia), installed only
#                        where it's needed (wanted_drivers)
#   <desktop>.squashfs   a desktop (gnome, …)
#
# Driver and desktop layers each hold only what they add, change or delete
# (whiteouts) relative to the base, and each was built on the base alone, so a
# desktop runs with or without any driver layer. They're stacked read-only
# with overlayfs, the desktop on top: desktop, drivers…, base.
#
# On LARCHSYS (SYS_DIR):
#   sys/layers               the installed layers' names, top first ("gnome nvidia base")
#   sys/<layer>.squashfs     each of them
#   sys/version, sys/desktop the release tag and desktop
# An update builds sys.new/ beside it and swaps the directories
# (install_layers); sys/init falls back to sys.old/ if a swap was cut off
# between its two renames.

SYS_DIR=sys
DRIVER_LAYERS="nvidia"

# sys_dir <larchsys-mount>: the installed layers' directory (sys/, or sys.old/
# after a cut-off swap). Returns 1 if there is none.
sys_dir() {
    for _s in "$1/$SYS_DIR" "$1/$SYS_DIR.old"; do
        [ -s "$_s/layers" ] && { echo "$_s"; return 0; }
    done
    return 1
}

# mount_layers <dir> <mnt> <root>: each layer named in <dir>/layers
# loop-mounted at <mnt>/<layer>, and the read-only overlay of them all (the
# first on top) at <root>.
mount_layers() {
    _lower=""
    _n=0
    for _l in $(cat "$1/layers" 2>/dev/null); do
        mkdir -p "$2/$_l" || return 1
        if ! mount -t squashfs -o ro,loop "$1/$_l.squashfs" "$2/$_l"; then
            umount_layers "$3" "$2"; return 1
        fi
        _lower="${_lower:+$_lower:}$2/$_l"
        _n=$((_n + 1))
    done
    # At least the base and a desktop (an overlay without an upper layer
    # needs two lower ones anyway).
    [ "$_n" -ge 2 ] || { umount_layers "$3" "$2"; return 1; }
    mount -t overlay overlay -o "ro,lowerdir=$_lower,$OVL_OPTS" "$3" \
        || { umount_layers "$3" "$2"; return 1; }
    unset _l _lower _n
}

# umount_layers <root> <mnt>: undo mount_layers.
umount_layers() {
    umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null || true
    for _m in "$2"/*; do
        [ -d "$_m" ] || continue
        umount "$_m" 2>/dev/null || umount -l "$_m" 2>/dev/null || true
    done
    unset _m
}

# wanted_drivers: the driver layers this computer needs, space-separated:
# nvidia when it has an NVIDIA display controller (PCI vendor 0x10de, class
# 0x03xxxx). larch.drivers=<a,b,…|none> on the kernel command line, or the
# QEMU fw_cfg entry opt/larch/drivers, overrides the detection (testing).
wanted_drivers() {
    _o=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^larch\.drivers=//p' | tail -1)
    [ -n "$_o" ] || _o=$(cat /sys/firmware/qemu_fw_cfg/by_name/opt/larch/drivers/raw 2>/dev/null || true)
    if [ -n "$_o" ]; then
        _w=""
        for _d in $(echo "$_o" | tr ',' ' '); do
            case " $DRIVER_LAYERS " in *" $_d "*) _w="${_w:+$_w }$_d" ;; esac
        done
        echo "$_w"
        unset _o _w _d
        return 0
    fi
    for _p in /sys/bus/pci/devices/*; do
        [ "$(cat "$_p/vendor" 2>/dev/null)" = 0x10de ] || continue
        case "$(cat "$_p/class" 2>/dev/null)" in 0x03*) echo nvidia; break ;; esac
    done
    unset _o _p
}

# install_layers <stage> <larchsys-mount> <layers> <version> <desktop>: the
# downloaded layers (<stage>/<layer>.squashfs, top first in <layers>) as the
# installed system. They are moved into <larchsys-mount>/sys.new/ with the
# layers, version and desktop files, then the directories are swapped:
# sys → sys.old, sys.new → sys (ext4 renames), and sys.old is deleted.
install_layers() {
    _new="$2/$SYS_DIR.new"
    # A swap cut off between its renames left only sys.old: that's the
    # installed system until this one is in place.
    if [ ! -d "$2/$SYS_DIR" ] && [ -d "$2/$SYS_DIR.old" ]; then
        mv "$2/$SYS_DIR.old" "$2/$SYS_DIR" || return 1
    fi
    rm -rf "$_new" "$2/$SYS_DIR.old"
    mkdir -p "$_new" || return 1
    for _l in $3; do
        mv -f "$1/$_l.squashfs" "$_new/$_l.squashfs" || return 1
    done
    printf '%s\n' "$3" > "$_new/layers" \
        && printf '%s\n' "$4" > "$_new/version" \
        && printf '%s\n' "$5" > "$_new/desktop" || return 1
    sync
    if [ -d "$2/$SYS_DIR" ]; then mv "$2/$SYS_DIR" "$2/$SYS_DIR.old" || return 1; fi
    mv "$_new" "$2/$SYS_DIR" || return 1
    sync
    rm -rf "$2/$SYS_DIR.old"
    unset _new _l
}
