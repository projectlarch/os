#!/bin/bash
# system/build.sh — build the Larch OS system release (runs inside the builder)
#
# One release serves every desktop environment. Its OS root is a stack of
# squashfs layers, all built from one base rootfs (kernel, drivers, shared
# services), published as these files in $LARCH_OUTPUT_DIR/system/ (default
# output/system/):
#
#   base.squashfs           the stripped base: a complete root on its own
#   <driver>.squashfs       each driver layer (system/drivers/<driver>/: nvidia),
#                           installed only on computers that need it
#   <desktop>.squashfs      one per desktop (system/desktops/<desktop>/)
#   vmlinuz                 Fedora's kernel — the same for every layer
#   sys.initramfs           boots the system: mounts the layers as the root, /etc, /var
#   updater.initramfs       the "Manage LARCH" boot entry
#   BOOTX64.EFI, loader.tar systemd-boot and its configuration
#   SHA256SUMS
#
# Driver and desktop layers are overlayfs upper directories: each is built on
# the stripped base alone (never on another layer), so it holds only what it
# adds, changes or deletes (whiteouts) there, and any desktop runs with any
# set of driver layers below it (shared/lib/sys.sh). Stage 8 checks that the
# layers don't fight over a file and that the full stack still links.
#
# Every package is installed by the BUILDER's dnf (--installroot, the builder's
# Fedora + RPM Fusion repositories, weak dependencies off, no docs), so the
# rootfs never contains a package manager to remove. Out-of-tree kernel modules
# (NVIDIA, Broadcom wl) are compiled by akmods in the builder too, against the
# rootfs's kernel, and installed as kmod RPMs: no compiler enters the image.
# The package databases stay in the build trees (each layer's dnf needs the
# base's) and are left out of the squashfs files (config/squashfs.exclude).
#
# Stages:
#   1. check-deps        — verify build tools
#   2. bootstrap         — Fedora's filesystem + generic-release into work/rootfs
#   3. base-overlay      — merge rootfs-overlay/, the latest Sawmill AppImage
#   4. base-configure    — packages.list, the base's kmods (akmods), scripts/setup-chroot.sh
#   5. base              — copy the base to work/layers/base and strip it
#                          (remove.list, orphans, remove-files.list,
#                          scripts/clean-rootfs.sh), checking that no library
#                          anything still links was removed
#   6. drivers           — per driver layer: an overlay on the stripped base
#                          (upper: work/layers/<driver>), its kmods and
#                          packages, its setup, its rootfs-overlay/, stripped
#                          the same way
#   7. desktops          — per desktop: the same, with its packages.list and setup.sh
#   8. make-squashfs     — version stamps, the overlap and full-stack checks,
#                          base.squashfs, <driver>.squashfs, <desktop>.squashfs
#   9. sys-initramfs     — sys.initramfs (from the base)
#  10. updater-initramfs — updater.initramfs (from the base)
#  11. release-files     — vmlinuz, BOOTX64.EFI, loader.tar, SHA256SUMS
#
# work/rootfs is never stripped (stage 5 strips a copy), so stage 5 can be
# re-run at will; it discards the driver and desktop layers, which are built on
# it (re-run 6 and 7). The installer build needs only work/rootfs: stages 1-4.
#
# Run via the container (see docker-build.sh):
#   ./docker-build.sh system                      # all stages, every desktop
#   ./docker-build.sh system --desktop gnome      # only some desktops
#   ./docker-build.sh system --stage 7            # from stage 7 on
#   ./docker-build.sh system --only 9             # exactly one stage
#   ./docker-build.sh system --to 4               # just the base (for the installer)

set -euo pipefail

SYSTEM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SYSTEM_DIR")"
WORK_DIR="$ROOT_DIR/work"
ROOTFS_DIR="$WORK_DIR/rootfs"            # the base; build-lib.sh takes tools/modules from it
LAYERS_WORK="$WORK_DIR/layers"           # base/ (the stripped base) and each layer's upper dir
MERGED_WORK="$WORK_DIR/merged"           # a layer's build root (overlay) is mounted here
OUT_DIR="${LARCH_OUTPUT_DIR:-$ROOT_DIR/output}/system"
LARCH_VERSION="${LARCH_VERSION:-dev-$(date -u +%Y%m%d%H%M)}"

# shellcheck source=../shared/build-lib.sh
. "$ROOT_DIR/shared/build-lib.sh"
# ETC_LINKS/ETC_DEFAULTS (stage 5-7), DRIVER_LAYERS (the runtime's list).
# shellcheck source=../shared/lib/conf.sh
. "$ROOT_DIR/shared/lib/conf.sh"
# shellcheck source=../shared/lib/sys.sh
. "$ROOT_DIR/shared/lib/sys.sh"

FEDORA_RELEASE="$(list_entries "$SYSTEM_DIR/config/fedora-release" | head -1)"
[[ "$FEDORA_RELEASE" =~ ^[0-9]+$ ]] || die "config/fedora-release must be a Fedora release number"
KMOD_DIR="$WORK_DIR/kmods"               # kmod RPMs akmods built for the base's kernel
DNF_CACHE="$WORK_DIR/dnf-cache"

# ── Arguments ────────────────────────────────────────────────────────────────
DESKTOPS="${LARCH_DESKTOPS:-}"
STAGE_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop) DESKTOPS="$DESKTOPS $2"; shift 2 ;;
        *) STAGE_ARGS+=("$1"); shift ;;
    esac
done
if [ -z "${DESKTOPS// /}" ]; then
    DESKTOPS=$(cd "$SYSTEM_DIR/desktops" && ls -d -- */ | tr -d / | tr '\n' ' ')
fi
for de in $DESKTOPS; do
    [[ "$de" =~ ^[a-z0-9]+$ ]] || die "Desktop names are lowercase letters/digits: '$de'"
    [ -f "$SYSTEM_DIR/desktops/$de/packages.list" ] || die "No system/desktops/$de/packages.list"
