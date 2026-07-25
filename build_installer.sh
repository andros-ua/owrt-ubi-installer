#!/bin/bash -x
# Builds a custom OpenWrt installer and recovery image.
#
# The script:
#   1. Downloads and verifies an OpenWrt Image Builder (IB) via PGP + sha256
#   2. Repacks the initramfs-based recovery .itb with extra LuCI packages
#   3. Builds a self-contained installer .itb that carries the new bootloader (BL2 + FIP),
#      the recovery image, and a small installer payload.
#
# Usage:
#   ./build_installer.sh
#   Output files land in the directory from which the script is called ($PWD).
#
# Prerequisites:
#   gcc, libfdt-dev   (to compile the bundled 'unfit' tool)
#   wget, gpg, xz, cpio, make, cmake

set -o errexit   # abort on any non-zero exit status
set -o nounset   # treat unset variables as errors
set -o pipefail  # propagate failures through pipes

BOARD_NAME="cmcc_rax3000m-ubi"

# Name of the BL2 bootloader file to embed in the installer image.
PRELOADER="mt7981-spim-nand-ubi-ddr4-bl2.img" 

# OpenWrt release to target for the installer build; must match the version used to build the IB and the .itb images.
OPENWRT_RELEASE="25.12.5"

# Output directory — caller's working directory, not the script's own directory.
DESTDIR="$PWD"

# PGP key ID used by the OpenWrt project to sign release artifacts.
OPENWRT_PGP="0x1D53D1877742E911"
KEYSERVER="keyserver.ubuntu.com"
# PGP key ID used by andros-ua
ANDROS_UA_PGP="0x5326B6B2DC1CC51E"

# Absolute path to the directory containing this script; lets us locate
# sibling files regardless of where the caller invoked us from.
INSTALLERDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# OpenWrt Image Builder is extracted here; cleaned up between full rebuilds.
OPENWRT_DIR="${INSTALLERDIR}/openwrt-ib"

# Host-side tools shipped inside the IB tarball — we use the IB's own copies
# to guarantee version compatibility with the target rootfs.
CPIO="${OPENWRT_DIR}/staging_dir/host/bin/cpio"
MKIMAGE="${OPENWRT_DIR}/staging_dir/host/bin/mkimage"
APK="${OPENWRT_DIR}/staging_dir/host/bin/apk"
XZ="${OPENWRT_DIR}/staging_dir/host/bin/xz"

# 'unfit' splits a FIT image (.itb) into its component blobs so we can
# patch individual nodes (kernel, dtb, initrd) and re-pack them.
UNFIT="${INSTALLERDIR}/unfit"
[ -x "$UNFIT" ] || ( cd "${INSTALLERDIR}/src" ; cmake . ; make all ; cp unfit .. ) || {
	echo "can't build unfit. please install gcc and libfdt-dev"
	exit 0
}

# Bake the last git commit timestamp into generated images so that builds are
# reproducible: identical source trees produce byte-for-byte identical output.
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct -C "${INSTALLERDIR}")

# Global state threaded between unfit_image / refit_image / bundle_initrd.
DTC=        # path to dtc found inside the extracted IB kernel build dir
FILEBASE=   # basename of the .itb being worked on (no extension)
WORKDIR=    # ephemeral temp directory for the current image being built
ITSFILE=    # path to the .its (DTS source) dumped from the current .itb


