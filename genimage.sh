#!/bin/bash

set -e

whoami
echo "Downloading the image"
wget -nv https://github.com/droidian-images/droidian/releases/download/droidian%2Fbookworm%2F24/droidian-OFFICIAL-phosh-phone-rootfs-api29-arm64-24_20220804.zip
echo "Readying up the image"
unzip droidian-OFFICIAL-phosh-phone-rootfs-api29-arm64-24_20220804.zip
mkdir ./rootfs/ -p
resize2fs ./data/rootfs.img 5G
DEVICE_ROOTFS=$(losetup -f)
ROOTFS_PATH="./rootfs/"
losetup ${DEVICE_ROOTFS} ./data/rootfs.img
mount ${DEVICE_ROOTFS} ${ROOTFS_PATH}
echo "Installing dependencies"
apt update
apt install qemu-user-static -y
echo "Downloading adaptation"
wget -nv https://mirror.bardia.tech/exynos9810/pool/main/adaptation-droidian-exynos9810_0.0.0+git20230110092736.88cb61b.main_all.deb -P ./rootfs/
wget -nv https://mirror.bardia.tech/exynos9810/pool/main/adaptation-exynos9810-configs_0.0.0+git20230110092736.88cb61b.main_all.deb -P ./rootfs/
cp /usr/bin/qemu-aarch64-static ./rootfs/usr/bin/
echo "Applying adaptation"
chroot ./rootfs/ qemu-aarch64-static /bin/bash -c 'export PATH="$PATH:/usr/bin:/usr/sbin:/bin:/sbin" && rm -f /etc/systemd/system/dbus-org.bluez.service && systemctl mask systemd-resolved systemd-timesyncd upower bluetooth && dpkg -i /*.deb && rm /*.deb /deb -rf && systemctl enable apt-fix samsung-hwc epoch altresolv upoweralt bluetoothalt batman'
rm ./rootfs/usr/bin/qemu-aarch64-static

ROOTFS_SIZE=$(du -sm ${ROOTFS_PATH} | awk '{ print $1 }')
IMG_SIZE=$(( ${ROOTFS_SIZE} + 250 + 32 + 32 )) # FIXME 250MB + 32MB + 32MB contingency
IMG_MOUNTPOINT=".image"

# Crate temporary directory
mkdir rootfs.work
WORK_DIR="rootfs.work"

# create target base image
echo "Creating empty image"
dd if=/dev/zero of=rootfs.work/userdata.raw bs=1M count=${IMG_SIZE}

# Loop mount
echo "Mounting image"
DEVICE=$(losetup -f)

losetup ${DEVICE} ${WORK_DIR}/userdata.raw

# Create LVM physical volume
echo "Creating PV"
pvcreate ${DEVICE}

# Create LVM volume group
echo "Creating VG"
vgcreate droidian "${DEVICE}"

# Create LVs, currently
# 1) droidian-persistent (32M)
# 2) droidian-reserved (32M)
# 3) droidian-rootfs (rest)
echo "Creating LVs"
lvcreate --zero n -L 32M -n droidian-persistent droidian
lvcreate --zero n -L 32M -n droidian-reserved droidian
lvcreate --zero n -l 100%FREE -n droidian-rootfs droidian

vgchange -ay droidian
vgscan --mknodes -v

sleep 5

# Try to determine the real device. vgscan --mknodes would have
# created the links as expected, but our /dev won't actually have
# the device mapper devices since they appeared after the container
# start.
# A workaround for that (see moby#27886) is to bind mount the host's /dev,
# but since we start systemd as well this might/will create issues with
# the host system.
# We workaround that by bind-mounting /dev to /host-dev, so that the host's
# /dev is still available, but we need to determine the correct path
# by ourselves
ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs)
ROOTFS_VOLUME=${ROOTFS_VOLUME/\/dev/\/host-dev}

# Create rootfs filesystem
echo "Creating rootfs filesystem"
mkfs.ext4 -O ^metadata_csum -O ^64bit ${ROOTFS_VOLUME}

# mount the image
echo "Mounting root image"
mkdir -p $IMG_MOUNTPOINT
mount ${ROOTFS_VOLUME} ${IMG_MOUNTPOINT}

# copy rootfs content
echo "Syncing rootfs content"
rsync --archive -H -A -X ${ROOTFS_PATH}/* ${IMG_MOUNTPOINT}
rsync --archive -H -A -X ${ROOTFS_PATH}/.[^.]* ${IMG_MOUNTPOINT}
sync

# Create stamp file
mkdir -p ${IMG_MOUNTPOINT}/var/lib/halium
touch ${IMG_MOUNTPOINT}/var/lib/halium/requires-lvm-resize

# umount the image
echo "umount root image"
umount ${IMG_MOUNTPOINT}

# clean up
vgchange -an droidian

losetup -d ${DEVICE}

img2simg ${WORK_DIR}/userdata.raw ${WORK_DIR}/userdata.img
rm -f ${WORK_DIR}/userdata.raw

# Prepare target zipfile
echo "Preparing zipfile"
if [ ! -d "android-image-flashing-template" ]; then
    apt update
    apt install git -y
    git clone https://github.com/sexynos/android-image-flashing-template
fi
echo ${WORK_DIR}
echo ${ZIP_NAME}
ls ${WORK_DIR}
ls ./
pwd
mkdir -p ${WORK_DIR}/target/data/
rm -r android-image-flashing-template/template/data
cp -R android-image-flashing-template/template/* ${WORK_DIR}/target/
mv ${WORK_DIR}/userdata.img ${WORK_DIR}/target/data/userdata.img

apt update
apt install wget -y
wget https://github.com/Sexynos/droidian-kernel-samsung-exynos9810/releases/download/star2lte/boot-star2lte.img
wget https://github.com/Sexynos/droidian-kernel-samsung-exynos9810/releases/download/star2lte/recovery.img
cp ./boot-star2lte.img ${WORK_DIR}/target/data/boot.img
cp ./recovery.img ${WORK_DIR}/target/data/recovery.img

# generate zip
echo "Generating zip"
mkdir ../../out/
(cd ${WORK_DIR}/target ; zip -r9 ../../out/rootfs.zip * -x .git README.md *placeholder)

echo "done."
