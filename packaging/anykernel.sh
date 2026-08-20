### AnyKernel3 Ramdisk Mod Script

properties() { '
kernel.string=6sp Droidspaces Kernel r1 (Thin LTO + KernelSU v3.2.5)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=sheng
supported.versions=16
supported.patchlevels=2026-06 - 2026-06
supported.vendorpatchlevels=2026-02 - 2026-02
'; }

BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_VBMETA_PARTITION_PATCH=1;

. tools/ak3-core.sh;

# Xiaomi Pad 6S Pro keeps the Android 13+ generic ramdisk in init_boot.
# Replace only the kernel payload in the active-slot boot image.
split_boot;
flash_boot;