# ---------------------------------------------------------------------------
# prepare_openwrt_ib
#
# Downloads the three OpenWrt artifacts needed for installer build:
#   - Image Builder tarball  (.tar.zst)
#   - sysupgrade image       (.itb)
#   - initramfs/recovery image (.itb)
#
# All downloads are verified against the project's signed sha256sums file
# before extraction.  A cached copy is re-used if its checksum still passes,
# saving bandwidth on repeated runs.
# ---------------------------------------------------------------------------
prepare_openwrt_ib() {
	# Isolate GPG state in a throw-away keyring so we don't pollute the
	# user's real ~/.gnupg and avoid any trust-model surprises.
	GNUPGHOME="$(mktemp -d)"
	export GNUPGHOME
	trap 'rm -rf -- "${GNUPGHOME}"' EXIT

	mkdir -p "${INSTALLERDIR}/dl"
	cd "${INSTALLERDIR}/dl"

	# Import the OpenWrt release key only if it isn't already in our
	# temporary keyring (avoids a network round-trip on warm runs).
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $OPENWRT_PGP 1>/dev/null 2>/dev/null || gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --keyserver ${KEYSERVER}	--recv-key $OPENWRT_PGP
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $OPENWRT_PGP 1>/dev/null 2>/dev/null || exit 0

	# Add andros-ua key while using custom images
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $ANDROS_UA_PGP 1>/dev/null 2>/dev/null || gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --keyserver ${KEYSERVER}	--recv-key $ANDROS_UA_PGP
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $ANDROS_UA_PGP 1>/dev/null 2>/dev/null || exit 0

	# Always re-fetch the checksum manifest.
	rm -f "sha256sums.asc" "sha256sums"
	wget "${OPENWRT_TARGET}/sha256sums.asc"
	wget "${OPENWRT_TARGET}/sha256sums"
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --verify sha256sums.asc sha256sums || exit 1

	# Tear down the temp-keyring trap now that we're done with GPG.
	trap - EXIT
	rm -rf -- "${GNUPGHOME}"
	export -n GNUPGHOME

	# Validate any previously downloaded blobs; remove stale ones so wget -c
	# will re-download rather than silently use a corrupt file.
	sha256sum -c sha256sums --ignore-missing || rm -f "$OPENWRT_SYSUPGRADE" "$OPENWRT_IB" "$OPENWRT_INITRD"

	# Resume-capable downloads — no-ops if the file is already complete.
	wget -c "${OPENWRT_TARGET}/${OPENWRT_INITRD}"
	wget -c "${OPENWRT_TARGET}/${OPENWRT_SYSUPGRADE}"
	wget -c "${OPENWRT_TARGET}/${OPENWRT_IB}"

	# Final integrity check before we trust any of these files.
	sha256sum -c sha256sums --ignore-missing || exit 1

	mkdir -p "${OPENWRT_DIR}" || exit 1
	# Strip the top-level directory component so the IB contents land
	# directly in OPENWRT_DIR regardless of the tarball's internal prefix.
	tar -xf "${INSTALLERDIR}/dl/${OPENWRT_IB}" -C "${OPENWRT_DIR}" --strip-components=1

	# Locate dtc that was built as part of the kernel in the IB.  We need
	# exactly the version that matches the kernel tree to avoid dtb ABI skew.
	DTC="$(ls -1 "${OPENWRT_DIR}/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_filogic/linux-"*"/scripts/dtc/dtc")"
	[ -x "$DTC" ] || {
		echo "can't find dtc executable in OpenWrt IB"
		exit 1
	}
}


# ---------------------------------------------------------------------------
# its_add_data  (reads ITSFILE, writes to stdout)
#
# After round-tripping a FIT image through dtc (dtb → dts), all binary blobs
# are referenced by offset/size rather than inline.  This function re-inserts
# "data = /incbin/(…);" lines so mkimage can re-embed the blobs when we call
# refit_image.
#
# It works by parsing the .its structure line-by-line with a tiny state
# machine:
#   State 0  →  scanning for the top-level "images {" block
#   State 1  →  inside images {}, scanning for individual image sub-nodes
#   State 2  →  inside an image node, injecting a data line after "type ="
# ---------------------------------------------------------------------------
its_add_data() {
	local line
	local in_images=0   # 1 once we're inside the top-level images {} block
	local in_image=0    # 1 once we're inside an individual image node
	local br_level=0    # tracks nested brace depth within an image node
	local img_name      # name token of the current image node (used as filename)

	while read -r line; do
		echo "$line"

		if [ "$in_images" = "0" ]; then
			case "$line" in
				*"images {"*)
					in_images=1
					continue;
				;;
			esac
		fi

		if [ "$in_images" = "1" ] && [ "$in_image" = "0" ]; then
			case "$line" in
				*"{"*)
					# Opening brace after the node name — record the name
					# and descend into the image node.
					in_image=1
					img_name="$(echo "$line" | cut -d'{' -f1 | sed 's/ *$//g' )"
					continue;
				;;
			esac
		fi

		if [ "$in_images" = "1" ] && [ "$in_image" = "1" ]; then
			case "$line" in
				*"type = "*)
					# Insert the data reference immediately after the type
					# declaration; unfit wrote the blob to a file named after
					# the image node.
					echo "data = /incbin/(\"./${img_name}\");"
					;;
				*"{"*)
					# Track nested braces (e.g. hash sub-nodes) so we don't
					# mistake their closing brace for the image node's end.
					br_level=$((br_level + 1))
					continue;
					;;
				*"}"*)
					if [ $br_level -gt 0 ]; then
						br_level=$((br_level - 1))
					else
						# Outermost closing brace — leave the image node.
						in_image=0
					fi
					continue;
					;;
			esac
		fi
	done < "${ITSFILE}"
}


