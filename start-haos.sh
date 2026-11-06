#!/usr/bin/env bash
#
# Home Assistant OS QEMU launcher (ARM64 + KVM) with curses debug mode
#

# Boot slot always A for generic imgs.
# 

VM_NAME="haos"
VM_DIR="/opt/vz/haos_vm/16.3"
QCOW2="$VM_DIR/haos_generic-aarch64-16.3.qcow2"
KERNEL="$VM_DIR/haos_kernel/Image"
BIOS="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"

MONITOR_SOCKET="/run/qemu-haos.monitor"
CONSOLE_SOCKET="/run/qemu-haos.console"

# Autoconnect to VM
USB_DEVICES=(
    "0x10c4:0xea60"  # SkyConnect
    "0x1a86:0x7523"  # CH340
)

RAM_MB="2048"

cleanup_sockets() {
    rm -f "$MONITOR_SOCKET" "$CONSOLE_SOCKET"
}

detect_bootslot() {
    state_file="$VM_DIR/last-slot"
    [[ -f "$state_file" ]] && SLOT=$(cat "$state_file") || SLOT="A"
    echo "$SLOT"
}

write_slot_state() {
    echo "$1" > "$VM_DIR/last-slot"
}

attach_usb_device() {
    local VENDOR="$1"
    local PRODUCT="$2"
    echo "[INFO] Attaching USB device vendor=$VENDOR product=$PRODUCT"
    socat - UNIX-CONNECT:$MONITOR_SOCKET <<EOT
device_add usb-host,vendorid=$VENDOR,productid=$PRODUCT,bus=xhci.0,id=usb$(date +%s)
EOT
}

attach_all_default_usb() {
    for dev in "${USB_DEVICES[@]}"; do
        VENDOR=${dev%%:*}
        PRODUCT=${dev##*:}
        attach_usb_device "$VENDOR" "$PRODUCT"
    done
}

start_vm() {
    SLOT=$(detect_bootslot)
    cleanup_sockets
    echo "[INFO] Starting HAOS VM on slot $SLOT"

    sudo qemu-system-aarch64 \
        -name "$VM_NAME" \
        -machine virt,accel=kvm \
        -cpu host \
        -m "$RAM_MB" \
        -bios "$BIOS" \
        -kernel "$KERNEL" \
        -append "console=ttyAMA0 rootwait root=PARTUUID=8d3d53e3-6d49-4c38-8349-aff6859e82fd zram.enabled=1 zram.num_devices=3 fsck.repair=yes rauc.slot=$SLOT" \
        -drive if=none,id=hd,file="$QCOW2",format=qcow2 \
        -device virtio-blk-pci,drive=hd \
        -device qemu-xhci,id=xhci \
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
        -device virtio-net-pci,netdev=net0 \
        -monitor unix:$MONITOR_SOCKET,server,nowait \
        -serial unix:$CONSOLE_SOCKET,server,nowait \
        -nographic \
        -D "$VM_DIR/qemu.log" &
    sleep 2
    attach_all_default_usb
}

stop_vm() {
    echo "[INFO] Stopping VM via QMP"
    socat - UNIX-CONNECT:$MONITOR_SOCKET <<< "system_powerdown"
    sleep 3
}

kill_vm() {
    echo "[INFO] Killing VM"
    pkill -f "qemu-system-aarch64.*$VM_NAME"
    cleanup_sockets
}

show_conf() {
    echo "=== HAOS VM CONFIGURATION ==="
    echo "VM Name: $VM_NAME"
    echo "QCOW2: $QCOW2"
    echo "Kernel: $KERNEL"
    echo "BIOS: $BIOS"
    echo "RAM: ${RAM_MB}MB"
    echo "Boot slot: $(detect_bootslot)"
    echo "Monitor socket: $MONITOR_SOCKET"
    echo "Console socket: $CONSOLE_SOCKET"
    echo "USB devices: ${USB_DEVICES[*]}"
    echo "--- QEMU processes ----------"
    ps -flp "`pgrep qemu`"
    echo "-----------------------------"
}

### --- DEBUG MODE WITH CURSES --- ###
text_ui() {
    # Requires: dialog or whiptail installed for simple TUI
    while true; do
        cmd=$(whiptail --title "HAOS VM Debug" \
            --menu "Select action:" 20 60 10 \
            "1" "Start VM" \
            "2" "Stop VM" \
            "3" "Kill VM" \
            "4" "Show VM config" \
            "5" "Console" \
            "6" "Monitor" \
            "7" "Attach default USBs" \
            "0" "Exit" 3>&1 1>&2 2>&3)

        case $cmd in
            1) start_vm ;;
            2) stop_vm ;;
            3) kill_vm ;;
            4) show_conf ;;
            5) /opt/vz/haos_vm/start-haos.sh console ;;
            6) /opt/vz/haos_vm/start-haos.sh monitor ;;
            7) attach_all_default_usb ;;
            0) break ;;
            *) echo "Unknown option" ;;
        esac
        sleep 4
    done
}

### --- COMMAND PARSER --- ###
case "$1" in
    start) start_vm ;;
    stop) stop_vm ;;
    kill) kill_vm ;;
    console) socat -,raw,echo=0 UNIX-CONNECT:$CONSOLE_SOCKET ;;
    monitor) socat readline UNIX-CONNECT:$MONITOR_SOCKET ;;
    usb-attach) [[ -n "$2" && -n "$3" ]] && attach_usb_device "$2" "$3" || attach_all_default_usb ;;
    list-usb) for dev in "${USB_DEVICES[@]}"; do echo "  $dev"; done ;;
    lsusb) lsusb ;;
    tui) text_ui ;;
    conf*) show_conf;;
    *)
        echo "Usage: $0 {start|stop|kill|console|monitor|usb-attach [vendor product]|list-usb|lsusb|conf|tui}"
        exit 1 ;;
esac
