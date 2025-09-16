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

VERSION=v1.3
SDCARD=/dev/mmcblk0
MOUNTDIR=""
opt_log=""
LOG=""

# Define log directory
LOGDIR="/mnt/triton/backup/rpi/logs"

# Create the directory if it doesn't exist
mkdir -p "${LOGDIR}"

# Default log file name
DEFAULT_LOG="${LOGDIR}/$(uname -n)-$(date +%Y-%m-%d).log"


setup () {
        [ -t 1 ] && {
                RED=$(tput setaf 1)
                GREEN=$(tput setaf 2)
                YELLOW=$(tput setaf 3)
                BLUE=$(tput setaf 4)
                MAGENTA=$(tput setaf 5)
                CYAN=$(tput setaf 6)
                WHITE=$(tput setaf 7)
                RESET=$(tput setaf 9)
                BOLD=$(tput bold)
                NOATT=$(tput sgr0)
        }||{
                RED=""
                GREEN=""
                YELLOW=""
                BLUE=""
                MAGENTA=""
                CYAN=""
                WHITE=""
                RESET=""
                BOLD=""
                NOATT=""
        }
        MYNAME=$(basename $0)
}

trace () {
    echo -e "${YELLOW}${1}${NOATT}"
}

info () {
    echo -e "${GREEN}${1}${NOATT}"
}

error () {
    echo -e "${RED}${1}${NOATT}" >&2
    exit 1
}

do_create () {
    trace "Creating sparse image ${IMAGE} (~$((TOTAL_USED/1024/1024)) MB)"
    dd if=/dev/zero of="${IMAGE}" bs=${BLOCKSIZE} count=0 seek=${SIZE}

    if [ -s "${IMAGE}" ]; then
        trace "Attaching "${IMAGE}" to ${LOOPBACK}"
        losetup ${LOOPBACK} "${IMAGE}"
    else
        error "${IMAGE} was not created or has zero size"
    fi

    trace "Copying partition table from ${SDCARD} to ${LOOPBACK}"
    parted -s ${LOOPBACK} mklabel msdos
    sfdisk --dump ${SDCARD} | sfdisk --force ${LOOPBACK}

    trace "Formatting partitions"
    partx --add ${LOOPBACK}
    mkfs.vfat -I ${LOOPBACK}p1
    mkfs.ext4 ${LOOPBACK}p2
	clone
}

do_cloneid () {
    if [ $(losetup -f) = ${LOOPBACK} ]; then
        trace "Attaching ${IMAGE} to ${LOOPBACK}"
        losetup ${LOOPBACK} "${IMAGE}"
        partx --add ${LOOPBACK}
    fi
    clone
    partx --delete ${LOOPBACK}
    losetup -d ${LOOPBACK}
}

clone () {
    UUID=$(blkid -s UUID -o value ${SDCARD}p2)
    PTUUID=$(blkid -s PTUUID -o value ${SDCARD})
    e2fsck -f -y ${LOOPBACK}p2
    echo y|tune2fs ${LOOPBACK}p2 -U $UUID
    printf 'p\nx\ni\n%s\nr\np\nw\n' 0x${PTUUID}|fdisk "${LOOPBACK}"
    sync
}

do_mount () {
    if [ $(losetup -f) = ${LOOPBACK} ]; then
        trace "Attaching ${IMAGE} to ${LOOPBACK}"
        losetup ${LOOPBACK} "${IMAGE}"
        partx --add ${LOOPBACK}
    fi

    trace "Mounting ${LOOPBACK}1 and ${LOOPBACK}2 to ${MOUNTDIR}"
    if [ ! -n "${opt_mountdir}" ]; then
        mkdir ${MOUNTDIR}
    fi
    mount ${LOOPBACK}p2 ${MOUNTDIR}
    mkdir -p ${MOUNTDIR}/boot
    mount ${LOOPBACK}p1 ${MOUNTDIR}/boot
}

