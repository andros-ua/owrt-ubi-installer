#!/bin/sh

. /installer/install_func

BOARD_NAME=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | tr ',' '_')

INSTALLER_DIR="/installer"
PRELOADER="$(ls -1 $INSTALLER_DIR/mt7981-*-bl2.img)"
FIP="$INSTALLER_DIR/mt7981_${BOARD_NAME}-u-boot.fip"
# Use ls to resolve the wildcard at runtime so the script does not need to
# hardcode the OpenWrt build version string in the filename.
RECOVERY="$(ls -1 $INSTALLER_DIR/openwrt-*mediatek-filogic-${BOARD_NAME}-initramfs-recovery.itb)"

# These flags allow selectively skipping volume creation.
HAS_ENV=1
HAS_FIP=1
HAS_FACTORY=1
# The backup volume takes storage space - make it optional
HAS_BACKUP=1

# LED definitions for the installer initramfs.
# These are used to signal installer status and errors to the user via the board's LED(s).
#LED_BLUE="blue:status"
LED_GREEN="green:status"
LED_RED="red:status"

led_reset() {
#	echo none > /sys/class/leds/${LED_BLUE}/trigger
	echo none > /sys/class/leds/${LED_GREEN}/trigger
	echo none > /sys/class/leds/${LED_RED}/trigger
#	echo 0 > /sys/class/leds/${LED_BLUE}/brightness
	echo 0 > /sys/class/leds/${LED_GREEN}/brightness
	echo 0 > /sys/class/leds/${LED_RED}/brightness
}

# Installation complete: solid LED.
led_done() {
	led_reset
	echo 255 > /sys/class/leds/${LED_RED}/brightness
	echo 255 > /sys/class/leds/${LED_GREEN}/brightness
}

# Flashing in progress: LED with a short delay to indicate activity.
led_run() {
	led_reset
	echo timer > /sys/class/leds/${LED_GREEN}/trigger
	echo 1 > /sys/class/leds/${LED_GREEN}/delay_on
	echo 70 > /sys/class/leds/${LED_GREEN}/delay_off
}

# Error state: LED with a long delay to indicate a problem.
led_error() {
	led_reset
	echo timer > /sys/class/leds/${LED_RED}/trigger
	echo 120 > /sys/class/leds/${LED_RED}/delay_on
	echo 200 > /sys/class/leds/${LED_RED}/delay_off
}

# All installer messages go to the kernel ring buffer so they appear in both
# the live console and the dmesg.log saved to the boot_backup UBI volume.
log () {
	echo "INSTALLER: $@" > /dev/kmsg
}



led_run

sleep 1

echo
log "OpenWrt UBI installer (${BOARD_NAME})"
echo


if [ ! -s "$PRELOADER" ] || [ ! -s "$FIP" ] || [ ! -s "$RECOVERY" ]; then
	trigger_crash "Missing files. Aborting."
fi



# mtd0 = BL2 (full partition)
# mtd1 layout at 128k erase blocks:
#   blocks 0-3    (0x000000-0x07ffff): U-Boot environment
#   blocks 4-19   (0x080000-0x17ffff): Factory / Wi-Fi EEPROM
#   blocks 20-35  (0x180000-0x27ffff): FIP (BL31 + U-Boot)
if [ "$HAS_BACKUP" = "1" ]; then
	log "backing up BL2, Factory, FIP from mtd0, mtd1 before erase"
	mkdir -p /tmp/boot_backup
	install_prepare_mtd_backup 0 BL2
	install_prepare_mtd_backup 1 u-boot-env 4
	install_prepare_mtd_backup 1 Factory 16 4
	install_prepare_mtd_backup 1 FIP 16 20

	# Create a compressed archive of the backup files and remove the temporary directory.
	tar czvf /tmp/boot_backup.tar.gz -C /tmp boot_backup && rm -rf /tmp/boot_backup
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
ubi_mknod ubi0_4 && ubiupdatevol /dev/ubi0_4 $RECOVERY

# Reserve a minimal dynamic volume for the production FIT image. It will be
# populated on first boot by the sysupgrade or TFTP flow in U-Boot.
log "create fit ubi volume"
ubimkvol /dev/ubi0 -n 5 -s 126976 -N fit

if [ "$HAS_BACKUP" = "1" ]; then
	install_write_backup
fi

sync

# Lime = done. The 5s pause makes the state visible before the board disappears
# from the console on reboot.
led_done

sleep 5

reboot -f
