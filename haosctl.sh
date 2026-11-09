#!/usr/bin/env bash
# HAOS QEMU controller - Stage A (test candidate; not installed automatically)
set -Eeuo pipefail

VM_NAME=haos
BASE=/opt/vz/haos_vm/16.3
QCOW="$BASE/haos_generic-aarch64-16.3.qcow2"
KERNEL="$BASE/haos_kernel/Image"
EFI=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
PARTUUID=8d3d53e3-6d49-4c38-8349-aff6859e82fd
RAM_MB=2048
MONITOR_SOCK=/run/qemu-haos-monitor.sock
CONSOLE_SOCK=/run/qemu-haos-console.sock
LOGFILE="$BASE/qemu_haos.log"

require_root() {
    if (( EUID != 0 )); then
        echo 'ERROR: this action requires root (sudo).' >&2
        exit 1
    fi
}

check_network() {
    local i master
    for ((i=0; i<30; i++)); do
        if ip link show br0 >/dev/null 2>&1 &&
           ip link show tap0 >/dev/null 2>&1; then
            master=$(basename "$(readlink -f /sys/class/net/tap0/master 2>/dev/null || true)")
            if [[ "$master" == br0 ]] &&
               ip -o link show tap0 | grep -q '<[^>]*UP' &&
               ip -o link show br0 | grep -q '<[^>]*UP'; then
                echo 'Network ready: tap0 attached to br0; both administratively UP.'
                return 0
            fi
        fi
        sleep 1
    done
    echo 'ERROR: tap0/br0 not ready. Inspect nmcli connection show --active and bridge link show.' >&2
    return 1
}

build_qemu_cmd() {
    CMD=(
        qemu-system-aarch64
        -name "$VM_NAME"
        -machine virt,accel=kvm
        -cpu host
        -m "$RAM_MB"
        -bios "$EFI"
        -kernel "$KERNEL"
        -append "console=ttyAMA0 root=PARTUUID=$PARTUUID rootwait zram.enabled=1 zram.num_devices=3 systemd.machine_id=00000000000000000000000000000000 fsck.repair=yes systemd.condition-first-boot=true rauc.slot=A"
        -drive "id=hd,if=none,format=qcow2,file=$QCOW"
        -device virtio-blk-pci,drive=hd
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
        -device virtio-net-pci,netdev=net0
        -chardev "socket,id=con0,path=$CONSOLE_SOCK,server=on,wait=off"
        -serial chardev:con0
        -monitor "unix:$MONITOR_SOCK,server=on,wait=off"
        -D "$LOGFILE"
        -nographic
        -device qemu-xhci
        -device usb-host,vendorid=0x10c4,productid=0xea60
    )
}

run_vm() {
    require_root
    check_network
    [[ -f "$QCOW" && -f "$KERNEL" && -f "$EFI" ]] || {
        echo 'ERROR: Missing QCOW2, kernel or EFI file.' >&2
        exit 1
    }
    # Refuse to touch sockets if the existing manually launched VM is still running.
    if pgrep -af "^qemu-system-aarch64 -name $VM_NAME( |$)" >/dev/null; then
        echo "ERROR: $VM_NAME QEMU is already running. Stop it before systemd handover." >&2
        exit 1
    fi
    rm -f -- "$MONITOR_SOCK" "$CONSOLE_SOCK"
    build_qemu_cmd
    echo 'Starting HAOS under systemd (foreground QEMU).'
    exec "${CMD[@]}"
}

stop_vm() {
    require_root
    [[ -S "$MONITOR_SOCK" ]] || {
        echo 'ERROR: HMP socket missing; cannot request graceful shutdown.' >&2
        return 1
    }
    echo 'Requesting HAOS shutdown via QEMU HMP system_powerdown.'
    # Keep this command short: systemd supervises the actual QEMU process.
    printf 'system_powerdown\n' | timeout 5 socat -T 2 - "UNIX-CONNECT:$MONITOR_SOCK" >/dev/null
    # Do not kill QEMU here. systemd waits for ExecStart's process to exit.
}

status_vm() {
    systemctl status haos.service --no-pager 2>/dev/null || true
    echo '--- Network ---'
    ip -br link show br0 tap0 2>/dev/null || { ip -br link show br0 2>/dev/null || true; ip -br link show tap0 2>/dev/null || true; }
    bridge link show dev tap0 2>/dev/null || true
    echo '--- QEMU ---'
    pgrep -af '[q]emu-system-aarch64' || true
    echo '--- Sockets ---'
    ls -l "$MONITOR_SOCK" "$CONSOLE_SOCK" 2>/dev/null || true
}

connect_socket() {
    local sock=$1
    [[ -S "$sock" ]] || { echo "Socket not found: $sock" >&2; return 1; }
    exec socat -,raw,echo=0 "UNIX-CONNECT:$sock"
}

case "${1:-}" in
    run) run_vm ;;
    check-network) check_network ;;
    stop) stop_vm ;;
    status) status_vm ;;
    console) connect_socket "$CONSOLE_SOCK" ;;
    monitor) connect_socket "$MONITOR_SOCK" ;;
    show-command)
        build_qemu_cmd
        printf '%q ' "${CMD[@]}"
        printf '\n'
        ;;
    *) echo "Usage: $0 {run|check-network|stop|status|console|monitor|show-command}" >&2; exit 2 ;;
esac