# ---------------------------------------------------------------------------
# unfit_image <input.itb>
#
# Splits a FIT image into its constituent blobs and a DTS source file.
# Sets the global WORKDIR, FILEBASE, ITSFILE, EXTERNAL, and STATIC so the
# rest of the pipeline knows how to put things back together.
#
# EXTERNAL=1  →  blobs live outside the FIT header (data-size node present)
# STATIC=1    →  blobs are at fixed offsets      (data-position node present)
# Both flags drive the mkimage arguments used in refit_image.
# ---------------------------------------------------------------------------
unfit_image() {
	INFILE="$1"
	FILEBASE="$(basename "$INFILE" .itb)"
	WORKDIR="$(mktemp -d)"
	ITSFILE="${WORKDIR}/image.its"
	mkdir -p "$WORKDIR"
	cd "$WORKDIR"

	# Dump raw blobs from the .itb into individual files in WORKDIR.
	"$UNFIT" "$INFILE"

	# Decompile the .itb to DTS so we can inspect and patch it as text.
	"$DTC" -I dtb -O dts -o "$ITSFILE" "$INFILE" || exit 2

	# Detect the FIT layout style used by the original image.
	EXTERNAL=
	STATIC=
	grep -q "data-size = " "$ITSFILE" && EXTERNAL=1
	grep -q "data-position = " "$ITSFILE" && STATIC=1

	# Strip the existing data/size/offset/position nodes — its_add_data will
	# re-emit them pointing at the (potentially modified) blob files.
	grep -v -e "data = " -e "data-size = " -e "data-offset = " -e "data-position = " "$ITSFILE" > "${ITSFILE}.new"
	mv "${ITSFILE}.new" "${ITSFILE}"
}


# ---------------------------------------------------------------------------
# refit_image <blocksize> [imgtype]
#
# Reconstructs a FIT image from the (possibly patched) blobs in WORKDIR and
# the DTS file in ITSFILE, then pads the result to a multiple of <blocksize>.
#
# imgtype is appended to the output filename (e.g. "installer") so that
# multiple variants produced from the same base .itb don't collide.
# ---------------------------------------------------------------------------
refit_image() {
	local blocksize="${1}"
	local imgtype
	[ -n "${2-}" ] && imgtype="${2}"
	local MKIMAGE_PARM=()

	# Inject data = /incbin/ references back into the cleaned-up .its.
	its_add_data > "${ITSFILE}.new"

	# Mirror the layout flags of the original image so the new .itb is
	# structurally compatible with the bootloader's FIT parser.
	[ "$EXTERNAL" = "1" ] && MKIMAGE_PARM=("${MKIMAGE_PARM[@]}" -E -B 0x1000)
	[ "$STATIC" = "1" ] && MKIMAGE_PARM=("${MKIMAGE_PARM[@]}" -p 0x1000)

	# Put dtc on PATH so mkimage can invoke it when processing the .its.
	PATH="$PATH:$(dirname "$DTC")" \
		SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
		"$MKIMAGE" "${MKIMAGE_PARM[@]}" -f "${ITSFILE}.new" "${FILEBASE}-refit.itb"

	echo "imgtype: \"${imgtype:-(unset)}\""

	# Pad to blocksize boundary — required for raw NAND flash writes where
	# partial erase blocks cause write failures.
	dd if="${FILEBASE}-refit.itb" of="${FILEBASE}${imgtype:+-$imgtype}.itb" bs="$blocksize" conv=sync
}


