#!/bin/bash
#i##########################################
# Home Assistant OS QEMU Controller
#
# All-in-one management script
# Note: fixed VM name 

# startscript and service file as genertaed by ChatGPT
# https://chatgpt.com/c/68ed2905-6af8-8328-9594-7741a3a9f0c0

# Notes:
# console=ttyAMA0 console=tty0
# addad staus_vm() for debug info
# digging some config info and qemu info
# tty0 needed by EFI if booting in grapical console

############################################
# CONFIGURATION
############################################

VM_NAME="haos"
BASE="/opt/vz/haos_vm/16.3"

QCOW="$BASE/haos_generic-aarch64-16.3.qcow2"
KERNEL="$BASE/haos_kernel/Image"
PARTUUID="8d3d53e3-6d49-4c38-8349-aff6859e82fd"
EFI="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"

RAM_MB=2048

# SkyConnect USB
USB_VENDOR="0x10c4"
USB_PRODUCT="0xea60"
USE_USB=true   # set to false to disable usb-host

# RS485
# 1a86:7523 QinHeng Electronics CH340 serial converter

# Runtime sockets
MONITOR_SOCK="/run/qemu-$VM_NAME-monitor.sock"
CONSOLE_SOCK="/run/qemu-$VM_NAME-console.sock"
PIDFILE="/run/qemu-$VM_NAME.pid"

LOGFILE="$BASE/qemu_${VM_NAME}.log"

# CMD array for VM start command
CMD=()

############################################
# INTERNAL QEMU COMMAND BUILDE
# bugfix 
# nowait => wait=off
# \ in () topreserve "
############################################

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
        -drive id=hd,if=none,format=qcow2,file="$QCOW"
        -device virtio-blk-pci,drive=hd

        # NETWORK
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
        -device virtio-net-pci,netdev=net0

        # SERIAL CONSOLE (UNIX SOCKET)
        -chardev socket,id=con0,path="$CONSOLE_SOCK",server=on,wait=off
        -serial chardev:con0

        # QMP MONITOR, HMP mode (readline
        #-qmp unix:"$MONITOR_SOCK",server=on,wait=off,mode=readline
        -monitor unix:"$MONITOR_SOCK",server=on,wait=off

        # LOG
        -D "$LOGFILE"

        # HEADLESS
        -nographic
    )

    # Optional USB passthrough
    if [ "$USE_USB" = true ]; then
        CMD+=(-device "qemu-xhci")
        CMD+=(-device "usb-host,vendorid=$USB_VENDOR,productid=$USB_PRODUCT")
    fi
    # more USB devices...?
}

############################################
# ACTIONS
############################################

start_vm() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "VM already running (PID $(cat "$PIDFILE"))."
        exit 0
    fi

    echo "Starting HAOS virtual machine..."
    rm -f "$MONITOR_SOCK" "$CONSOLE_SOCK"

    build_qemu_cmd

    MAX_ATTEMPTS=10

    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
        echo "Attempt $attempt: starting process..."

        # Start the process in background
	"${CMD[@]}" &
        PID=$!

        # Wait for startup or failure
	sleep 1
        if  kill -0 "$PID" 2>/dev/null; then
            echo "$PID" > "$PIDFILE"
            echo "VM started with PID $PID"
            break
        fi

        wait "$PID"	
        echo "Process died early. Retrying..."
	
    done
}

stop_vm() {
    if [ ! -f "$PIDFILE" ]; then
        echo "VM not running (no PID file)."
        exit 1
    fi

    PID=$(cat "$PIDFILE")
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "Stale PID file. Removing."
        rm -f "$PIDFILE"
        exit 1
    fi

    echo "Sending graceful shutdown (HMP system_powerdown)..."

    if [ -S "$MONITOR_SOCK" ]; then
        #QM-P>HMP
        #printf '{ "execute": "system_powerdown" }\n' |\
        printf 'system_powerdown' |\
        socat - UNIX-CONNECT:"$MONITOR_SOCK"
    else
        echo "HMP socket missing. Killing VM directly."
        kill "$PID"
        rm -f "$PIDFILE"
        exit 0
    fi

    # Wait up to 20 seconds for clean exit
    for i in {1..20}; do
        if ! kill -0 "$PID" 2>/dev/null; then
            echo "VM stopped cleanly."
            rm -f "$PIDFILE"
            return
        fi
        sleep 1
    done

    echo "Graceful shutdown timed out. Forcing kill..."
    kill -9 "$PID"
    rm -f "$PIDFILE"
}

monitor_vm() {
    if [ ! -S "$MONITOR_SOCK" ]; then
        echo "No monitor socket found."
        exit 1
    fi
    echo "Connecting to QEMU monitor..."
    #socat - UNIX-CONNECT:"$MONITOR_SOCK"
    # For iHMP text mode
    socat -,raw,echo=0 UNIX-CONNECT:"$MONITOR_SOCK"
}

console_vm() {
    if [ ! -S "$CONSOLE_SOCK" ]; then
        echo "No console socket found."
        exit 1
    fi
    echo "Connecting to VM serial console (Ctrl+] to exit)"
    socat -,raw,echo=0 UNIX-CONNECT:"$CONSOLE_SOCK"
}

status_vm() {
    echo "### HAOS VM Config (this script config)
    VM name  : $VM_NAME
    BASE     : $BASE
    Disk     : $QCOW
    KERNEL   : $KERNEL
    PARTUUID : $PARTUUID
    EFI boot : $EFI
    LOGFILE  : $LOGFILE "
    #MONITOR_SOCK="/run/qemu-$VM_NAME-monitor.sock"
    #CONSOLE_SOCK="/run/qemu-$VM_NAME-console.sock"
    #PIDFILE  : cat "/run/qemu-$VM_NAME.pid"


    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "VM is running (PID $(cat "$PIDFILE"))."
    else
        echo "VM is stopped."
    fi
    if [ -S "$MONITOR_SOCK" ]; then
        printf '### QEMU status ###'
        echo 'info status
        info name
        info usb
        info cpus'|\
        socat - UNIX-CONNECT:"$MONITOR_SOCK"
    fi
    echo "### haos/qemu related proesses ###"
    pgrep -la haosctl
    pgrep -la qemu |\
    awk '{print($1 " " $2 " " $3 " " $4 " " $5 " " $6 " ...")}' 

}

############################################
# MAIN
############################################

case "$1" in
    start) start_vm ;;
    stop) stop_vm ;;
    status) status_vm ;;
    console) console_vm ;;
    monitor) monitor_vm ;;
    *)
        echo "Usage: $0 {start|stop|status|console|monitor}"
        exit 1
        ;;
esac
