#!/bin/bash

###############################################################################
#
# Copyright 2023 NVIDIA Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
###############################################################################

PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/mellanox/scripts"
CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

rshimlog=$(which bfrshlog 2> /dev/null)
distro="Ubuntu"
NIC_FW_UPDATE_DONE=0
NIC_FW_RESET_REQUIRED=0
RC=0
err_msg=""

logfile=${distro}.installation.log
LOG=/tmp/$logfile

fspath=$(readlink -f "$(dirname $0)")

log()
{
	msg="[$(date +%H:%M:%S)] $*"
	echo "$msg" > /dev/ttyAMA0
	echo "$msg" > /dev/hvc0
	if [ -n "$rshimlog" ]; then
		$rshimlog "$*"
	fi
	echo "$msg" >> $LOG
}

ilog()
{
	msg="[$(date +%H:%M:%S)] $*"
	echo "$msg" >> $LOG
	echo "$msg"
}

save_log()
{
cat >> $LOG << EOF

########################## DMESG ##########################
$(dmesg -x)
EOF
	sync
	if [ ! -d /mnt/root ]; then
		mount -t $ROOTFS $ROOT_PARTITION /mnt
	fi
	cp $LOG /mnt/root
	umount /mnt
}

fw_update()
{
	FW_UPDATER=/opt/mellanox/mlnx-fw-updater/mlnx_fw_updater.pl
	FW_DIR=/opt/mellanox/mlnx-fw-updater/firmware/

	if [[ -x /mnt/${FW_UPDATER} && -d /mnt/${FW_DIR} ]]; then
		log "INFO: Updating NIC firmware..."
		chroot /mnt ${FW_UPDATER} --log /tmp/mlnx_fw_update.log -v \
			--force-fw-update \
			--fw-dir ${FW_DIR}
		rc=$?
		sync
		if [ -e /tmp/mlnx_fw_update.log ]; then
			cat /tmp/mlnx_fw_update.log >> $LOG
		fi
		if [ $rc -eq 0 ]; then
			log "INFO: NIC firmware update done"
		else
			log "INFO: NIC firmware update failed"
		fi
	else
		log "WARNING: NIC Firmware files were not found"
	fi
}

fw_reset()
{
	ilog "Running mlnx_bf_configure:"
	ilog "$(chroot /mnt /sbin/mlnx_bf_configure)"

	MLXFWRESET_TIMEOUT=${MLXFWRESET_TIMEOUT:-180}
	SECONDS=0
	while ! (chroot /mnt mlxfwreset -d /dev/mst/mt*_pciconf0 q 2>&1 | grep -w "Driver is the owner" | grep -qw "\-Supported")
	do
		if [ $SECONDS -gt $MLXFWRESET_TIMEOUT ]; then
			log "INFO: NIC Firmware reset is not supported. Host power cycle is required"
			return
		fi
		sleep 1
	done

	log "INFO: Running NIC Firmware reset"
	save_log
	if [ "X$mode" == "Xmanufacturing" ]; then
		log "INFO: Rebooting..."
	fi
	# Wait for these messages to be pulled by the rshim service
	# as mlxfwreset will restart the DPU
	sleep 3

	msg=$(chroot /mnt mlxfwreset -d /dev/mst/mt*_pciconf0 -y -l 3 --sync 1 r 2>&1)
	if [ $? -ne 0 ]; then
		log "INFO: NIC Firmware reset failed"
		log "INFO: $msg"
	else
		log "INFO: NIC Firmware reset done"
	fi
}

#
# Set the Hardware Clock from the System Clock
#

hwclock -w

#
# Check auto configuration passed from boot-fifo
#
boot_fifo_path="/sys/bus/platform/devices/MLNXBF04:00/bootfifo"
if [ -e "${boot_fifo_path}" ]; then
	cfg_file=$(mktemp)
	# Get 16KB assuming it's big enough to hold the config file.
	dd if=${boot_fifo_path} of=${cfg_file} bs=4096 count=4 > /dev/null 2>&1

	#
	# Check the .xz signature {0xFD, '7', 'z', 'X', 'Z', 0x00} and extract the
	# config file from it. Then start decompression in the background.
	#
	offset=$(strings -a -t d ${cfg_file} | grep -m 1 "7zXZ" | awk '{print $1}')
	if [ -s "${cfg_file}" -a ."${offset}" != ."1" ]; then
		log "INFO: Found bf.cfg"
		cat ${cfg_file} | tr -d '\0' > /etc/bf.cfg
		cat >> $LOG << EOF

############ bf.cfg ###############
$(cat /etc/bf.cfg)
########## END of bf.cfg ##########
EOF
	fi
	rm -f $cfg_file
