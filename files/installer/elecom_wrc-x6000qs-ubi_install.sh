#!/bin/sh

. /installer/install_func

# cheks if the lock file exists and if it does, aborts the script
check_lock

BOARD_NAME=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | tr ',' '_')

INSTALLER_DIR="/installer"
PRELOADER="$(ls -1 $INSTALLER_DIR/mt7986-*-bl2.img)"
FIP="$INSTALLER_DIR/mt7986_${BOARD_NAME}-u-boot.fip"
# Use ls to resolve the wildcard at runtime so the script does not need to
# hardcode the OpenWrt build version string in the filename.
RECOVERY="$(ls -1 $INSTALLER_DIR/openwrt-*mediatek-filogic-${BOARD_NAME}-initramfs-recovery.itb)"

# These flags allow selectively skipping volume creation.
HAS_ENV=1
HAS_FIP=1
HAS_FACTORY=1
# The backup volume takes storage space - make it optional
HAS_BACKUP=1


# OEM mtd layout:
# mtd0 = BL2 - full partition 0x100000 bytes (1MiB)
MTD_BL2=0
MTD_BL2_LEN=4

# mtd1 layout at 128k (0x20000) erase blocks:
#  4 blocks 0-3    (0x000000-0x07ffff): OEM U-Boot environment (in fact only 128k of real data there)
MTD_UBOOTENV=1
MTD_UBOOTENV_OFFSET=0
MTD_UBOOTENV_LEN=1

# 16 blocks 4-19   (0x080000-0x17ffff): Factory / Wi-Fi EEPROM (in fact only 512k of real data there)
MTD_FACTORY=1
MTD_FACTORY_OFFSET=4
MTD_FACTORY_LEN=4

# 16 blocks 20-35  (0x180000-0x27ffff): FIP (BL31 + U-Boot) (in fact only 1024k of real data there)
MTD_FIP=1
MTD_FIP_OFFSET=20
MTD_FIP_LEN=8

# Fwheader1
# 1 block		  OEM firmware header
MTD_FWHDR1=1
MTD_FWHDR1_OFFSET=36
MTD_FWHDR1_LEN=1

# firmware1
# 400 blocks, 50MiB: OEM firmware/UBI
MTD_FW1=1
MTD_FW1_OFFSET=37
MTD_FW1_LEN=400

# Config1
# 28 blocks, 3.5MiB: configuration part for firmware1
MTD_CFG1=1
MTD_CFG1_OFFSET=437
MTD_CFG1_LEN=28

# Fwheader2
# 1 block		  OEM firmware header
MTD_FWHDR2=1
MTD_FWHDR2_OFFSET=465
MTD_FWHDR2_LEN=1

# firmware2
# 400 blocks, 50MiB: OEM firmware/UBI
MTD_FW2=1
MTD_FW2_OFFSET=466
MTD_FW2_LEN=400

# Config2
# 28 blocks, 3.5MiB: configuration part for firmware2
MTD_CFG2=1
MTD_CFG2_OFFSET=866
MTD_CFG2_LEN=28

# persis part, used to keep track of active boot part
# 8 blocks (in fact only <1k of a real data there)
MTD_PERSIST=1
MTD_PERSIST_OFFSET=894
MTD_PERSIST_LEN=1



# LED definitions for the installer initramfs.
# These are used to signal installer status and errors to the user via the board's LED(s).
LED_BLUE="blue:power"
LED_GREEN="green:power"
LED_RED="red:power"
LED_WHITE="white:power"


led_reset() {
	echo none > /sys/class/leds/${LED_BLUE}/trigger
	echo none > /sys/class/leds/${LED_GREEN}/trigger
	echo none > /sys/class/leds/${LED_RED}/trigger
	echo none > /sys/class/leds/${LED_WHITE}/trigger

	echo 0 > /sys/class/leds/${LED_BLUE}/brightness
	echo 0 > /sys/class/leds/${LED_GREEN}/brightness
	echo 0 > /sys/class/leds/${LED_RED}/brightness
	echo 0 > /sys/class/leds/${LED_WHITE}/brightness
}

