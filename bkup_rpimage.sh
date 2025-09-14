#!/bin/bash
#
# Utility script to backup Raspberry Pi's SD Card to a sparse image file
# mounted as a filesystem in a file, allowing for efficient incremental
# backups using rsync
#
# The backup is taken while the system is up, so it's a good idea to stop
# programs and services which modifies the filesystem and needed a consistant state
# of their file. 
# Especially applications which use databases needs to be stopped (and the database systems too).
#
#  So it's a smart idea to put all these stop commands in a script and perfom it before 
#  starting the backup. After the backup terminates normally you may restart all stopped
#  applications or just reboot the system. 
#
# 2025-09-14 Jools
# 		fix: use AI to reduce log spam
#		fix: use AI to ignore errors with symlinks in do_backup
#		fix: use AI to reduce the size of the sparse image in losetup
#
# 2019-04-25 Dolorosus                  
#        fix: Proper quoting of imagename. Now blanks in the imagename should be no longer 
#             a problem.
#
# 2019-03-19 Dolorosus                  
#        fix: Define colors only if connected to a terminal.
#             Thus output to file is no more cluttered.
#
# 2019-03-18 Dolorosus: 
#               add: exclusion of files below /tmp,/proc,/run,/sys and 
#                    also the swapfile /var/swap will be excluded from backup.
#               add: Bumping the version to 1.1
#
# 2019-03-17 Dolorosus: 
#               add: -s parameter to create an image of a defined size.
#               add: funtion cloneid to clone te UUID and the PTID from 
#                    the SDCARD to the image. So restore is working on 
#                    recent raspian versions.
#
#
#

VERSION=v2.0
SDCARD=/dev/mmcblk0

#!/bin/bash
#
# bkup_rpimage.sh v2.0
# Backup live root filesystem to SD-ready image
# Automatically calculates minimum image size
# Maintains bootable SD compatibility

VERSION=v2.0

setup() {
    [ -t 1 ] && {
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        RESET=$(tput sgr0)
    } || { RED=""; GREEN=""; YELLOW=""; RESET=""; }
    MYNAME=$(basename "$0")
}

trace() { echo -e "${YELLOW}$1${RESET}"; }
error() { echo -e "${RED}$1${RESET}" >&2; exit 1; }

# Detect live root device
SDCARD=$(findmnt -n -o SOURCE /)
[ -z "$SDCARD" ] && error "Failed to detect root device"

# Create sparse image with auto size
do_create() {
    trace "Calculating minimum image size..."
    ROOT_USED=$(df --output=used -B1 / | tail -n1)
    BOOT_DIR=$(findmnt -n -o TARGET /boot 2>/dev/null || echo "")
    [ -z "$BOOT_DIR" ] && BOOT_DIR=$(findmnt -n -o TARGET /boot/firmware 2>/dev/null || echo "")
    BOOT_USED=0
    [ -n "$BOOT_DIR" ] && BOOT_USED=$(df --output=used -B1 "$BOOT_DIR" | tail -n1)
    TOTAL_USED=$((ROOT_USED + BOOT_USED + 500*1024*1024)) # 500MB margin

    BLOCKSIZE=1M
    SIZE=$(( (TOTAL_USED + 1024*1024 - 1) / (1024*1024) )) # round up MB

    trace "Creating sparse image ${IMAGE} (~${SIZE} MB)"
    dd if=/dev/zero of="${IMAGE}" bs=1M count=0 seek=$SIZE || error "Failed to create image"

    LOOPBACK=$(losetup -f)
    losetup "${LOOPBACK}" "${IMAGE}" || error "Failed to attach loop device"
    parted -s "${LOOPBACK}" mklabel msdos
    sfdisk --dump "${SDCARD}" | sfdisk --force "${LOOPBACK}"
    partx --add "${LOOPBACK}"
    mkfs.vfat -I "${LOOPBACK}p1"
    mkfs.ext4 "${LOOPBACK}p2"
}

# Mount image partitions
do_mount() {
    [ -z "${LOOPBACK}" ] && LOOPBACK=$(losetup -j "${IMAGE}" | cut -d: -f1)
    [ -z "${LOOPBACK}" ] && error "No loop device for ${IMAGE}"
    [ -z "${MOUNTDIR}" ] && MOUNTDIR="/mnt/$(basename "${IMAGE}")"
    mkdir -p "${MOUNTDIR}"
    mount "${LOOPBACK}p2" "${MOUNTDIR}" || error "Failed to mount rootfs"
    mkdir -p "${MOUNTDIR}/boot"
    mount "${LOOPBACK}p1" "${MOUNTDIR}/boot" || error "Failed to mount boot"
}

