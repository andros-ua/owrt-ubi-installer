#!/bin/sh

. /lib/upgrade/nand.sh

BOARD_NAME="creatlentem_clt-r30b1"

# LED state conventions:
#   lime  (red+green on)  = install complete, about to reboot
#   green (fast blink)    = install in progress
#   red   (slow blink)    = fatal error, system will panic after 5s

led_lime() {
	echo none > /sys/class/leds/red:status/trigger
	echo none > /sys/class/leds/green:status/trigger
	echo 255 > /sys/class/leds/red:status/brightness
	echo 255 > /sys/class/leds/green:status/brightness
}

led_green() {
	echo none > /sys/class/leds/red:status/trigger
	echo 0 > /sys/class/leds/red:status/brightness
	echo 0 > /sys/class/leds/green:status/brightness
	echo timer > /sys/class/leds/green:status/trigger
	echo 1 > /sys/class/leds/green:status/delay_on
	echo 70 > /sys/class/leds/green:status/delay_off
}

led_red() {
	echo none > /sys/class/leds/green:status/trigger
	echo 0 > /sys/class/leds/green:status/brightness
	echo 0 > /sys/class/leds/red:status/brightness
	echo timer > /sys/class/leds/red:status/trigger
	echo 120 > /sys/class/leds/red:status/delay_on
	echo 200 > /sys/class/leds/red:status/delay_off
}

# All installer messages go to the kernel ring buffer so they appear in both
# the live console and the dmesg.log saved to the boot_backup UBI volume.
log () {
	echo "INSTALLER: $@" > /dev/kmsg
}

# On unrecoverable error: signal failure via LED, wait for the message to be
# visible to anyone watching serial, then panic the kernel. A kernel panic is
# intentional here — it produces a crash dump and prevents the board from
# silently booting into a half-installed state.
trigger_crash() {
	led_red
	sleep 5
	log "$@"
	echo c > /proc/sysrq-trigger
}

led_green

sleep 1

echo
log OpenWrt UBI installer
echo

INSTALLER_DIR="/installer"
PRELOADER="$INSTALLER_DIR/mt7981-spim-nand-ubi-ddr3-1866-bl2.img"
FIP="$INSTALLER_DIR/mt7981_${BOARD_NAME}-u-boot.fip"
# Use ls to resolve the wildcard at runtime so the script does not need to
# hardcode the OpenWrt build version string in the filename.
RECOVERY="$(ls -1 $INSTALLER_DIR/openwrt-*mediatek-filogic-${BOARD_NAME}-ubi-initramfs-recovery.itb)"

# These flags allow selectively skipping volume creation.
HAS_ENV=1
HAS_FIP=1
HAS_FACTORY=1
# The backup volume takes storage space - make it optional
HAS_BACKUP=1

if [ ! -s "$PRELOADER" ] || [ ! -s "$FIP" ] || [ ! -s "$RECOVERY" ]; then
	trigger_crash "Missing files. Aborting."
fi

# UBI device nodes are not created by udev in the installer initramfs, so we
# create them manually from the sysfs uevent attributes after each attach/mkvol.
ubi_mknod() {
	local dev="$1"
	dev="${dev##*/}"
	[ -e "/sys/class/ubi/$dev/uevent" ] || return 2
	. "/sys/class/ubi/$dev/uevent"
	mknod "/dev/$dev" c $MAJOR $MINOR
}

# Locate the Wi-Fi EEPROM (factory) data on a raw MTD device by scanning for
# a known magic value. The EEPROM may not start at a fixed offset due to
# vendor-specific partition layouts, so we scan up to 4 erase blocks from the
# expected starting offset. The found block is extracted to /tmp/factory for
# later storage in a dedicated UBI volume.
install_get_factory() {
	local mtddev="$1"
	local ebs=$(cat /sys/class/mtd/$(basename $mtddev)/erasesize)
	local assertm="$3"
	local init_off="$2"
	local off=$init_off
	local skip="$((init_off / ebs))"
	local found
	local magic

	while [ $((off)) -lt $((init_off + 4 * ebs)) ]; do
		magic="$(hexdump -v -s $off -n 2 -e '"%02x"' $mtddev)"
		if [ "$magic" = "$assertm" ]; then
			found=1
			break
		fi
		off=$((off + ebs))
		skip=$((skip + 1))
	done

	if [ "$found" != "1" ]; then
		log "factory partition not found on raw flash offset"
		return 1
	fi

	log "found factory partition at offset $(printf %08x $((off)))"

	dd if=$mtddev bs=$ebs skip=$skip count=1 of=/tmp/factory
}

# Back up raw MTD regions before we erase anything. These are preserved in the
# boot_backup UBI volume so the original bootloader and calibration data can be
# recovered if the install goes wrong.
install_prepare_mtd_backup() {
	log "preparing backup of the $2 from mtd$1 ${3:+using $3 blocks} ${4:+after skipping first $4 blocks}"
	local mtdnum=$1
	local ebs=$(cat /sys/class/mtd/mtd${mtdnum}/erasesize)
	dd bs=$ebs if=/dev/mtd${mtdnum} of=/tmp/backup/$2.bin ${3:+count=$3} ${4:+skip=$4}
}