done
# Driver layers: every system/drivers/<driver>/, always all of them. The
# installer and updater pick them by name (shared/lib/sys.sh DRIVER_LAYERS).
DRIVERS=$(cd "$SYSTEM_DIR/drivers" 2>/dev/null && ls -d -- */ 2>/dev/null | tr -d / | tr '\n' ' ' || true)
DRIVERS=${DRIVERS% }
[ "$DRIVERS" = "$DRIVER_LAYERS" ] \
    || die "system/drivers/ has '$DRIVERS' but shared/lib/sys.sh DRIVER_LAYERS is '$DRIVER_LAYERS'"
for l in $DRIVERS; do
    [[ "$l" =~ ^[a-z0-9]+$ ]] || die "Driver layer names are lowercase letters/digits: '$l'"
    [ ! -d "$SYSTEM_DIR/desktops/$l" ] || die "'$l' is both a driver layer and a desktop"
done
for l in $DRIVERS $DESKTOPS; do [ "$l" != base ] || die "'base' is the base layer's name"; done

BUILD_NAME="system"
END_STAGE=11
parse_stage_args "${STAGE_ARGS[@]}"

[ "$(id -u)" -eq 0 ] || die "Must run as root inside the privileged builder (chroot, mounts, …) — use ./docker-build.sh"
mkdir -p "$WORK_DIR" "$OUT_DIR"
info "Fedora $FEDORA_RELEASE; driver layers: ${DRIVERS:-none}; desktops: $DESKTOPS"

# dnf_root <root> <dnf args…>: the builder's dnf acting on <root>. Weak
# dependencies (Recommends) are never installed and docs never extracted; the
# image gets exactly the listed packages and what they require.
dnf_root() {
    local root="$1"; shift
    dnf -y -q --installroot="$root" --releasever="$FEDORA_RELEASE" --use-host-config \
        --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        --setopt=keepcache=True --setopt=cachedir="$DNF_CACHE" "$@"
}

# chroot_run <root> <script> [file…]: copy <script> and the files into <root>
# (each as /<its basename>, or /<name> for "path:name") and run it there.
chroot_run() {
    local root="$1" script="$2" dep; shift 2
    install -m 755 "$script" "$root/$(basename "$script")"
    for dep in "$@"; do
        if [[ "$dep" == *:* ]]; then cp "${dep%%:*}" "$root/${dep#*:}"
        else cp "$dep" "$root/$(basename "$dep")"; fi
    done
    chroot "$root" "/$(basename "$script")"
}

mount_chroot_pseudofs() {
    local root="$1"
    info "Mounting proc/sys/dev inside $root"
    mkdir -p "$root"/{proc,sys,dev}
    mount --bind /proc "$root/proc"
    mount --bind /sys  "$root/sys"
    # /dev must be bound recursively: under rootless Podman the container's
    # /dev is a tmpfs of placeholder files with each device node bind-mounted
    # over its placeholder, which a plain --bind would skip. rslave keeps the
    # recursive unmount below from propagating back.
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    CHROOT_MOUNTED="$root"
}

umount_chroot_pseudofs() {
    local root="${1:-${CHROOT_MOUNTED:-}}" m
    [ -n "$root" ] || return 0
    # Lazy and recursive, never -f: MNT_FORCE needs CAP_SYS_ADMIN in the
    # initial user namespace, so under rootless Podman `umount -f` fails and
    # leaves the mount behind (the next rsync then walks a live /sys). A mount
    # that survives is fatal rather than silently copied.
    for m in dev sys proc; do
        umount -Rl "$root/$m" 2>/dev/null || true
    done
    for m in dev sys proc; do
        if mountpoint -q "$root/$m"; then
            echo "ERROR: could not unmount $root/$m" >&2; exit 1
        fi
    done
    CHROOT_MOUNTED=""
}

# ── Layer build roots ────────────────────────────────────────────────────────
# A driver or desktop layer is built in an overlay: lower = the stripped base
# (work/layers/base), upper = work/layers/<layer>, which becomes
# <layer>.squashfs. The same options as every overlay larch mounts, plus
# xino=off: nothing in the upper dir may point into a particular lower layer.
OVL_BUILD_OPTS="$OVL_OPTS,xino=off"
LAYER_MOUNTS=()

# layer_mount <layer>: its build root at $MERGED_WORK/<layer> (LAYER_ROOT).
layer_mount() {
    LAYER_ROOT="$MERGED_WORK/$1"
    mkdir -p "$LAYERS_WORK/$1" "$LAYERS_WORK/.work-$1" "$LAYER_ROOT"
    mount -t overlay overlay \
        -o "lowerdir=$LAYERS_WORK/base,upperdir=$LAYERS_WORK/$1,workdir=$LAYERS_WORK/.work-$1,$OVL_BUILD_OPTS" \
        "$LAYER_ROOT"
    LAYER_MOUNTS+=("$LAYER_ROOT")
}

# stack_mount <dir> <layer>…: the read-only overlay of the layers (first on
# top) at <dir>, as sys.initramfs mounts them.
stack_mount() {
    local dir=$1 lower="" l; shift
    for l in "$@"; do lower="${lower:+$lower:}$LAYERS_WORK/$l"; done
    mkdir -p "$dir"
    mount -t overlay overlay -o "ro,lowerdir=$lower,$OVL_BUILD_OPTS" "$dir"
    LAYER_MOUNTS+=("$dir")
}

layer_umount() {
    local m keep=()
    umount "$1"
    for m in ${LAYER_MOUNTS[@]+"${LAYER_MOUNTS[@]}"}; do [ "$m" = "$1" ] || keep+=("$m"); done
    LAYER_MOUNTS=(${keep[@]+"${keep[@]}"})
}

cleanup() {
    local m
    umount_chroot_pseudofs
    for m in ${LAYER_MOUNTS[@]+"${LAYER_MOUNTS[@]}"}; do umount -l "$m" 2>/dev/null || true; done
}
trap cleanup EXIT