# Rsync backup
do_backup() {
    trace "Starting rsync backup..."
    BOOTDIR="${MOUNTDIR}/boot"
    [ -d "${BOOTDIR}/firmware" ] && BOOTDIR="${BOOTDIR}/firmware"
    rsync -aHx --info=progress2 --exclude={'tmp/**','proc/**','run/**','sys/**','mnt/**','var/swap','home/pi/.cache/**'} /boot/ "${BOOTDIR}/" || trace "Boot rsync warnings"
    rsync -aHx --info=progress2 --exclude={'tmp/**','proc/**','run/**','sys/**','mnt/**','var/swap','home/pi/.cache/**'} / "${MOUNTDIR}/" || trace "Root rsync warnings"
}

# Update UUIDs for SD boot
update_sd_image_boot() {
    BOOTDIR="${MOUNTDIR}/boot"
    [ -d "${BOOTDIR}/firmware" ] && BOOTDIR="${BOOTDIR}/firmware"
    BOOT_UUID=$(blkid -s UUID -o value "${LOOPBACK}p1")
    ROOT_UUID=$(blkid -s UUID -o value "${LOOPBACK}p2")

    sed -i "s|UUID=[^ ]* / |UUID=${ROOT_UUID} / |" "${MOUNTDIR}/etc/fstab"
    sed -i "s|UUID=[^ ]* /boot|UUID=${BOOT_UUID} /boot|" "${MOUNTDIR}/etc/fstab"
    sed -i "s|UUID=[^ ]* /boot/firmware|UUID=${BOOT_UUID} /boot/firmware|" "${MOUNTDIR}/etc/fstab"

    [ -f "${BOOTDIR}/cmdline.txt" ] && sed -i "s|root=UUID=[^ ]*|root=UUID=${ROOT_UUID}|" "${BOOTDIR}/cmdline.txt"
}

# Unmount partitions
do_umount() {
    trace "Flushing to disk"
    sync; sync
    umount "${MOUNTDIR}/boot" 2>/dev/null
    umount "${MOUNTDIR}" 2>/dev/null
    rmdir "${MOUNTDIR}" 2>/dev/null
    partx --delete "${LOOPBACK}"
    losetup -d "${LOOPBACK}"
}

# Compress image
do_compress() {
    trace "Compressing ${IMAGE}..."
    if command -v pv >/dev/null 2>&1; then
        pv "${IMAGE}" | gzip > "${IMAGE}.gz.tmp"
    else
        gzip -c "${IMAGE}" > "${IMAGE}.gz.tmp"
    fi
    mv -f "${IMAGE}.gz.tmp" "${IMAGE}.gz"
    [ -n "${opt_delete}" ] && rm -f "${IMAGE}"
}

# Ctrl-C trap
ctrl_c() { trace "Backup interrupted"; do_umount; exit 1; }
trap ctrl_c SIGINT SIGTERM

# Parse command & options
setup
[ "$(id -u)" -ne 0 ] && error "Run as root"

case "$1" in
    start|mount|umount|gzip) opt_command=$1;;
    -h|--help) echo "$MYNAME $VERSION"; exit 0;;
    *) error "Unknown command: $1";;
esac
shift

while getopts ":czd" opt; do
    case $opt in
        c) opt_create=1;;
        z) opt_compress=1;;
        d) opt_delete=1;;
    esac
done
shift $((OPTIND-1))
IMAGE=$1
[ -z "$IMAGE" ] && error "No image specified"

MOUNTDIR=$2

# Main execution
case "$opt_command" in
    start)
        [ ! -f "$IMAGE" ] && [ -n "$opt_create" ] && do_create
        do_mount
        do_backup
        update_sd_image_boot
        do_umount
        [ -n "$opt_compress" ] && do_compress
        trace "Backup completed successfully"
        ;;
    mount)
        do_mount
        trace "Image mounted at ${MOUNTDIR:-/mnt/$(basename "${IMAGE}")}"
        ;;
    umount) do_umount;;
    gzip) do_compress;;
esac

exit 0