do_backup () {
    if mountpoint -q "${MOUNTDIR}"; then
        START_TIME=$(date +%s)
        echo "Starting rsync backup of / and /boot/ to ${MOUNTDIR}" | tee -a "${LOG}"

        # Console rsync options (show progress)
        RSYNC_CONSOLE_OPTS="-aHAXx --delete --info=progress2"

        # Log rsync options (summary only)
        RSYNC_LOG_OPTS="-aHAXx --delete --stats"
        [ -n "${opt_log}" ] && RSYNC_LOG_OPTS+=" --log-file=${LOG}"

        # Backup /boot
        if [ -n "${opt_log}" ]; then
            rsync ${RSYNC_CONSOLE_OPTS} /boot/ "${MOUNTDIR}/boot/" 2> >(grep -v "Operation not permitted" >&2)
            rsync ${RSYNC_LOG_OPTS} /boot/ "${MOUNTDIR}/boot/" 2> >(grep -v "Operation not permitted" >&2)
        else
            rsync ${RSYNC_CONSOLE_OPTS} /boot/ "${MOUNTDIR}/boot/" 2> >(grep -v "Operation not permitted" >&2)
        fi

        # Backup root filesystem
        EXCLUDES="--exclude=/boot/* --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found"
        if [ -n "${opt_log}" ]; then
            rsync ${RSYNC_CONSOLE_OPTS} ${EXCLUDES} / "${MOUNTDIR}/" 2> >(grep -v "Operation not permitted" >&2)
            rsync ${RSYNC_LOG_OPTS} ${EXCLUDES} / "${MOUNTDIR}/" 2> >(grep -v "Operation not permitted" >&2)
        else
            rsync ${RSYNC_CONSOLE_OPTS} ${EXCLUDES} / "${MOUNTDIR}/" 2> >(grep -v "Operation not permitted" >&2)
        fi

        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SUMMARY="Backup completed: ${MOUNTDIR}
Duration: $((DURATION/3600))h $(((DURATION/60)%60))m $((DURATION%60))s"

        # Output summary to screen and log
        echo -e "${SUMMARY}" | tee -a "${LOG}"

    else
        echo "Skipping rsync: ${MOUNTDIR} not mounted" | tee -a "${LOG}"
    fi
}

do_showdf () {
    echo -n "${CYAN}"
    df -m ${LOOPBACK}p1 ${LOOPBACK}p2
    echo -n "$NOATT"
}

do_umount () {
    trace "Flushing to disk"
    sync; sync

    trace "Unmounting ${LOOPBACK}1 and ${LOOPBACK}2 from ${MOUNTDIR}"
    umount ${MOUNTDIR}/boot
    umount ${MOUNTDIR}
    if [ ! -n "${opt_mountdir}" ]; then
        rmdir ${MOUNTDIR}
    fi

    trace "Detaching ${IMAGE} from ${LOOPBACK}"
    partx --delete ${LOOPBACK}
    losetup -d ${LOOPBACK}
}

do_compress () {
    trace "Compressing ${IMAGE} to ${IMAGE}.gz"
    pv -tpreb "${IMAGE}" | gzip > "${IMAGE}.gz.tmp"
    if [ -s "${IMAGE}.gz.tmp" ]; then
        mv -f "${IMAGE}.gz.tmp" "${IMAGE}.gz"
        if [ -n "${opt_delete}" ]; then
            rm -f "${IMAGE}"
        fi
    fi
}

ctrl_c () {
    trace "Ctrl-C detected."

    if [ -s "${IMAGE}.gz.tmp" ]; then
        rm "${IMAGE}.gz.tmp"
    else
        do_umount
    fi

    if [ -n "${opt_log}" ]; then
        trace "See rsync log in ${LOG}"
    fi

    error "SD Image backup process interrupted"
}