# ---------------------------------------------------------------------------
# extract_initrd
#
# Unpacks the initrd blob (written by unfit as "initrd-1") into a plain
# directory so we can add/remove packages and files before repacking.
# Returns 1 (non-fatal) if no initrd blob was found in the .itb.
# ---------------------------------------------------------------------------
extract_initrd() {
	[ -e "${WORKDIR}/initrd-1" ] || return 1
	[ -e "${WORKDIR}/initrd" ] && rm -rf "${WORKDIR}/initrd"
	mkdir "${WORKDIR}/initrd"
	"${XZ}" -d < "${WORKDIR}/initrd-1" | "${CPIO}" -i -D "${WORKDIR}/initrd"
	rm "${WORKDIR}/initrd-1"    # free space; we now own the unpacked form
	echo "initrd extracted in '${WORKDIR}/initrd'"
	return 0
}


# ---------------------------------------------------------------------------
# repack_initrd
#
# Rebuilds the initrd blob from the (patched) directory tree.
# Uses --reproducible cpio + SOURCE_DATE_EPOCH timestamp clamping so the
# resulting blob is deterministic across machines and timezones.
# Returns 1 (non-fatal) if the unpacked initrd directory is missing.
# ---------------------------------------------------------------------------
repack_initrd() {
	[ -d "${WORKDIR}/initrd" ] || return 1

	# Clamp all mtimes to SOURCE_DATE_EPOCH so timestamps embedded in the
	# cpio archive are stable, regardless of when files were last touched.
	find "${WORKDIR}/initrd" -newermt "@${SOURCE_DATE_EPOCH}" -print0 |
		xargs -0r touch --no-dereference --date="@${SOURCE_DATE_EPOCH}"

	echo "re-compressing initrd..."
	( cd "${WORKDIR}/initrd"
	  find . | LC_ALL=C sort |
	  "${CPIO}" --reproducible -o -H newc -R 0:0 |
	  "${XZ}" -T0 -c -9 --check=crc32 > "${WORKDIR}/initrd-1" )
	return 0
}


# ---------------------------------------------------------------------------
# allow_mtd_write
#
# Patches the installer's device tree (fdt-1) to give the installer script
# raw access to every MTD partition on the SPI-NAND flash:
#
#   - Strips "read-only" flags so all partitions are writable.
#   - Removes "linux,ubi" hints to prevent the kernel from auto-attaching
#     the existing UBI device before the installer has a chance to reformat it.
#   - Renames the "spi-nand" compatible string to prevent any NAND driver
#     from binding — the installer accesses flash through raw MTD only.
# ---------------------------------------------------------------------------
allow_mtd_write() {
	"$DTC" -I dtb -O dts -o "${WORKDIR}/fdt-1.dts" "${WORKDIR}/fdt-1"
	rm "${WORKDIR}/fdt-1"
	grep -v 'read-only' "${WORKDIR}/fdt-1.dts" > "${WORKDIR}/fdt-1.dts.patched"
	grep -v 'linux,ubi' "${WORKDIR}/fdt-1.dts.patched" > "${WORKDIR}/fdt-1.dts.patched2"
	mv "${WORKDIR}/fdt-1.dts.patched2" "${WORKDIR}/fdt-1.dts.patched"
	sed -i 's/"ubi"/"ibu"/' "${WORKDIR}/fdt-1.dts.patched"
	"$DTC" -I dts -O dtb -o "${WORKDIR}/fdt-1" "${WORKDIR}/fdt-1.dts.patched"
}