fi

ilog "Starting mst:"
ilog "$(mst start)"

cat >> $LOG << EOF

############ DEBUG INFO (pre-install) ###############
KERNEL: $(uname -r)

LSMOD:
$(lsmod)

NETWORK:
$(ip addr show)

CMDLINE:
$(cat /proc/cmdline)

PARTED:
$(parted -l -s)

LSPCI:
$(lspci)

NIC FW INFO:
$(flint -d /dev/mst/mt*_pciconf0 q)

MLXCONFIG:
$(mlxconfig -d /dev/mst/mt*_pciconf0 -e q)
########### DEBUG INFO END ############

EOF

#
# Check PXE installation
#
if [ ! -e /tmp/bfpxe.done ]; then touch /tmp/bfpxe.done; bfpxe; fi

DUAL_BOOT="no"
if [ -e /etc/bf.cfg ]; then
	if ( bash -n /etc/bf.cfg ); then
		. /etc/bf.cfg
	else
		log "INFO: Invalid bf.cfg"
	fi
fi

if [ "X${DEBUG}" == "Xyes" ]; then
	log_output=/dev/kmsg
	if [ -n "$log_output" ]; then
		exec >$log_output 2>&1
		unset log_output
	fi
fi

function_exists()
{
	declare -f -F "$1" > /dev/null
	return $?
}

ROOTFS=${ROOTFS:-"ext4"}
DHCP_CLASS_ID=${PXE_DHCP_CLASS_ID:-""}
DHCP_CLASS_ID_OOB=${DHCP_CLASS_ID_OOB:-"NVIDIA/BF/OOB"}
DHCP_CLASS_ID_DP=${DHCP_CLASS_ID_DP:-"NVIDIA/BF/DP"}
FACTORY_DEFAULT_DHCP_BEHAVIOR=${FACTORY_DEFAULT_DHCP_BEHAVIOR:-"true"}

if [ "${FACTORY_DEFAULT_DHCP_BEHAVIOR}" == "true" ]; then
	# Set factory defaults
	DHCP_CLASS_ID="NVIDIA/BF/PXE"
	DHCP_CLASS_ID_OOB="NVIDIA/BF/OOB"
	DHCP_CLASS_ID_DP="NVIDIA/BF/DP"
fi

log "INFO: $distro installation started"

default_device=/dev/mmcblk0
if [ -b /dev/nvme0n1 ]; then
	default_device="/dev/$(cd /sys/block; /bin/ls -1d nvme* | sort -n | tail -1)"
fi
device=${device:-"$default_device"}

ilog "OS installation target: $device"
echo 0 > /proc/sys/kernel/hung_task_timeout_secs

# We cannot use wait-for-root as it expects the device to contain a
# known filesystem, which might not be the case here.
while [ ! -b $device ]; do
    log "Waiting for $device to be ready\n"
    sleep 1
done

DF=$(which df 2> /dev/null)
if [ -n "$DF" ]; then
	current_root=$(df --output=source / 2> /dev/null | tail -1)
fi

if [ -z "$current_root" ]; then
	current_root="rootfs"
fi

mode="manufacturing"

NEXT_OS_IMAGE=0
if [ "X$current_root" == "X${device}p2" ]; then
    mode="upgrade"
    NEXT_OS_IMAGE=1
    DUAL_BOOT="yes"
elif [ "X$current_root" == "X${device}p4" ]; then
    mode="upgrade"
    NEXT_OS_IMAGE=0
    DUAL_BOOT="yes"
elif [ "X$current_root" == "Xrootfs" ]; then
    mode="manufacturing"
else
    printf "ERROR: unsupported partition scheme\n"
    exit 1
fi

# Flash image
if [ "X$mode" == "Xmanufacturing" ]; then

	log "INFO: destroying partition table via dd zero"
	dd if=/dev/zero of="$device" bs="$bs" count=1

fi # manufacturing mode

bind_partitions()
{
	mount --bind /proc /mnt/proc
	mount --bind /dev /mnt/dev
	mount --bind /sys /mnt/sys
	mount -t efivarfs none /mnt/sys/firmware/efi/efivars
}

unmount_partitions()
{
	umount /mnt/sys/fs/fuse/connections > /dev/null 2>&1 || true
	umount /mnt/sys/firmware/efi/efivars 2>&1 || true
	umount /mnt/sys > /dev/null 2>&1
	umount /mnt/dev > /dev/null 2>&1
	umount /mnt/proc > /dev/null 2>&1
	umount /mnt/boot/efi > /dev/null 2>&1
	umount /mnt > /dev/null 2>&1
}

