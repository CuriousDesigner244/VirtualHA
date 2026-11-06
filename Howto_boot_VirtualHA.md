# vHA - Home Assistant QEMU/KVM virtualized on ARM64

## Innstall QEMU & KVM

## Configure br0 and tap0 

## First boot

````sh
$ sudo qemu-system-aarch64 \
    -name haos \
    -machine virt,accel=kvm \
    -cpu host \
    -m 2048 \
    -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
    -drive if=none,id=hd,format=qcow2,file=/opt/vz/haos_vm/16.3/haos_generic-aarch64-16.3.qcow2 \
    -device virtio-blk-pci,drive=hd \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -kernel /opt/vz/haos_vm/16.3/haos_kernel/Image \
    -append "console=ttyS0 console=ttyS0 console=tty0 root=PARTUUID=8d3d53e3-6d49-4c38-8349-aff6859e82fd rootwait zram.enabled=1 zram.num_devices=3 systemd.machine_id=00000000000000000000000000000000 fsck.repair=yes systemd.condition-first-boot=true rauc.slot=A" \
    -nographic -serial mon:stdio \
    -D /opt/vz/haos_vm/16.3/qemu_haos.log
EFI stub: Booting Linux Kernel...
EFI stub: EFI_RNG_PROTOCOL unavailable
EFI stub: Generating empty DTB
EFI stub: Exiting boot services...
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd082]
[    0.000000] Linux version 6.12.51-haos (builder@113c92a9d172) (aarch64-buildroot-linux-gnu-gcc.br_real (Buildroot -g02f1553a) 13.4.0, GNU ld (GNU Binutils) 2.43.1) #1 SMP PREEMPT Tue Nov  4 14:21:05 UTC 2025
.
.
.
Welcome to Home Assistant
homeassistant login: root
Welcome to Home Assistant OS.

Use `ha` to access the Home Assistant CLI.
#
````

## HAOS extract kernel on Ubuntu/WSL2 Windows machine

HAOS uses erofs not supported on Radxa Ubuntu 22.04 LTS B38
Fix it

````sh
  https://github.com/home-assistant/operating-system/releases
  wget https://github.com/home-assistant/operating-system/releases/download/16.3/haos_generic-aarch64-16.3.qcow2.xz

  sudo qemu-nbd -d /dev/nbd0
  sudo qemu-nbd -c /dev/nbd0 haos_generic-aarch64-16.3.qcow2

  sudo fdisk -l /dev/nbd0
  sudo file /dev/nbd0*

  sudo mkdir /mnt/haos_boot/
  sudo mount /dev/nbd0p1 /mnt/haos_boot
  sudo mkdir /mnt/haos_kernel/
  sudo mount /dev/nbd0p2 /mnt/haos_kernel

  USB stick on Windows D:
  sudo mount -t drvfs D: /mnt/d

  sudo tar cvf /mnt/d/extracted.tar ./haos_boot/ ./haos_kernel/
  ./haos_boot/
  ./haos_boot/EFI/
  ./haos_boot/EFI/BOOT/
  ./haos_boot/EFI/BOOT/grubenv
  ./haos_boot/EFI/BOOT/bootaa64.efi
  ./haos_boot/EFI/BOOT/grub.cfg
  ./haos_boot/cmdline.txt
  ./haos_kernel/
  ./haos_kernel/Image

````
Repack(?) to qcow2 file.