# ---------------------------------------------------------------------------
# enable_services
#
# Runs rc.common enable for every init script in the unpacked initrd so that
# the required daemons (e.g. uhttpd for LuCI) start on boot without requiring
# manual symlink management in the file overlay.
# ---------------------------------------------------------------------------
enable_services() {
	cd "${WORKDIR}/initrd"
	for service in ./etc/init.d/*; do
		( cd "${WORKDIR}/initrd"
		  IPKG_INSTROOT="${WORKDIR}/initrd" \
		  $(command -v bash) ./etc/rc.common "$service" enable 2>/dev/null )
	done
}


# ---------------------------------------------------------------------------
# bundle_initrd <imgtype> <input.itb> [extra-files…]
#
# High-level orchestration for a single image variant:
#   1. Unpacks the .itb and extracts the initrd
#   2. Removes unwanted packages (e.g. large Wi-Fi firmware not needed during
#      install/recovery) to keep the image within flash size constraints
#   3. Adds base packages, then variant-specific packages or files
#   4. Enables init scripts, cleans up temp artifacts, repacks the initrd
#   5. Calls refit_image to produce the final padded .itb
#
# imgtype must be one of:
#   recovery  — adds LuCI packages; padded at 128 KiB
#   installer — adds installer payload files and the bootloader blobs;
#               also patches the dtb via allow_mtd_write before repacking
# ---------------------------------------------------------------------------
bundle_initrd() {
	local imgtype=$1
	shift

	unfit_image "$1"
	shift

	extract_initrd

	# Remove packages to shrink the initrd (Wi-Fi drivers are irrelevant
	# during a recovery/install boot and consume several MiB).
	[[ ${#OPENWRT_REMOVE_PACKAGES[@]} -gt 0 ]] && \
		IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
		"${APK}" --no-scripts --no-logfile --root "${WORKDIR}/initrd" \
		del "${OPENWRT_REMOVE_PACKAGES[@]}"

	# Refresh the APK index inside the initrd so subsequent add operations
	# resolve the correct package versions from the feed.
	PATH="$(dirname "${APK}"):$PATH" \
	TMPDIR="${WORKDIR}/initrd/tmp" \
		"${APK}" --no-logfile --root "${WORKDIR}/initrd" update

	# Install packages common to both recovery and installer images.
	[[ ${#OPENWRT_ADD_PACKAGES[@]} -gt 0 ]] && \
		PATH="$(dirname "${APK}"):$PATH" \
		TMPDIR="${WORKDIR}/initrd/tmp" \
		IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
		"${APK}" --no-scripts --no-logfile --root "${WORKDIR}/initrd" \
		add "${OPENWRT_ADD_PACKAGES[@]}"

	case "$imgtype" in
		recovery)
			# Add LuCI so the user gets a web UI when booted into recovery.
			[[ ${#OPENWRT_ADD_REC_PACKAGES[@]} -gt 0 ]] && \
			PATH="$(dirname "${APK}"):$PATH" \
			TMPDIR="${WORKDIR}/initrd/tmp" \
			IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
				"${APK}" --no-scripts --no-logfile --root "${WORKDIR}/initrd" \
				add "${OPENWRT_ADD_REC_PACKAGES[@]}"
			;;
		installer)
			# Overlay the installer scripts from the repo's files/ directory,
			# then copy the bootloader blobs (bl2, FIP) and recovery .itb into
			# /installer inside the initrd so the init script can find them.
			cp -avr "${INSTALLERDIR}/files/"* "${WORKDIR}/initrd"
			cp -v "$@" "${WORKDIR}/initrd/installer"
			;;
	esac

	enable_services

	# Purge APK's download cache — it's only needed during this build step
	# and would inflate the final initrd size.
	rm -rf "${WORKDIR}/initrd/tmp/"*

	# Normalise all mtimes before cpio to ensure a deterministic archive.
	find ${WORKDIR}/initrd/ -mindepth 1 -execdir touch -hcd "@${SOURCE_DATE_EPOCH}" "{}" +

	repack_initrd

	cd "${WORKDIR}"
	case "$imgtype" in
		recovery)
			refit_image 128k
			;;
		installer)
			# Patch the dtb so the installer can access every MTD partition.
			allow_mtd_write
			# Force a standard inline FIT layout for the installer regardless of
			# what the source .itb used; the installer bootloader expects blobs
			# embedded in the FIT header, not appended externally.
			EXTERNAL=
			STATIC=
			# Rewrite the kernel load/entry address to the correct DRAM
			# location for the mt7981's DDR3 memory map.
			sed -i 's/<0x46000000>/<0x48000000>/' "${ITSFILE}"
			refit_image 128k "$imgtype"
			;;
	esac
}


# ---------------------------------------------------------------------------
# installer  (entry point)
#
# Ties all of the above together for the build:
#
#   Step 1 — Build the recovery .itb (LuCI included, Wi-Fi firmware stripped)
#             Saved directly to DESTDIR for use as a standalone recovery image.
#
#   Step 2 — Copy the upstream sysupgrade .itb to DESTDIR unchanged; it is
#             the final OpenWrt image that the installer will flash.
#
#   Step 3 — Build the installer .itb which embeds:
#               • BL2 (ARM Trusted Firmware first-stage bootloader)
#               • FIP (Firmware Image Package: BL31 + U-Boot as BL33)
#               • The recovery .itb built in step 1
#             The installer init script writes BL2 to raw NAND, then
#             flashes the FIP, then boots into the new U-Boot which finally
#             flashes the sysupgrade image.
# ---------------------------------------------------------------------------
ubi_installer() {
	OPENWRT_TARGET="https://dlowrt.kuiukov.com/releases/${OPENWRT_RELEASE}/targets/mediatek/filogic"
	OPENWRT_IB="openwrt-imagebuilder-${OPENWRT_RELEASE}-mediatek-filogic.Linux-x86_64.tar.zst"
	OPENWRT_INITRD="openwrt-${OPENWRT_RELEASE}-mediatek-filogic-${BOARD_NAME}-initramfs-recovery.itb"
	OPENWRT_SYSUPGRADE="openwrt-${OPENWRT_RELEASE}-mediatek-filogic-${BOARD_NAME}-squashfs-sysupgrade.itb"

	# Packages added only to the recovery image (LuCI web UI).
	OPENWRT_ADD_REC_PACKAGES=(uhttpd luci-mod-admin-full luci-theme-bootstrap)

	# Remove Wi-Fi firmware and unneeded daemons from both images — the
	# radios are not used during installation or recovery, and omitting
	# these saves ~10 MiB of initrd space.
	OPENWRT_REMOVE_PACKAGES=(kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-mt76-connac kmod-mt76-core odhcp6c odhcpd-ipv6only ppp ppp-mod-pppoe wpad-basic-mbedtls)

	# No extra packages needed in both images beyond what's already in the
	# initramfs; left as an explicit empty array for future extension.
	OPENWRT_ADD_PACKAGES=()

	prepare_openwrt_ib

	# Sanity-check that this IB actually includes the 'fitblk'
	# package.  fitblk is required by the installer to write FIT images to
	# MTD block devices; older versions may predate the feature.
	make -C ${OPENWRT_DIR} info | grep "Default Packages:" | grep -q fitblk || {
		echo "ImageBuilder is outdated and not in sync with installer."
		echo "Please re-run once fitblk changes are included in ${OPENWRT_RELEASE} build."
		exit 1
	}

	# --- Step 1: recovery image ---
	bundle_initrd recovery "${INSTALLERDIR}/dl/${OPENWRT_INITRD}"
	mv "${WORKDIR}/${FILEBASE}.itb" "${DESTDIR}"
	rm -r "${WORKDIR}"

	# --- Step 2: unmodified sysupgrade image ---
	cp "${INSTALLERDIR}/dl/${OPENWRT_SYSUPGRADE}" "${DESTDIR}"

	# --- Step 3: installer image ---
	# Positional args after the imgtype and base .itb are extra files that
	# bundle_initrd copies into /installer inside the initrd:
	#   bl2  — raw NAND bootloader stage 1 (written to the very start of flash)
	#   fip  — U-Boot + ATF packaged as a Trusted Firmware FIP image
	#   recovery .itb — the image built in step 1
	bundle_initrd installer "${INSTALLERDIR}/dl/${OPENWRT_INITRD}" \
		"${OPENWRT_DIR}/staging_dir/target-aarch64_cortex-a53_musl/image/${PRELOADER}" \
		"${OPENWRT_DIR}/staging_dir/target-aarch64_cortex-a53_musl/image/mt7981_${BOARD_NAME}-ddr4-u-boot.fip" \
		"${DESTDIR}/${FILEBASE}.itb"

	mv "${WORKDIR}/${FILEBASE}-installer"* "${DESTDIR}"
	rm -r "${WORKDIR}"
}

ubi_installer