install_os_image()
{
	log "check who mounts efivars - head of install_os_image"
	log "$(mount | grep efivars)"
	OS_IMAGE=$1
	if [ "X$DUAL_BOOT" == "Xyes" ]; then
		if [ $OS_IMAGE -eq 0 ]; then
			log "Installing first OS image"
		else
			log "Installing second OS image"
		fi
	else
		log "Installing OS image"
	fi

	ilog "Extracting /..."
	export EXTRACT_UNSAFE_SYMLINKS=1
	# put UC22 here
	log "cat core image to $device"
	ilog "cat core image to $device"
	log "more debugging info below..."
	log "where am I: $(pwd)"
	log "echo fspath: $(echo $fspath)"
	log "ls fspath: $(ls $fspath)"
	log "ls fspath image: $(ls $fspath/image.tar.xz)"
	log "ls: $(ls)"
	log "ls ubuntu: $(ls ./ubuntu)"
	log "ls /: $(ls /)"
	log "going to cat ..."
	flash_log="/tmp/cat_uc22.log"
	# execute the cat command for writting the core image to the device
	log "check who mounts efivars - on writing uc22"
	log "$(mount | grep efivars)"
	xzcat $fspath/ubuntu-core-22-arm64.img.xz | dd of="$device" bs=32M status=progress > ${flash_log} 2>&1
	sync
	# Refresh partition table
	log "check who mounts efivars - on refreshing partition table"
	log "$(mount | grep efivars)"
	blockdev --rereadpt "$device" >> ${flash_log} 2>&1
	log "check who mounts efivars - after refreshing partition table"
	log "$(mount | grep efivars)"

	log "Remove old boot entries"
	log "$(bfbootmgr --cleanall)"
	/bin/rm -f /sys/firmware/efi/efivars/Boot* > /dev/null 2>&1
	/bin/rm -f /sys/firmware/efi/efivars/dump-* > /dev/null 2>&1

	if efibootmgr | grep ubuntu; then
		efibootmgr -b "$(efibootmgr | grep ubuntu | cut -c 5-8)" -B
	fi
	efibootmgr -c -d "$device" -p 1 -L ubuntu -l "\EFI\boot\grubaa64.efi"

	log "cat log if any stderr:"
	while IFS= read -r line; do
			log "$line"
	done < ${flash_log}
	log "cat log if any stderr: done"
	log "cat core image to $device : done"
	ilog "cat core image to $device : done"

	if function_exists bfb_modify_os; then
		log "INFO: Running bfb_modify_os from bf.cfg"
		bfb_modify_os
	fi

	sync

	unmount_partitions
}

if [ ! -d /sys/firmware/efi/efivars ]; then
	mount -t efivarfs none /sys/firmware/efi/efivars
fi

ilog "Remove old boot entries"
ilog "$(bfbootmgr --cleanall)"
/bin/rm -f /sys/firmware/efi/efivars/Boot* > /dev/null 2>&1
/bin/rm -f /sys/firmware/efi/efivars/dump-* > /dev/null 2>&1

if function_exists bfb_pre_install; then
	log "INFO: Running bfb_pre_install from bf.cfg"
	bfb_pre_install
fi

if function_exists custom_install_os_image; then
	log "INFO: Running custom_install_os_image from bf.cfg"
	custom_install_os_image
else
	if [ "X$mode" == "Xmanufacturing" ]; then
		if [ "X$DUAL_BOOT" == "Xyes" ]; then
			# Format common partition
			mkfs.${ROOTFS} -F ${device}p5 -L "common"
			for OS_IMAGE in 0 1
			do
				install_os_image $OS_IMAGE
			done # OS_IMAGE
		else
			install_os_image 0
		fi
	else
		install_os_image $NEXT_OS_IMAGE
	fi
fi

sleep 1
blockdev --rereadpt ${device} > /dev/null 2>&1

sync

ilog "Updating ATF/UEFI:"
ilog "$(bfrec --bootctl || true)"
if [ -e /lib/firmware/mellanox/boot/capsule/boot_update2.cap ]; then
	ilog "$(bfrec --capsule /lib/firmware/mellanox/boot/capsule/boot_update2.cap)"
fi

if [ -e /lib/firmware/mellanox/boot/capsule/efi_sbkeysync.cap ]; then
	ilog "$(bfrec --capsule /lib/firmware/mellanox/boot/capsule/efi_sbkeysync.cap)"
fi

if function_exists bfb_post_install; then
	log "INFO: Running bfb_post_install from bf.cfg"
	bfb_post_install
fi

log "INFO: Installation finished"

save_log
if [ "X$mode" == "Xmanufacturing" ]; then
	sleep 3
	log "INFO: Rebooting..."
	# Wait for these messages to be pulled by the rshim service
	sleep 3
fi