require_rootfs() {
    [ -d "$ROOTFS_DIR/usr" ] || die "Larch OS base rootfs not found — run system stages 2-4 first"
}
require_base_layer() {
    [ -d "$LAYERS_WORK/base/usr" ] || die "No stripped base (work/layers/base) — run system stage 5 first"
}
is_desktop() { case " $DESKTOPS " in *" $1 "*) return 0 ;; esac; return 1; }

# merged_list <list> <id> [layer-dir]: a list file for the strip, the base's
# config/<list> plus the layer's own.
merged_list() {
    local name="$1" id="$2" dir="${3:-}"
    local out="$WORK_DIR/lists/$id.$name"
    mkdir -p "$WORK_DIR/lists"
    cat "$SYSTEM_DIR/config/$name" > "$out"
    if [ -n "$dir" ] && [ -f "$dir/$name" ]; then cat "$dir/$name" >> "$out"; fi
    echo "$out"
}

# sync_overlay <overlay-dir> <root>: copy_overlay for a layer's build root.
# Only files whose content or mode differ are written, so the base's overlay
# files that a layer's packages left alone are not copied up into the layer.
sync_overlay() {
    rsync -rlpc --no-owner --no-group --omit-dir-times --chmod=go-w "$1/" "$2/"
}

# copy_resolv <root>: the builder's resolv.conf for package scriptlets and
# chrooted steps that need the network, without following the image's symlink.
copy_resolv() {
    rm -f "$1/etc/resolv.conf"
    cp /etc/resolv.conf "$1/etc/resolv.conf"
}

