# VirtualHA
vHA - Virtualized Home Assistant tool running KVM accelerated QEMU VM on ARM64(aarch64).

It will run an unmodified official virtualized build of Home Assistant distributed as an qcow2-file.
It will run HaOS in an Virtual Machine om some ARM SBC together with Docker Compose on a common host running vanilla Ubuntu.
No need to do an own limited installation of "HA core" in a single container, Get it all. 

Hopefully HA will run stable with HaOS there is no need to have Proxmox or graphical tools for QEMU/KVM.
Keep it (virtual) simple, but let me take care om my host Docker Compose myself.

The script haosctl.sh can start and stop HaOS manualy or be used as a systemd-service with a unit file, haos.service.
Systemd Unit-file haos.service must be installed and haos enabled and started with systemd to start at boot time.

The vHA systemd service will be joined by the vHA Status Display, a python tool using an LCD display to show the host's CPU load, HA status etc.

The haosctl.sh script contains a persistent patch to the HaOS image to shutdown HaOS in a safe way and and boot up again after an "ha host reboot".

## Installation

Packages needed:
  QEMU/KVM and dependencies,
  qemu-efi-aarch64.

Files:
  haosctl.sh
  aos.service


Configure and run manually.
Edit path to qcow2-file.
Configure RAM size, number of CPUs.

```sh
armhost:/opt/vz/haos_vm# nano ./haosctl.sh 
armhost:/opt/vz/haos_vm# ./haosctl.sh run
Network ready: tap0 attached to br0.
Starting HAOS (SMP# 2 affinity: 4,5).
...
```


### Run HaOS as a service starting at boot time.
```sh
$ cp haos.service /etc/systemd/system/
$ ls -l /etc/systemd/system/haos.service
$ systemctl daemon-reload
$ systemctl enable haos.service
$ systemctl status haos.service
$ ./haosctl.sh stop
$ systemctl start haos.service
$ systemctl status haos.service
```

If VM process dies, it will be restarted.
```sh
$ journalctl -u haos.service -b -n 10
Nov 12 23:20:16 rock-4se systemd[1]: haos.service: Main process exited, code=killed, status=9/KILL
Nov 12 23:20:16 rock-4se systemd[1]: haos.service: Failed with result 'signal'.
Nov 12 23:20:16 rock-4se systemd[1]: haos.service: Consumed 2min 46.070s CPU time.
Nov 12 23:20:26 rock-4se systemd[1]: haos.service: Scheduled restart job, restart counter is at 1.
Nov 12 23:20:26 rock-4se systemd[1]: Stopped Home Assistant OS 16.3+ in QEMU/KVM.
Nov 12 23:20:26 rock-4se systemd[1]: haos.service: Consumed 2min 46.070s CPU time.
Nov 12 23:20:26 rock-4se systemd[1]: Starting Home Assistant OS 16.3+ in QEMU/KVM...
Nov 12 23:20:26 rock-4se systemd[1]: Started Home Assistant OS 16.3+ in QEMU/KVM.
Nov 12 23:20:27 rock-4se haosctl.sh[2622929]: Network ready: tap0 attached to br0.
Nov 12 23:20:27 rock-4se haosctl.sh[2622929]: Starting HAOS (SMP# 2 affinity: 4,5).
```

## Usage
```sh
armhost$ ./haosctl.sh -h

Usage: ./haosctl.sh {run|stop|status|check-network|
                     console|monitor|patch-poweroff [ssh-target]|
                     show-qemu-command}

  Simple ARM SBC script utility to start HAOS in a KVM accelerated
  QEMU Virtual machine. Run HAOS as a systemd service at boot time.
  Use an official unmodified qcow2-file.
  Simple configuration in top of script.

  QEMU more suited for Virtualized Home Assistant than a pure KVM.
  Better usability. No need for Poxmox or virt-tools, GUI etc.

   run               start used manually or by the systemd service
   stop              stop both Arm Virtual machine and Home Assistant

   status            Show information like pid, cmdline parameters,
                     files and resources needed for normal function.
                     Important to check test are okay!

   show-qemu-command qemu command line to run
                     Currently configured for SkyConnect Zigbee and
                     an USB-Modbus stick.

   check-network     Check tap0 interface (asumes tap0 is used for VM
                     bridged to eth0 with br0).

   kill-console      Free the console socket for script usage.
                     'status' and 'check-poweroff' use the console
                     to check HAOS properly configured.

   check-poweroff    Check if virtual poweroff button works properly.

   patch-poweroff    Generate pachfile to copy abd run on HAOS
                     to enable safe HAOS reboot or shutdown.


   monitor           Connect to QEMUs mgmt console

   console           Connect to HaOS virtual serial console.
                     See some boot/reboot messages like:


armhost$ ./haosctl.sh console
Welcome to Home Assistant
homeassistant login:

# ha host reboot
Command completed successfully.
# [41286.975079] reboot: Restarting system

                     GNU GRUB  version 2.12

 /------------------------------------------------------------------\
 | Slot A (OK=1 TRY=0)                                              |
 |*Slot B (OK=1 TRY=1)                                              |
 | Slot A (rescue shell)                                            |
 | Slot B (rescue shell)                                            |
 |                                                                  |
 \------------------------------------------------------------------/

Welcome to Home Assistant
homeassistant login:

Welcome to Home Assistant OS.

Use `ha` to access the Home Assistant CLI.
#
```