usage () {
    echo -e ""
    echo -e "${MYNAME} ${VERSION} by jinx"
    echo -e ""
    echo -e "Usage:"
    echo -e ""
    echo -e "    ${MYNAME} ${BOLD}start${NOATT} [-clzdf] [-L logfile] [-i sdcard] sdimage"
    echo -e "    ${MYNAME} ${BOLD}mount${NOATT} [-c] sdimage [mountdir]"
    echo -e "    ${MYNAME} ${BOLD}umount${NOATT} sdimage [mountdir]"
    echo -e "    ${MYNAME} ${BOLD}gzip${NOATT} [-df] sdimage"
    echo -e ""
    echo -e "    Commands:"
    echo -e ""
    echo -e "        ${BOLD}start${NOATT}      starts complete backup of RPi's SD Card to 'sdimage'"
    echo -e "        ${BOLD}mount${NOATT}      mounts the 'sdimage' to 'mountdir' (default: /mnt/'sdimage'/)"
    echo -e "        ${BOLD}umount${NOATT}     unmounts the 'sdimage' from 'mountdir'"
    echo -e "        ${BOLD}gzip${NOATT}       compresses the 'sdimage' to 'sdimage'.gz"
    echo -e "        ${BOLD}cloneid${NOATT}    clones the UUID/PTUUID from the actual disk to the image"
    echo -e "        ${BOLD}shodf${NOATT}      shows allocation of the image"
    echo -e ""
    echo -e "    Options:"
    echo -e ""
    echo -e "        ${BOLD}-c${NOATT}         creates the SD Image if it does not exist"
    echo -e "        ${BOLD}-l${NOATT}         writes rsync log to 'sdimage'-YYYY-MM-DD.log"
    echo -e "        ${BOLD}-z${NOATT}         compresses the SD Image (after backup) to 'sdimage'.gz"
    echo -e "        ${BOLD}-d${NOATT}         deletes the SD Image after successful compression"
    echo -e "        ${BOLD}-f${NOATT}         forces overwrite of 'sdimage'.gz if it exists"
    echo -e "        ${BOLD}-L logfile${NOATT} writes rsync log to 'logfile'"
    echo -e "        ${BOLD}-i sdcard${NOATT}  specifies the SD Card location (default: $SDCARD)"
    echo -e "        ${BOLD}-s Mb${NOATT}      specifies the size of image in MB (default: Size of $SDCARD)"
    echo -e ""
    echo -e "Examples:"
    echo -e ""
    echo -e "    ${MYNAME} start -c /path/to/rpi_backup.img"
    echo -e "        starts backup to 'rpi_backup.img', creating it if it does not exist"
    echo -e ""
    echo -e "    ${MYNAME} start -c -s 8000 /path/to/rpi_backup.img"
    echo -e "        starts backup to 'rpi_backup.img', creating it"
    echo -e "        with a size of 8000mb if it does not exist"
    echo -e ""
    echo -e "    ${MYNAME} start /path/to/\$(uname -n).img"
    echo -e "        uses the RPi's hostname as the SD Image filename"
    echo -e ""
    echo -e "    ${MYNAME} start -cz /path/to/\$(uname -n)-\$(date +%Y-%m-%d).img"
    echo -e "        uses the RPi's hostname and today's date as the SD Image filename,"
    echo -e "        creating it if it does not exist, and compressing it after backup"
    echo -e ""
    echo -e "    ${MYNAME} mount /path/to/\$(uname -n).img /mnt/rpi_image"
    echo -e "        mounts the RPi's SD Image in /mnt/rpi_image"
    echo -e ""
    echo -e "    ${MYNAME} umount /path/to/raspi-$(date +%Y-%m-%d).img"
    echo -e "        unmounts the SD Image from default mountdir (/mnt/raspi-$(date +%Y-%m-%d).img/)"
    echo -e ""
}

setup

case ${1} in
    start|mount|umount|gzip|cloneid|showdf)
        opt_command=${1}
        ;;
    -h|--help)
        usage; exit 0;;
    --version)
        trace "${MYNAME} ${VERSION} by jinx"; exit 0;;
    *)
        error "Invalid command or option: ${1}\nSee '${MYNAME} --help' for usage";;
esac
shift 1

if [ $(id -u) -ne 0 ]; then
    error "Please run as root. Try sudo."
fi

SIZE=$(blockdev --getsz $SDCARD)
BLOCKSIZE=$(blockdev --getss $SDCARD)