# ── Sawmill (the app manager) ────────────────────────────────────────────────
# install_sawmill <root>: the latest Sawmill release's x86_64 AppImage
# (github.com/projectlarch/sawmill) at /opt/sawmill/Sawmill.AppImage, its icon in
# hicolor; the launcher is rootfs-overlay/usr/share/applications/
# io.sawmill.Store.desktop. Verified against the asset digest GitHub's API
# publishes; cached in work/sawmill/<tag>/ so a re-run only checks the tag.
SAWMILL_REPO=projectlarch/sawmill
SAWMILL_ASSET=Sawmill-x86_64.AppImage
install_sawmill() {
    local root=$1 json tag sum dir auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    json=$(curl -fsSL ${auth[@]+"${auth[@]}"} -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$SAWMILL_REPO/releases/latest") \
        || die "Cannot read the latest Sawmill release from GitHub's API"
    tag=$(printf '%s\n' "$json" | sed -n 's/^  "tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    # The asset objects list "name" before "digest"; take the digest that
    # follows our asset's name.
    sum=$(printf '%s\n' "$json" | awk -v a="$SAWMILL_ASSET" '
        /"name":/   { hit = index($0, "\"" a "\"") > 0 }
        /"digest":/ && hit { sub(/.*"sha256:/, ""); sub(/".*/, ""); print; exit }')
    [ -n "$tag" ] || die "No tag_name in Sawmill's latest release"
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || die "Sawmill $tag has no sha256 digest for $SAWMILL_ASSET"
    dir="$WORK_DIR/sawmill/$tag"
    if ! echo "$sum  $dir/$SAWMILL_ASSET" | sha256sum -c --status 2>/dev/null; then
        info "Downloading Sawmill $tag"
        rm -rf "$WORK_DIR/sawmill"; mkdir -p "$dir"
        curl -fsSL -o "$dir/$SAWMILL_ASSET" \
            "https://github.com/$SAWMILL_REPO/releases/download/$tag/$SAWMILL_ASSET" \
            || die "Sawmill $tag: download failed"
        echo "$sum  $dir/$SAWMILL_ASSET" | sha256sum -c --status \
            || die "Sawmill $tag: $SAWMILL_ASSET does not match its sha256 digest"
        curl -fsSL -o "$dir/io.sawmill.Store.png" \
            "https://raw.githubusercontent.com/$SAWMILL_REPO/$tag/client/data/icons/io.sawmill.Store.png" \
            || die "Sawmill $tag: icon download failed"
    else
        info "Sawmill $tag already downloaded"
    fi
    install -D -m 0755 "$dir/$SAWMILL_ASSET" "$root/opt/sawmill/Sawmill.AppImage"
    printf '%s\n' "$tag" | install -m 0644 /dev/stdin "$root/opt/sawmill/version"
    install -D -m 0644 "$dir/io.sawmill.Store.png" \
        "$root/usr/share/icons/hicolor/512x512/apps/io.sawmill.Store.png"
}

# ── Out-of-tree kernel modules ───────────────────────────────────────────────
# install_kmods <root> <akmods.list>: akmods builds a kmod RPM per akmod for
# the rootfs's kernel in the builder (kernel-devel of exactly that version;
# akmodsbuild refuses root, so it runs as akmods' user), and the RPMs go into
# <root> in one transaction with the userspace packages that require them.
# Rebuilt only when the kernel or the akmod changed (work/kmods/<name>).
install_kmods() {
    local root=$1 list=$2 kver ak rest name srpm stamp out r f n
    local akmods=() pkgs=() rpms=() more=()
    kver=$(rootfs_kver)
    while read -r ak rest; do
        [ -n "$ak" ] || continue
        akmods+=("$ak"); read -r -a more <<< "$rest"; pkgs+=(${more[@]+"${more[@]}"})
    done < <(list_entries "$list")
    [ "${#akmods[@]}" -gt 0 ] || return 0
    info "Building kmods for kernel $kver (akmods, in the builder): ${akmods[*]}"
    dnf -y -q --setopt=install_weak_deps=False install "kernel-devel-$kver" "${akmods[@]}"
    id akmods >/dev/null 2>&1 || useradd -r -M -d /var/cache/akmods akmods
    mkdir -p "$KMOD_DIR"
    for ak in "${akmods[@]}"; do
        name=${ak#akmod-}
        srpm=$(readlink -f "/usr/src/akmods/$name-kmod.latest" 2>/dev/null || true)
        [ -f "$srpm" ] || die "No akmods source RPM for $ak (/usr/src/akmods/$name-kmod.latest)"
        stamp="$(basename "$srpm") $kver"
        out="$KMOD_DIR/$name"
        if [ "$(cat "$out/.built" 2>/dev/null)" != "$stamp" ]; then
            info "  akmodsbuild $(basename "$srpm") for $kver"
            rm -rf "$out" "$WORK_DIR/akmods-build"; mkdir -p "$out" "$WORK_DIR/akmods-build"
            chown akmods: "$out" "$WORK_DIR/akmods-build"
            (cd "$WORK_DIR/akmods-build" && runuser -u akmods -- env HOME="$WORK_DIR/akmods-build" \
                akmodsbuild --kernels "$kver" --outputdir "$out" "$srpm") \
                > "$WORK_DIR/akmods-$name.log" 2>&1 \
                || { tail -40 "$WORK_DIR/akmods-$name.log" >&2; die "akmodsbuild failed for $name"; }
            echo "$stamp" > "$out/.built"
        else
            info "  kmod-$name for $kver already built ($(basename "$srpm"))"
        fi
        for r in "$out"/kmod-"$name"-"$kver"-*.x86_64.rpm; do
            [ -f "$r" ] || die "akmodsbuild left no kmod-$name-$kver RPM in $out"
            rpms+=("$r")
        done
    done
    dnf_root "$root" install "${rpms[@]}" ${pkgs[@]+"${pkgs[@]}"}
    chroot "$root" depmod -a "$kver"
    # Every module the kmod RPMs carry is in place.
    for r in "${rpms[@]}"; do
        n=0
        while read -r f; do
            case "$f" in *.ko|*.ko.*)
                [ -e "$root$f" ] || die "$(basename "$r"): $f is missing from the rootfs"
                n=$((n + 1)) ;;
            esac
        done < <(rpm -qlp "$r" 2>/dev/null)
        [ "$n" -gt 0 ] || die "$(basename "$r") carries no kernel module"
    done
}

# ── Shared-library guard ─────────────────────────────────────────────────────
# What a strip removes must not be a library anything left links.
# guard_record <root> <id> before stripping; guard_check <root> <id> after:
# every DT_NEEDED soname that resolved before must still resolve for each file
# still there (sonames already unresolved are optional plugins whose library
# Fedora leaves to another package; they don't count). guard_stack does the
# same for a whole stack of layers. Runs the builder's readelf over the
# rootfs, so the image needs no binutils.
guard_sonames_present() {
    (cd "$1" && find usr/lib usr/lib64 \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' \) \
        -printf '%f\n' 2>/dev/null) | sort -u
}
guard_needed() {   # <soname> TAB <file> for every DT_NEEDED in <root>
    (cd "$1" && find usr/bin usr/sbin usr/lib usr/lib64 usr/libexec -type f \
        \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
        | xargs -0 -r readelf -d 2>/dev/null \
        | awk '/^File: /{f=$2} /\(NEEDED\)/{gsub(/[][]/,"",$5); print $5 "\t" f}') \
        | sort -u || true
}
guard_record() {
    local root="$1" g="$WORK_DIR/libguard/$2"
    rm -rf "$g"; mkdir -p "$g"
    info "[$2] Recording shared-library dependencies"
    guard_needed "$root" > "$g/needed"
    cut -f1 "$g/needed" | sort -u > "$g/needed.sonames"
    guard_sonames_present "$root" > "$g/present.before"
    comm -23 "$g/needed.sonames" "$g/present.before" > "$g/missing.before"
}
# guard_report <dir> <root>: an error per soname in <dir>/broken that a file
# still in <root> needs; returns 1 if any.
guard_report() {
    local g="$1" root="$2" so users broken=0
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        users=$(awk -F'\t' -v so="$so" '$1 == so {print $2}' "$g/needed" \
                | while read -r f; do if [ -e "$root/$f" ]; then echo "/$f"; fi; done \
                | head -3 | tr '\n' ' ' || true)
        [ -n "$users" ] || continue    # only files that were removed too needed it
        echo "ERROR: $so is missing but needed by: $users" >&2
        broken=1
    done < "$g/broken"
    return "$broken"
}
guard_check() {
    local root="$1" g="$WORK_DIR/libguard/$2"
    guard_sonames_present "$root" > "$g/present.after"
    comm -23 "$g/needed.sonames" "$g/present.after" | comm -23 - "$g/missing.before" > "$g/broken"
    guard_report "$g" "$root" \
        || die "[$2] The strip removed libraries the layer needs (remove.list / orphans / remove-files.list)"
    info "[$2] Library guard: no needed shared library was removed"
}
# guard_stack <root> <id>…: in the stack mounted at <root>, every soname a
# file needs resolves, unless it was already unresolved in one of the layers'
# own builds (<id>…).
guard_stack() {
    local root="$1" g="$WORK_DIR/libguard/stack" id; shift
    rm -rf "$g"; mkdir -p "$g"
    guard_needed "$root" > "$g/needed"
    cut -f1 "$g/needed" | sort -u > "$g/needed.sonames"
    guard_sonames_present "$root" > "$g/present"
    for id in "$@"; do cat "$WORK_DIR/libguard/$id/missing.before"; done | sort -u > "$g/allowed"
    comm -23 "$g/needed.sonames" "$g/present" | comm -23 - "$g/allowed" > "$g/broken"
    guard_report "$g" "$root"
}

# ── Strip, /etc links ────────────────────────────────────────────────────────
# strip_root <root> <id> [layer-dir]: remove.list (rpm globs, `!` lines keep;
# the base's + the layer's), the orphans, then scripts/clean-rootfs.sh with
# remove-files.list (base's + layer's) and the layer's launcher.list; guarded.
# rpm -e --nodeps, no scriptlets: what depends on a removed build-time package
# keeps working without it (the guard checks that).
strip_root() {
    local root="$1" id="$2" dir="${3:-}" pkg k p deps=()
    local patterns=() keeps=() purge=()
    info "[$id] Stripping"
    guard_record "$root" "$id"
    mapfile -t patterns < <(list_entries "$(merged_list remove.list "$id" "$dir")" | grep -v '^!' || true)
    mapfile -t keeps < <(list_entries "$(merged_list remove.list "$id" "$dir")" | sed -n 's/^!//p')
    while read -r pkg; do
        # shellcheck disable=SC2053  # unquoted on purpose: glob match
        for k in ${keeps[@]+"${keeps[@]}"}; do [[ $pkg == $k ]] && continue 2; done
        # shellcheck disable=SC2053
        for p in ${patterns[@]+"${patterns[@]}"}; do
            if [[ $pkg == $p ]]; then purge+=("$pkg"); break; fi
        done
    done < <(rpm --root "$root" -qa --qf '%{NAME}\n' | sort -u)
    if [ "${#purge[@]}" -gt 0 ]; then
        info "[$id] remove.list: ${purge[*]}"
        rpm --root "$root" -e --nodeps --noscripts --notriggers "${purge[@]}"
    fi
    # Orphans: what only the removed packages (or nothing) needed.
    info "[$id] Removing orphaned dependencies"
    dnf_root "$root" autoremove --setopt=tsflags=noscripts,nodocs || true
    deps=("$(merged_list remove-files.list "$id" "$dir"):remove-files.list")
    if [ -n "$dir" ] && [ -f "$dir/launcher.list" ]; then deps+=("$dir/launcher.list:launcher.list"); fi
    chroot_run "$root" "$SYSTEM_DIR/scripts/clean-rootfs.sh" "${deps[@]}"
    guard_check "$root" "$id"
    # Root is mounted read-only, so NetworkManager can't rewrite
    # /etc/resolv.conf; point it at the file NM keeps in /run.
    rm -f "$root/etc/resolv.conf"
    ln -s ../run/NetworkManager/resolv.conf "$root/etc/resolv.conf"
}

# etc_links <root>: /etc's per-machine files become links to LARCHCONF
# (/conf/etc/<file>), so they stay out of /etc's overlay (accounts only); the
# image's own version is kept in ETC_DEFAULTS for mount_etc
# (shared/lib/conf.sh). Idempotent, and run on every layer: a layer whose
# packages replaced one of the links gets its file moved the same way. A
# relative symlink (localtime → ../usr/share/zoneinfo/UTC) is stored with its
# absolute target, which resolves from /conf/etc too.
etc_links() {
    local root="$1" f t
    mkdir -p "$root/$ETC_DEFAULTS"
    for f in $ETC_LINKS; do
        [ "$(readlink "$root/etc/$f" 2>/dev/null)" = "/conf/etc/$f" ] && continue
        rm -rf "${root:?}/$ETC_DEFAULTS/$f"
        if [ -L "$root/etc/$f" ]; then
            t=$(readlink "$root/etc/$f")
            [ "${t#/}" != "$t" ] || t=$(realpath -m "/etc/$t")
            ln -s "$t" "$root/$ETC_DEFAULTS/$f"
            rm -f "$root/etc/$f"
        elif [ -e "$root/etc/$f" ]; then
            mv "$root/etc/$f" "$root/$ETC_DEFAULTS/$f"
        fi
        ln -s "/conf/etc/$f" "$root/etc/$f"
    done
    # The image is the root of every install as-is, so it carries no machine
    # identity: the installer writes LARCHCONF:/etc/machine-id, and an empty
    # default keeps systemd from treating a missing one as a first boot.
    # D-Bus's copy follows it.
    if [ ! -f "$root/$ETC_DEFAULTS/machine-id" ] || [ -s "$root/$ETC_DEFAULTS/machine-id" ]; then
        : > "$root/$ETC_DEFAULTS/machine-id"
    fi
    if [ "$(readlink "$root/var/lib/dbus/machine-id" 2>/dev/null)" != /etc/machine-id ]; then
        mkdir -p "$root/var/lib/dbus"
        ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
    fi
}

# build_layer <layer> <dir> driver|desktop: work/layers/<layer> built afresh
# on the stripped base: a driver's kmods (akmods.list) and packages.list, or a
# desktop's packages.list; its setup.sh (a desktop's via
# scripts/setup-desktop.sh, which requires a display manager); the base's
# and the layer's rootfs-overlay/; stripped like the base.
build_layer() {
    local l="$1" dir="$2" kind="$3" root deps=() kver
    kver=$(rootfs_kver)
    info "[$l] Building the $kind layer on the base"
    rm -rf "${LAYERS_WORK:?}/$l" "$LAYERS_WORK/.work-$l"
    layer_mount "$l"; root=$LAYER_ROOT
    mount_chroot_pseudofs "$root"
    copy_resolv "$root"
    # The kernel is the base's: every layer of a release carries modules
    # for the one vmlinuz the release ships.
    if [ "$kind" = driver ]; then
        if [ -f "$dir/akmods.list" ]; then install_kmods "$root" "$dir/akmods.list"; fi
        if [ -f "$dir/packages.list" ]; then
            # shellcheck disable=SC2046
            dnf_root "$root" install --exclude='kernel*' $(list_entries "$dir/packages.list")
        fi
        if [ -f "$dir/setup.sh" ]; then
            chroot_run "$root" "$dir/setup.sh"
            rm -f "$root/setup.sh"
        fi
    else
        info "[$l] Installing the desktop's packages"
        # shellcheck disable=SC2046
        dnf_root "$root" install --exclude='kernel*' $(list_entries "$dir/packages.list")
        if [ -f "$dir/setup.sh" ]; then deps+=("$dir/setup.sh:desktop-setup.sh"); fi
        chroot_run "$root" "$SYSTEM_DIR/scripts/setup-desktop.sh" ${deps[@]+"${deps[@]}"}
    fi
    # After the packages, so the base's and the layer's files win.
    sync_overlay "$SYSTEM_DIR/rootfs-overlay" "$root"
    if [ -d "$dir/rootfs-overlay" ]; then sync_overlay "$dir/rootfs-overlay" "$root"; fi
    strip_root "$root" "$l" "$dir"
    umount_chroot_pseudofs
    etc_links "$root"
    [ -d "$root/usr/lib/modules/$kver" ] || die "[$l] lost the modules of kernel $kver"
    layer_umount "$root"
    rm -rf "${LAYERS_WORK:?}/.work-$l"
}

# ── Layer checks (stage 8) ───────────────────────────────────────────────────
# Files every layer regenerates (caches, stamps, the account files a desktop
# adds its users to): with a desktop on top, its copy is the one in use, and
# it covers what the driver layers need (their libraries are in the default
# library path; checked below).
LAYER_SHARED_RE='^(etc/ld\.so\.cache|etc/\.updated|var/\.updated|etc/resolv\.conf|etc/(passwd|group|shadow|gshadow|subuid|subgid)-?|usr/share/glib-2\.0/schemas/gschemas\.compiled|usr/share/icons/[^/]+/icon-theme\.cache|usr/share/applications/mimeinfo\.cache|usr/lib/fontconfig/cache/.*|etc/dconf/db/.*|var/cache/ldconfig/.*|var/lib/(rpm|dnf)/.*|usr/lib/sysimage/.*|tmp/.*|run/.*)$'

# check_layers: a desktop sits above every driver layer, so a file both change
# is the desktop's — the driver layer's change would be lost. Allowed only
# for LAYER_SHARED_RE (or identical content). A driver layer must not add
# accounts (the desktops' account files hide them) or library directories
# (the desktops' ld.so.cache doesn't list them).
check_layers() {
    local l de f bad=0 lw=$LAYERS_WORK
    mkdir -p "$WORK_DIR/lists"
    for l in $DRIVERS $DESKTOPS; do
        (cd "$lw/$l" && find . ! -type d | sed 's|^\./||' | sort) > "$WORK_DIR/lists/$l.files"
    done
    for l in $DRIVERS; do
        for f in passwd group shadow gshadow; do
            if [ -e "$lw/$l/etc/$f" ] && ! cmp -s "$lw/$l/etc/$f" "$lw/base/etc/$f"; then
                echo "ERROR: the $l layer changes /etc/$f (a driver layer can't add accounts)" >&2; bad=1
            fi
        done
        if grep '^etc/ld\.so\.conf\.d/' "$WORK_DIR/lists/$l.files" >&2; then
            echo "ERROR: the $l layer adds library directories (above)" >&2; bad=1
        fi
        for de in $DESKTOPS; do
            while IFS= read -r f; do
                [[ $f =~ $LAYER_SHARED_RE ]] && continue
                # Both delete it (whiteouts), link it alike, or write the same.
                [ -c "$lw/$l/$f" ] && [ -c "$lw/$de/$f" ] && continue
                if [ -L "$lw/$l/$f" ] || [ -L "$lw/$de/$f" ]; then
                    [ "$(readlink "$lw/$l/$f")" = "$(readlink "$lw/$de/$f")" ] && continue
                elif cmp -s "$lw/$l/$f" "$lw/$de/$f" 2>/dev/null; then
                    continue
                fi
                echo "ERROR: /$f is changed by both the $l and the $de layer" >&2; bad=1
            done < <(comm -12 "$WORK_DIR/lists/$l.files" "$WORK_DIR/lists/$de.files")
        done
    done
    [ "$bad" -eq 0 ] || die "The layers conflict (see above)"
    info "Layers: no driver layer and desktop change the same file"
}

# check_stack <desktop>: the desktop over every driver layer over the base,
# mounted as an installed system would: every library still resolves, and
# the module index knows every driver layer's modules.
check_stack() {
    local de="$1" root="$MERGED_WORK/stack-$de" kver l m
    kver=$(rootfs_kver)
    # shellcheck disable=SC2086
    stack_mount "$root" "$de" $DRIVERS base
    info "[$de] Checking the full stack ($de ${DRIVERS:+$DRIVERS }base)"
    # shellcheck disable=SC2086
    guard_stack "$root" base $DRIVERS "$de" || { layer_umount "$root"; die "[$de] Libraries are missing in the full stack"; }
    for l in $DRIVERS; do
        while IFS= read -r m; do
            grep -q "^${m#usr/lib/modules/$kver/}:" "$root/usr/lib/modules/$kver/modules.dep" \
                || { layer_umount "$root"; die "[$de] modules.dep of the full stack lacks $m (the $l layer)"; }
        done < <(cd "$LAYERS_WORK/$l" && find "usr/lib/modules/$kver" -name '*.ko*' 2>/dev/null)
    done
    layer_umount "$root"
}

# ── Stage 1: check-deps ──────────────────────────────────────────────────────
run_stage 1 "check-deps" && {
    MISSING=()
    for cmd in dnf rpm readelf akmodsbuild mksquashfs rsync cpio find xz gzip sha256sum; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        printf 'Missing build tools in the builder image: %s\n' "${MISSING[*]}" >&2
        echo "They come from the Dockerfile; ./docker-build.sh rebuilds the image." >&2
        exit 1
    fi
    builder_rel=$(. /etc/os-release && echo "$VERSION_ID")
    [ "$builder_rel" = "$FEDORA_RELEASE" ] \
        || die "The builder is Fedora $builder_rel but config/fedora-release says $FEDORA_RELEASE (Dockerfile FROM)"
    info "All dependencies found"
}

# ── Stage 2: bootstrap ───────────────────────────────────────────────────────
# The filesystem layout and the release identity. generic-release (not
# fedora-release): Fedora's trademark guidelines want derivatives unbranded.
# kernel-install's plugins are disabled before any kernel arrives: every larch
# initramfs is built by hand (no dracut), there is no GRUB/BLS entry to write
# (systemd-boot's entries are release files), and the kernel ships as the
# release's vmlinuz from /usr/lib/modules/<ver>/vmlinuz. 50-depmod stays.
run_stage 2 "bootstrap — Fedora $FEDORA_RELEASE filesystem into work/rootfs" && {
    if [ -d "$ROOTFS_DIR/usr" ]; then
        info "Base rootfs already exists, skipping the bootstrap. Use --clean to restart."
    else
        mkdir -p "$ROOTFS_DIR/etc/kernel/install.d"
        for p in 20-grub 50-dracut 51-dracut-rescue 60-kdump 90-loaderentry 90-uki-copy \
                 92-crashkernel 92-tuned 99-grub-mkconfig; do
            ln -sf /dev/null "$ROOTFS_DIR/etc/kernel/install.d/$p.install"
        done
        mount_chroot_pseudofs "$ROOTFS_DIR"
        dnf_root "$ROOTFS_DIR" install filesystem generic-release
        umount_chroot_pseudofs
    fi
}

# ── Stage 3: base-overlay ────────────────────────────────────────────────────
run_stage 3 "base-overlay — merge rootfs-overlay, install Sawmill" && {
    require_rootfs
    copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$ROOTFS_DIR"
    install_sawmill "$ROOTFS_DIR"
}

# ── Stage 4: base-configure ──────────────────────────────────────────────────
run_stage 4 "base-configure — install the base packages and configure" && {
    require_rootfs
    mount_chroot_pseudofs "$ROOTFS_DIR"
    copy_resolv "$ROOTFS_DIR"
    info "Installing config/packages.list"
    # shellcheck disable=SC2046
    dnf_root "$ROOTFS_DIR" install $(list_entries "$SYSTEM_DIR/config/packages.list")
    kver=$(rootfs_kver)
    [ -f "$ROOTFS_DIR/usr/lib/modules/$kver/vmlinuz" ] || die "No vmlinuz for kernel $kver in the rootfs"

    # The base's out-of-tree modules (config/akmods.list); driver layers
    # have their own (stage 6).
    install_kmods "$ROOTFS_DIR" "$SYSTEM_DIR/config/akmods.list"

    chroot_run "$ROOTFS_DIR" "$SYSTEM_DIR/scripts/setup-chroot.sh"
    rm -f "$ROOTFS_DIR/setup-chroot.sh"
    umount_chroot_pseudofs
    # The packages may have replaced an overlay file (dnf has no conffile
    # prompts); put ours back.
    copy_overlay "$SYSTEM_DIR/rootfs-overlay" "$ROOTFS_DIR"
}

# ── Stage 5: base ────────────────────────────────────────────────────────────
run_stage 5 "base — strip a copy of the base into work/layers/base" && {
    require_rootfs
    kver=$(rootfs_kver)
    root="$LAYERS_WORK/base"
    # Every other layer is built on this one: an older build of them is stale.
    for l in "$LAYERS_WORK"/* "$LAYERS_WORK"/.work-*; do
        [ -e "$l" ] && [ "$l" != "$root" ] && rm -rf "$l"
    done
    info "[base] Copying the base → $root"
    mkdir -p "$root"
    # The pseudo-filesystems' mount points only; their contents (and any
    # left in the copy by an earlier run) never belong in an image.
    rsync -aHAX --numeric-ids --delete --delete-excluded \
        --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
        "$ROOTFS_DIR/" "$root/"
    mount_chroot_pseudofs "$root"
    strip_root "$root" base
    umount_chroot_pseudofs
    etc_links "$root"
    [ -d "$root/usr/lib/modules/$kver" ] || die "[base] lost the modules of kernel $kver"
}

# ── Stage 6: drivers ─────────────────────────────────────────────────────────
run_stage 6 "drivers — each driver layer on the stripped base" && {
    require_rootfs; require_base_layer
    for l in $DRIVERS; do build_layer "$l" "$SYSTEM_DIR/drivers/$l" driver; done
}

# ── Stage 7: desktops ────────────────────────────────────────────────────────
run_stage 7 "desktops — each desktop layer on the stripped base" && {
    require_rootfs; require_base_layer
    for de in $DESKTOPS; do build_layer "$de" "$SYSTEM_DIR/desktops/$de" desktop; done
}

# ── Stage 8: make-squashfs ───────────────────────────────────────────────────
run_stage 8 "make-squashfs — base.squashfs, one per driver layer and desktop" && {
    require_rootfs; require_base_layer
    for l in $DRIVERS $DESKTOPS; do
        [ -d "$LAYERS_WORK/$l/usr" ] || die "No $l layer (work/layers/$l) — run stage 6/7 first"
    done
    base="$LAYERS_WORK/base"
    # What each layer is: shown by the updater, checked by release.sh
    # (check_release: every layer of an install from the same build).
    mkdir -p "$base/usr/lib/larch/layers"
    printf '%s\n' "$LARCH_VERSION" > "$base/usr/lib/larch/version"
    printf '%s\n' "$LARCH_VERSION" > "$base/usr/lib/larch/layers/base"
    # os-release carries the release too (GNOME Settings → About shows
    # PRETTY_NAME): tag v0.7.2 → "Larch 0.7.2". /etc/os-release is a
    # symlink to it. Rewritten from rootfs-overlay's template every run.
    osrel="$base/usr/lib/os-release"
    ver=${LARCH_VERSION#v}
    [ -L "$base/etc/os-release" ] || cp -f "$base/etc/os-release" "$osrel"
    sed -i -e "s/^VERSION=.*/VERSION=\"$ver\"/" \
           -e "s/^VERSION_ID=.*/VERSION_ID=$ver/" \
           -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Larch $ver\"/" \
           -e '/^IMAGE_VERSION=/d' "$osrel"
    printf 'IMAGE_VERSION=%s\n' "$ver" >> "$osrel"
    ln -sfn ../usr/lib/os-release "$base/etc/os-release"
    for l in $DRIVERS $DESKTOPS; do
        layer_mount "$l"
        mkdir -p "$LAYER_ROOT/usr/lib/larch/layers"
        printf '%s\n' "$LARCH_VERSION" > "$LAYER_ROOT/usr/lib/larch/layers/$l"
        if is_desktop "$l"; then printf '%s\n' "$l" > "$LAYER_ROOT/usr/lib/larch/desktop"; fi
        layer_umount "$LAYER_ROOT"
        rm -rf "${LAYERS_WORK:?}/.work-$l"
    done

    check_layers
    for de in $DESKTOPS; do check_stack "$de"; done

    for l in base $DRIVERS $DESKTOPS; do
        # systemd-tmpfiles' root.conf (`z / 555`) would try to chmod the
        # read-only root at every boot; ship it with that mode already (the
        # root's attributes are the top layer's).
        chmod 555 "$LAYERS_WORK/$l"
        out="$OUT_DIR/$l.squashfs"
        rm -f "$out"
        info "[$l] mksquashfs (version $LARCH_VERSION)"
        # config/squashfs.exclude: build leftovers, /boot and the package
        # databases (see the file). The build overlay's own bookkeeping
        # xattrs stay out; its whiteouts (0/0 character devices) and opaque
        # directories (trusted.overlay.opaque) are the layer's deletions.
        mksquashfs "$LAYERS_WORK/$l" "$out" \
            -comp zstd -Xcompression-level 19 -no-progress -noappend \
            -wildcards -ef "$SYSTEM_DIR/config/squashfs.exclude" \
            -xattrs-exclude '^trusted\.overlay\.(origin|impure|nlink|upper|uuid|metacopy|redirect|protattr)$'
        info "[$l] $(basename "$out"): $(du -sh "$out" | cut -f1)"
    done
}

# ── Stage 9: sys-initramfs ───────────────────────────────────────────────────
run_stage 9 "sys-initramfs — build sys.initramfs" && {
    require_rootfs
    build_dir="$WORK_DIR/sys-initramfs"
    init_initramfs_tree "$build_dir" "$SYSTEM_DIR/initramfs/sys/init"
    # The same disk drivers (and their firmware) as the installer and the
    # updater, filesystems and a keyboard (for the rescue shell). No network:
    # systemd's udev loads everything else from the image.
    bundle_modules "$build_dir" 1 "$MODS_BASE" "$MODS_DISK" "$MODS_INPUT"
    copy_bin_with_libs e2fsck "$build_dir"
    pack_initramfs "$build_dir" "$OUT_DIR/sys.initramfs"
}

# ── Stage 10: updater-initramfs ──────────────────────────────────────────────
run_stage 10 "updater-initramfs — build updater.initramfs" && {
    require_rootfs
    build_dir="$WORK_DIR/updater-initramfs"
    init_initramfs_tree "$build_dir" "$SYSTEM_DIR/initramfs/updater/init"
    # Exactly the installer's drivers: every disk and network driver of the
    # image's kernel, with their firmware.
    bundle_modules "$build_dir" 1 "$MODS_BASE" "$MODS_DISK" "$MODS_INPUT" "$MODS_NET"
    bundle_network "$build_dir"
    bundle_dialog "$build_dir" updater
    copy_bin_with_libs e2fsck "$build_dir"
    install -m 755 "$SYSTEM_DIR/updater/update.sh" "$build_dir/usr/sbin/larch-update"
    install -m 644 "$SYSTEM_DIR/updater/manage.sh" "$build_dir/usr/lib/larch/manage.sh"
    pack_initramfs "$build_dir" "$OUT_DIR/updater.initramfs"
}

# ── Stage 11: release-files ──────────────────────────────────────────────────
run_stage 11 "release-files — vmlinuz, bootloader, entries and SHA256SUMS" && {
    require_rootfs
    VMLINUZ="$(find_vmlinuz)"
    [ -f "$VMLINUZ" ] || die "Kernel vmlinuz not found in the rootfs (/usr/lib/modules/<ver>/vmlinuz)"
    kver=$(rootfs_kver)
    install -m 644 "$VMLINUZ" "$OUT_DIR/vmlinuz"
    # systemd-boot from the base (systemd-boot-unsigned; the layers don't
    # carry it) and its config from bootloader/, as release files shared by
    # every desktop: the installer and updater put them on LARCHEFI.
    efi="$ROOTFS_DIR/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
    [ -f "$efi" ] || die "No systemd-bootx64.efi in the base rootfs (systemd-boot-unsigned in packages.list) — run stage 4"
    install -m 644 "$efi" "$OUT_DIR/BOOTX64.EFI"
    loader_dir="$WORK_DIR/loader"
    rm -rf "$loader_dir"
    install -D -m 644 "$SYSTEM_DIR/bootloader/loader.conf" "$loader_dir/loader/loader.conf"
    install -d "$loader_dir/loader/entries"
    install -m 644 "$SYSTEM_DIR/bootloader/entries/"*.conf "$loader_dir/loader/entries/"
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -cf "$OUT_DIR/loader.tar" -C "$loader_dir" loader
    files=(vmlinuz sys.initramfs updater.initramfs BOOTX64.EFI loader.tar)
    for f in sys.initramfs updater.initramfs; do
        [ -f "$OUT_DIR/$f" ] || die "$OUT_DIR/$f is missing — run stages 9-10 first"
    done
    [ -d "$LAYERS_WORK/base/usr/lib/modules/$kver" ] \
        || die "The base layer has no modules for the release's kernel $kver — rebuild it from stage 5"
    for l in base $DRIVERS $DESKTOPS; do
        [ -f "$OUT_DIR/$l.squashfs" ] || die "$OUT_DIR/$l.squashfs is missing — run stages 5-8 first"
        files+=("$l.squashfs")
    done
    # A layer not built this time (another desktop, an older layout's
    # sys-<desktop>.squashfs) may belong to another kernel.
    for f in "$OUT_DIR"/*.squashfs; do
        [ -e "$f" ] || continue
        case " ${files[*]} " in *" $(basename "$f") "*) ;; *)
            info "Removing $(basename "$f") (not part of this build)"; rm -f "$f" ;;
        esac
    done
    (cd "$OUT_DIR" && sha256sum "${files[@]}" > SHA256SUMS)
    info "Release files in $OUT_DIR (kernel $kver):"
    (cd "$OUT_DIR" && ls -lh "${files[@]}" SHA256SUMS)
}

log "System build: stages $START_STAGE-$END_STAGE complete"
