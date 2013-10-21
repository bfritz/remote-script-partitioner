# Remote Script Partitioner

Partition Debian disks with PXE and shell script instead of complex
preseed templates.

Advanced partitioning of Debian boxes with preseed templates can be a
challange.  `remote-script-partitioner` makes it easy to bypass the
built-in templates and write a shell script to partition your disks.

This package disables `partman` in the Debian installer, downloads
your `partitioner` script via TFTP and executes it.

### Building

Packages are built with Jordan Sissel's `fpm` so install it first,
e.g. `gem install fpm`.

```bash
make udeb
```

### Configuration

The partitioner expects `tftp_server` to be set on the kernel
command line.  It downloads and executes a script named
`partitioner` from the root of the TFTP server.

```bash
$ cat /proc/cmdline
[..] tftp_server=192.168.56.1
```

Example from `debian-preseed`:<br/>
<https://github.com/bfritz/debian-preseed/blob/scripted-partitioning/config/preseed.cfg.in#L4>

The partitioner package can be downloaded and run from
`preseed/early_command`, e.g.:

```bash
d-i preseed/early_command string \
  tftp -g 192.168.56.1 -r remote-script-partitioner_0.0.1_all.udeb -l /tmp/partitioner.udeb \
  && udpkg --unpack /tmp/partitioner.udeb
```

Example from `debian-preseed`:<br/>
<https://github.com/bfritz/debian-preseed/blob/scripted-partitioning/config/vbox.conf#L21>


### Script Example

Below is an example script for GPT + dm-crypt + LVM.  This script:

* partitions the first disk with a GUID Partition Table (GPT)
* creates a small `biosboot` partition, 500MB `boot` partition
  and uses the rest of the first disk for an encrypted partition
* encrypts the large patition with `cryptsetup`
* adds the encrypted partition to a LVM volume group
* creates 1G `/` and 2G `/home` volumes with ext4 partitions

**CAUTION**: If you use this script as-is, change the encryption key
afterward, e.g.  `cryptsetup luksChangeKey /dev/sda3 --verify-passphrase`!

```bash
#!/bin/sh

set -e

PV_NAME=vg0
FS=ext4
BOOT_SIZE=500MB
ROOT_SIZE=1G
HOME_SIZE=2G
PASSPHRASE=t0ps3cr3t

BOOT_PART_N=2
CRYPT_PART_N=3

# TAG variable is exported from `postinst.sh` in package before
# executing this script.

FIRST_DISK=$(list-devices disk | head -n1)
logger -t "$TAG" "FIRST_DISK: $FIRST_DISK"

BOOT_DEV=$FIRST_DISK$BOOT_PART_N
logger -t "$TAG" "BOOT_DEV: $BOOT_DEV"

# partition $FIRST_DISK with GUID partition table
anna-install parted-udeb

dd if=/dev/zero of=$FIRST_DISK bs=1M count=1

logger -t "$TAG" "Cleared old partition table by writing zeros to start of $FIRST_DISK ."

logger -t "$TAG" "Partitioning $FIRST_DISK ."
log-output -t "$TAG" parted                -- $FIRST_DISK mklabel gpt
log-output -t "$TAG" parted                -- $FIRST_DISK mkpart biosboot 8192s 16383s
log-output -t "$TAG" parted                -- $FIRST_DISK set 1 bios_grub on

log-output -t "$TAG" parted --align=opt    -- $FIRST_DISK mkpart boot 16384s $BOOT_SIZE
log-output -t "$TAG" parted                -- $FIRST_DISK set 2 boot on

log-output -t "$TAG" parted --align=opt -s -- $FIRST_DISK mkpart pv_$PV_NAME $BOOT_SIZE -1

log-output -t "$TAG" parted                -- $FIRST_DISK print


# install cryptsetup and necessary crypto modules
anna-install crypto-modules crypto-dm-modules cryptsetup-udeb

depmod -ae
modprobe dm-mod
modprobe dm-crypt
modprobe aes

DEV="$FIRST_DISK$CRYPT_PART_N"
CRYPT_NAME=`echo $DEV | cut -d/ -f3`_crypt
KEYFILE=/tmp/keyfile

if [ ! -b "$DEV" ]; then
    error "$DEV is not a block special device, refusing to encrypt it."
    exit 1
fi

logger -t "$TAG" "Making $DEV an encrypted partition"
if [ ! -e "$KEYFILE" ]; then
    echo -n "$PASSPHRASE" > "$KEYFILE"
    logger -t "$TAG" 'Using WEAK PASSPHRASE!!! Change key after installation finishes!'
fi

#logger -t "$TAG" "Zeroing $DEV prior to setting up LUKS encryption."
#log-output -t "$TAG" dd if=/dev/zero of="$DEV" bs=1M

echo YES | log-output -t "$TAG" cryptsetup -d "$KEYFILE" luksFormat "$DEV"

log-output -t "$TAG" cryptsetup -d "$KEYFILE" luksOpen "$DEV" $CRYPT_NAME

# install LVM tools and create volume groups
anna-install lvm2-udeb

log-output -t "$TAG" pvcreate /dev/mapper/$CRYPT_NAME
log-output -t "$TAG" vgcreate $PV_NAME /dev/mapper/$CRYPT_NAME

log-output -t "$TAG" lvcreate -n root -L $ROOT_SIZE $PV_NAME
log-output -t "$TAG" lvcreate -n home -L $HOME_SIZE $PV_NAME

# partition /boot and LVM volumes
log-output -t "$TAG" mkfs.$FS -L boot $BOOT_DEV

for F in root home; do
    log-output -t "$TAG" mkfs.$FS -L $F /dev/mapper/${PV_NAME}-$F
done

# Debian installer expects partitions mounted at /target
mkdir -p /target
mount -t $FS /dev/mapper/${PV_NAME}-root /target

mkdir /target/boot
mount -t $FS $BOOT_DEV /target/boot

for F in home; do
    mkdir /target/$F
    mount -t $FS /dev/mapper/${PV_NAME}-$F /target/$F
done

eval `blkid -o udev $BOOT_DEV`
logger -t "$TAG" "UUID of boot device ($BOOT_DEV) is $ID_FS_UUID"

logger -t "$TAG" "Preparing /etc/fstab"
mkdir /target/etc
cat <<EOF > /target/etc/fstab
/dev/mapper/${PV_NAME}-root /     $FS defaults,noatime 0 1
UUID=$ID_FS_UUID  /boot $FS defaults,ro      0 1
EOF

for F in home; do
    echo "/dev/mapper/${PV_NAME}-$F /$F $FS defaults,noatime 0 2" >> /target/etc/fstab
done

CRYPT_DEV_UUID=`cryptsetup luksUUID "$DEV"`
logger -t "$TAG" "UUID of encrypted device ($DEV) is $CRYPT_DEV_UUID"
echo "$CRYPT_NAME UUID=$CRYPT_DEV_UUID none luks" > /target/etc/crypttab

logger -t "$TAG" "Installing cryptsetup and lvm2 packages to target system."
log-output -t "$TAG" apt-install cryptsetup || true
log-output -t "$TAG" apt-install lvm2 || true

debconf-set grub-installer/bootdev $FIRST_DISK

# long sleep can be handy for debugging, e.g. to inspect /var/log/syslog
# sleep 180
```