while getopts ":czdflL:i:s:" opt; do
    case ${opt} in
        c)  opt_create=1;;
        z)  opt_compress=1;;
        d)  opt_delete=1;;
        f)  opt_force=1;;
        l)
            # -l without argument → use default log
            opt_log=1
            LOG="${DEFAULT_LOG}"
            ;;
        L)
            # -L logfile → use specified logfile
            opt_log=1
            LOG="$OPTARG"
            ;;
        i)  SDCARD=${OPTARG};;
        s)  SIZE=${OPTARG}
            BLOCKSIZE=1M ;;
        \?) error "Invalid option: -${OPTARG}\nSee '${MYNAME} --help' for usage";;
        :)  error "Option -${OPTARG} requires an argument\nSee '${MYNAME} --help' for usage";;
    esac
done

shift $((OPTIND-1))

IMAGE=${1}
[ -z "${IMAGE}" ] && error "No sdimage specified"

if [ ${opt_command} = umount ] || [ ${opt_command} = gzip ]; then
    [ ! -f "${IMAGE}" ] && error "${IMAGE} does not exist"
else
    [ ! -f "${IMAGE}" ] && [ -z "${opt_create}" ] && error "${IMAGE} does not exist\nUse -c to allow creation"
fi

if [ -n "${opt_compress}" ] || [ ${opt_command} = gzip ]; then
    [ -s "${IMAGE}".gz ] && [ -z "${opt_force}" ] && error "${IMAGE}.gz already exists\nUse -f to force overwriting"
fi

if [ -n "${opt_log}" ] && [ -z "${LOG}" ]; then
    LOG="${IMAGE}-$(date +%F).log"
fi

LOOPBACK=$(losetup -j "${IMAGE}" | grep -o ^[^:]*)
if [ ${opt_command} = umount ]; then
    [ -z ${LOOPBACK} ] && error "No /dev/loop<X> attached to ${IMAGE}"
elif [ ! -z ${LOOPBACK} ]; then
    error "${IMAGE} already attached to ${LOOPBACK} mounted on $(grep ${LOOPBACK}p2 /etc/mtab | cut -d ' ' -f 2)/"
else
    LOOPBACK=$(losetup -f)
fi

MOUNTDIR=${2}
if [ -z ${MOUNTDIR} ]; then
    MOUNTDIR=/mnt/$(basename "${IMAGE}")/
else
    opt_mountdir=1
    [ ! -d ${MOUNTDIR} ] && error "Mount point ${MOUNTDIR} does not exist"
fi

if [ ${opt_command} = umount ]; then
    [ ! -d ${MOUNTDIR} ] && error "Default mount point ${MOUNTDIR} does not exist"
else
    [ -z "${opt_mountdir}" ] && [ -d ${MOUNTDIR} ] && error "Default mount point ${MOUNTDIR} already exists"
fi

trap ctrl_c SIGINT SIGTERM

for c in dd losetup parted sfdisk partx mkfs.vfat mkfs.ext4 mountpoint rsync; do
    command -v ${c} >/dev/null 2>&1 || error "Required program ${c} is not installed"
done
if [ -n "${opt_compress}" ] || [ ${opt_command} = gzip ]; then
    for c in pv gzip; do
        command -v ${c} >/dev/null 2>&1 || error "Required program ${c} is not installed"
    done
fi

case ${opt_command} in
    start)
            trace "Starting SD Image backup process"
            start_time=$(date +%s)
            if [ ! -f "${IMAGE}" ] && [ -n "${opt_create}" ]; then
                do_create
            fi
            do_mount
            do_backup
            do_showdf
            do_umount
            if [ -n "${opt_compress}" ]; then
                do_compress
            fi
            end_time=$(date +%s)
            duration=$(( end_time - start_time ))
            info "Backup completed: ${IMAGE}"
            info "Backup took $((duration / 60)) minutes and $((duration % 60)) seconds"
            if [ -n "${opt_log}" ]; then
                info "See rsync log in ${LOG}"
            fi
            ;;
    mount)
            if [ ! -f "${IMAGE}" ] && [ -n "${opt_create}" ]; then
                do_create
            fi
            do_mount
            trace "SD Image has been mounted and can be accessed at:\n    ${MOUNTDIR}"
            ;;
    umount)
            do_umount
            ;;
    gzip)
            do_compress
            ;;
    cloneid)
            do_cloneid
            ;;
    showdf)
            do_mount
            do_showdf
            do_umount
            ;;
    *)
            error "Unknown command: ${opt_command}"
            ;;
esac

exit 0