# Installation complete: solid light green LED
led_done() {
	led_reset
	echo 255 > /sys/class/leds/${LED_WHITE}/brightness
	echo 255 > /sys/class/leds/${LED_GREEN}/brightness
}

# Flashing in progress: blue LED with a short delay to indicate activity.
led_run() {
	led_reset
	echo timer > /sys/class/leds/${LED_BLUE}/trigger
	echo 1 > /sys/class/leds/${LED_BLUE}/delay_on
	echo 70 > /sys/class/leds/${LED_BLUE}/delay_off
}

# Error state: LED with a long delay to indicate a problem.
led_error() {
	led_reset
	echo timer > /sys/class/leds/${LED_RED}/trigger
	echo 120 > /sys/class/leds/${LED_RED}/delay_on
	echo 200 > /sys/class/leds/${LED_RED}/delay_off
}




led_run

echo
log "OpenWrt UBI installer (${BOARD_NAME})"
echo
# let progress LED blink a bit to indicate the script is running 
sleep 3

if [ ! -s "$PRELOADER" ] || [ ! -s "$FIP" ] || [ ! -s "$RECOVERY" ]; then
	trigger_crash "Missing files. Aborting."
fi


# backup all OEM data
if [ "$HAS_BACKUP" = "1" ]; then
	log "backing up BL2, Factory, FIP + OEM parts from mtd0, mtd1 before erase"
	bpath="/tmp/boot_backup"
	mkdir -p $bpath
	mtd_gzdump $MTD_BL2 BL2 $MTD_BL2_LEN 0 $bpath
	mtd_gzdump $MTD_UBOOTENV u-boot-env $MTD_UBOOTENV_LEN $MTD_UBOOTENV_OFFSET $bpath
	mtd_gzdump $MTD_FACTORY Factory $MTD_FACTORY_LEN $MTD_FACTORY_OFFSET $bpath
	mtd_gzdump $MTD_FIP FIP $MTD_FIP_LEN $MTD_FIP_OFFSET $bpath
	mtd_gzdump $MTD_FWHDR1 Fwheader $MTD_FWHDR1_LEN $MTD_FWHDR1_OFFSET $bpath
	mtd_gzdump $MTD_FW1 ubi $MTD_FW1_LEN $MTD_FW1_OFFSET $bpath
	mtd_gzdump $MTD_CFG1 Config $MTD_CFG1_LEN $MTD_CFG1_OFFSET $bpath
	mtd_gzdump $MTD_FWHDR2 Fwheader_2 $MTD_FWHDR2_LEN $MTD_FWHDR2_OFFSET $bpath
	mtd_gzdump $MTD_FW2 ubi_2 $MTD_FW2_LEN $MTD_FW2_OFFSET $bpath
	mtd_gzdump $MTD_CFG2 Config_2 $MTD_CFG2_LEN $MTD_CFG2_OFFSET $bpath
	mtd_gzdump $MTD_PERSIST persist $MTD_PERSIST_LEN $MTD_PERSIST_OFFSET $bpath

	# Create an archive of the backup files and remove the temporary directory.
	tar czvf /tmp/boot_backup.tar -C /tmp boot_backup && rm -rf /tmp/boot_backup
fi

# Extract Wi-Fi calibration data before erasing mtd1. Loss of this data
# requires physical access to restore and will break wireless permanently.
install_get_factory /dev/mtd1 0x80000 "7986" || trigger_crash "cannot find Wi-Fi EEPROM data"

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
ubimkvol /dev/ubi0 -n 4 -s $RECOVERY_SIZE -N recovery && ubi_mknod ubi0_4
[ -e /dev/ubi0_4 ] && ubiupdatevol /dev/ubi0_4 $RECOVERY

# Reserve a minimal dynamic volume for the production FIT image. It will be
# populated on first boot by the sysupgrade or TFTP flow in U-Boot.
log "create fit ubi volume"
ubimkvol /dev/ubi0 -n 5 -s 126976 -N fit

if [ "$HAS_BACKUP" = "1" ]; then
	install_write_backup "/tmp/boot_backup.tar"
fi

sync

# Lime = done. The 5s pause makes the state visible before the board disappears
# from the console on reboot.
led_done

sleep 5

##reboot -f