# Write all pre-install backups and the full dmesg (which includes all installer
# log messages) into a dedicated UBI volume. This volume survives the install
# and is the primary diagnostic resource if something goes wrong post-flash.
install_write_backup() {
	log "writing backup files to ubi volume..."
	ubimkvol /dev/ubi0 -n 6 -s 5MiB -N boot_backup
	ubi_mknod ubi0_6
	mount -t ubifs /dev/ubi0_6 /mnt
	cp /tmp/backup/* /mnt
	log "Done."
	dmesg > /mnt/dmesg.log
	umount /mnt
}

# Format the UBI partition and populate the fixed-layout volumes expected by
# the OpenWrt U-Boot port for this board:
#   vol 0  fip       - BL31 + U-Boot FIP image (static)
#   vol 1  factory   - Wi-Fi EEPROM / calibration data (static)
#   vol 2  ubootenv  - primary U-Boot environment store
#   vol 3  ubootenv2 - redundant U-Boot environment store
# Volumes 4 (recovery), 5 (fit), and 6 (boot_backup) are written separately.
install_prepare_ubi() {
	log "preparing UBI on $1"
	local mtddev=$1
	[ -e /sys/class/ubi/ubi0 ] && ubidetach -p $mtddev
	ubiformat -y $mtddev
	sleep 1
	ubiattach -p $mtddev
	sync
	sleep 1
	[ -e /dev/ubi0 ] || ubi_mknod ubi0
	[ "$HAS_FIP" = "1" ] && ubimkvol /dev/ubi0 -n 0 -t static -s $(du -b $FIP | awk '{print $1}') -N fip && \
		ubi_mknod ubi0_0 && ubiupdatevol /dev/ubi0_0 "$FIP"
	[ "$HAS_FACTORY" = "1" ] && ubimkvol /dev/ubi0 -n 1 -t static -s $(du -b "/tmp/factory" | awk '{print $1}') -N factory && \
		ubi_mknod ubi0_1 && ubiupdatevol /dev/ubi0_1 "/tmp/factory"
	[ "$HAS_ENV" = "1" ] && ubimkvol /dev/ubi0 -n 2 -s 126976 -N ubootenv && ubimkvol /dev/ubi0 -n 3 -s 126976 -N ubootenv2
}

log "backing up BL2, Factory, FIP from mtd0, mtd1 before erase"
mkdir -p /tmp/backup

# mtd0 = BL2 (full partition)
# mtd1 layout at 128k erase blocks:
#   blocks 0-3    (0x000000-0x07ffff): U-Boot environment
#   blocks 4-19   (0x080000-0x17ffff): Factory / Wi-Fi EEPROM
#   blocks 20-35  (0x180000-0x27ffff): FIP (BL31 + U-Boot)
if [ "$HAS_BACKUP" = "1" ]; then
	install_prepare_mtd_backup 0 BL2
	install_prepare_mtd_backup 1 u-boot-env 4
	install_prepare_mtd_backup 1 Factory 16 4
	install_prepare_mtd_backup 1 FIP 16 20
fi


# Extract Wi-Fi calibration data before erasing mtd1. Loss of this data
# requires physical access to restore and will break wireless permanently.
install_get_factory /dev/mtd1 0x80000 "7981" || trigger_crash "cannot find Wi-Fi EEPROM data"

# BL2 is written to two offsets for redundancy; the SoC ROM tries the second
# copy if the first fails its integrity check.
for bl2start in 0x0 0x80000 ; do
	log "write bl2 at offset $bl2start"
	mtd -p $bl2start write $PRELOADER /dev/mtd0 || \
	log "bl2 write to mtd0 at offset $bl2start failed"
done

# mtd1 holds everything above BL2: env, factory, FIP, and the UBI partition.
# This call erases and reformats it entirely.
install_prepare_ubi /dev/mtd1

log "write recovery ubi volume"
RECOVERY_SIZE=$(du -b $RECOVERY | awk '{print $1}')
ubimkvol /dev/ubi0 -n 4 -s $RECOVERY_SIZE -N recovery
ubi_mknod ubi0_4
ubiupdatevol /dev/ubi0_4 $RECOVERY

# Reserve a minimal dynamic volume for the production FIT image. It will be
# populated on first boot by the sysupgrade or TFTP flow in U-Boot.
log "create fit ubi volume"
ubimkvol /dev/ubi0 -n 5 -s 126976 -N fit

[ "$HAS_BACKUP" = "1" ] && install_write_backup

sync

# Lime = done. The 5s pause makes the state visible before the board disappears
# from the console on reboot.
led_lime

sleep 5

reboot -f
