#!/usr/bin/env bash
#
# HAOS QEMU controller
# Configured for Rock 4SE mixed Cortex-A53/-A72
# running HAOS 16.3 in a KVM accelerated QEMU VM.
# Intergrated in Ubuntu as a systemd-service.
#
set -Eeuo pipefail

VM_NAME=haos
RAM_MB=2048
# Number of SMP cpus for VM
QEMU_CPUS=2
# ARM SBC Survey (teaser)
# Rock4 Rockchip RK3399,    (cpu#)
#    2 x     Arm Cortex-A72 (4,5),
#    4 x               -A53 (0-3)
# Rock5B Rockchip RK3588 (#cpus=8)
#    4 x Arm Cortex-A76
#    4 x     Cortex-A55
# Radxa Dragon Q8B, 8 cores
#    Snapdragon gen 3 / SC8280XP
#    4 x ARM Cortex-X1
#    4 x ARM Cortex-A78
#
# Rasperry pi 4,
#    4 x ARM Cortex-A72     (0-3)
# Rasperry Pi 5, BCM2712
#    4 x Arm Cortex-A76     (0-3)
#
# Use Rock4SE faster Cortex-A72 cpu cores for HAOS
QEMU_CPU_AFFINITY="4,5"
START_LOCK=/run/qemu-haos-start.lock

# BASE dir for qcow2-disk file
# Consider where to put qcow2 disk file
BASE=/opt/vz/haos_vm/16.3AB
QCOW="$BASE/haos_generic-aarch64-16.3.qcow2"

# To pass bootparams, boot extracted kernel
KERNEL="$BASE/haos_kernel/Image"
PARTUUID=8d3d53e3-6d49-4c38-8349-aff6859e82fd

# EFI can find and load HAOS GRUB or
# extracted kernel/Image boot file
EFI="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"

MONITOR_SOCK=/run/qemu-haos-monitor.sock
CONSOLE_SOCK=/run/qemu-haos-console.sock
QMP_SOCK=/run/qemu-haos-qmp.sock
LOGFILE="$BASE/qemu_haos.log"

require_root() {
    if (( EUID != 0 )); then
        echo "ERROR: root privileges required." >&2
        exit 1
    fi
}

qemu_pids() {
    # Match QEMU itself, not an unrelated shell containing the command line.
    local pid cmd arg previous
    for pid_dir in /proc/[0-9]*; do
        pid=${pid_dir##*/}
        [[ -r "$pid_dir/comm" && -r "$pid_dir/cmdline" ]] || continue
        read -r cmd < "$pid_dir/comm" || continue
        [[ "$cmd" == qemu-system-aar* ]] || continue
        previous=""
        while IFS= read -r -d '' arg; do
            if [[ "$previous" == "-name" && ( "$arg" == "$VM_NAME" || "$arg" == "$VM_NAME,"* ) ]]; then
                printf '%s\n' "$pid"
                break
            fi
            previous=$arg
        done < "$pid_dir/cmdline"
    done
}

qemu_running() {
    [[ -n "$(qemu_pids)" ]]
}

wait_for_exit() {
    local seconds=$1
    local i

    for ((i=0; i<seconds; i++)); do
        if ! qemu_running; then
            echo "QEMU has exited."
            return 0
        fi
        sleep 1
    done

    ! qemu_running
}

check_network() {
    local i master

    for ((i=0; i<30; i++)); do
        if [[ -e /sys/class/net/br0 &&
              -e /sys/class/net/tap0 ]]; then

            master=$(
                basename "$(
                    readlink -f /sys/class/net/tap0/master \
                        2>/dev/null || true
                )"
            )

            if [[ "$master" == br0 ]] &&
               ip -o link show dev br0 |
                   grep -q '<[^>]*UP' &&
               ip -o link show dev tap0 |
                   grep -q '<[^>]*UP'; then

                echo "Network ready: tap0 attached to br0."
                return 0
            fi
        fi

        sleep 1
    done

    echo "ERROR: tap0/br0 not ready." >&2
    return 1
}

build_qemu_cmd() {
    CMD=(
        qemu-system-aarch64
        -name "$VM_NAME"
        -machine virt,accel=kvm
        -cpu host
	-smp "$QEMU_CPUS"  # Number of CPUs
        -m "$RAM_MB"
        -bios "$EFI"
        #-kernel "$KERNEL"
        #-append "console=ttyAMA0 root=PARTUUID=$PARTUUID rootwait zram.enabled=1 zram.num_devices=3 systemd.machine_id=00000000000000000000000000000000 fsck.repair=yes systemd.condition-first-boot=true rauc.slot=A"
        #-append "console=ttyAMA0"
        -drive "id=hd,if=none,format=qcow2,file=$QCOW"
        -device virtio-blk-pci,drive=hd
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
        -device virtio-net-pci,netdev=net0
        -chardev "socket,id=con0,path=$CONSOLE_SOCK,server=on,wait=off"
        -serial chardev:con0
        -monitor "unix:$MONITOR_SOCK,server=on,wait=off"
	-qmp "unix:$QMP_SOCK,server=on,wait=off"
        -nographic
        -device qemu-xhci
        -device usb-host,vendorid=0x10c4,productid=0xea60  # usb devs
    )
}

run_vm() {
    require_root

    # Nonblocking lock serializes simultaneous controller starts. The lock FD
    # remains open across exec and is released when QEMU exits.
    exec {START_LOCK_FD}>"$START_LOCK"
    if ! flock -n "$START_LOCK_FD"; then
        echo "ERROR: Another HAOS start/VM instance holds the lock." >&2
        return 1
    fi
    
    if qemu_running; then
        echo "ERROR: HAOS QEMU already running." >&2
        return 1
    fi

    if ! check_network; then
        nmcli connection up tap0
        check_network
    fi

    [[ -f "$QCOW" && -f "$EFI" ]] || {
        echo "ERROR: Missing VM image or EFI." >&2
        return 1
    }

    # Only remove stale sockets when QEMU is stopped.
    rm -f -- "$MONITOR_SOCK" "$CONSOLE_SOCK" "$QMP_SOCK"

    build_qemu_cmd

     command -v taskset >/dev/null || { echo "ERROR: taskset not installed." >&2; return 1; }


    echo "Starting HAOS (SMP# $QEMU_CPUS affinity: $QEMU_CPU_AFFINITY)."
    exec taskset -c "$QEMU_CPU_AFFINITY" "${CMD[@]}"
}

# Maybe usefull in future for using console for patching 
# the newly installed system.

# Close only console clients launched by our controller.
# Never kill QEMU or arbitrary users of the socket.
close_own_console_clients() {
    local pid
    local -a argv
    local arg
    local found

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" != "$$" ]] || continue

        [[ -r "/proc/$pid/cmdline" ]] || continue

        mapfile -d '' -t argv < "/proc/$pid/cmdline" || true

        found=0

        for arg in "${argv[@]}"; do
            if [[ "$arg" == "UNIX-CONNECT:$CONSOLE_SOCK" ]]; then
                found=1
            fi
        done

        # Match the exact socat arguments used by
        # connect_socket(), not other socket users.
        if (( found )) &&
           [[ "${argv[1]:-}" == "-,raw,echo=0" ]]; then

            echo "Closing existing haosctl console client PID $pid"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done < <(pgrep -x socat || true)

    # Allow the client to release its connection.
    sleep 1
}

request_console_shutdown() {
    [[ -S "$CONSOLE_SOCK" ]] || return 1

    close_own_console_clients

    echo "Requesting HAOS shutdown via console."

    # Send a newline to obtain a prompt, then the HA CLI
    # command. Success here means transmission only.
    printf '\nha host shutdown\n' |
        timeout 8 socat -u - "UNIX-CONNECT:$CONSOLE_SOCK"
}

request_acpi_shutdown() {
    [[ -S "$MONITOR_SOCK" ]] || {
        echo "ERROR: QEMU monitor socket missing." >&2
        return 1
    }

    echo "Requesting ACPI shutdown via QEMU monitor."

    printf 'system_powerdown\n' |
        timeout 8 socat -T 2 - \
            "UNIX-CONNECT:$MONITOR_SOCK" >/dev/null
}

qmp_command() {
    # Simple QMP json message handler
    local command=$1
    local line normalized
    local fd_in fd_out pid
    local rc=1

    [[ -S "$QMP_SOCK" ]] || {
        echo "ERROR: QMP socket missing." >&2
        return 1
    }

    coproc QMP {
        socat -T 5 - "UNIX-CONNECT:$QMP_SOCK"
    }

    fd_out=${QMP[0]}
    fd_in=${QMP[1]}
    pid=$QMP_PID

    # Read initial QMP greeting.
    if ! IFS= read -r -t 5 line <&"$fd_out"; then
        echo "ERROR: No QMP greeting." >&2
    else
        # Negotiate capabilities.
        printf '%s\n' \
            '{"execute":"qmp_capabilities","id":"cap"}' >&"$fd_in"

        while IFS= read -r -t 5 line <&"$fd_out"; do
            normalized=${line//[[:space:]]/}

            if [[ $normalized == *'"id":"cap"'* &&
                  $normalized == *'"return"'* ]]; then
                break
            fi

            if [[ $normalized == *'"id":"cap"'* &&
                  $normalized == *'"error"'* ]]; then
                echo "QMP error: $line" >&2
                break
            fi
        done

        if [[ $normalized == *'"id":"cap"'* &&
              $normalized == *'"return"'* ]]; then

            printf '{"execute":"%s","id":"cmd"}\n' \
                "$command" >&"$fd_in"

            while IFS= read -r -t 5 line <&"$fd_out"; do
                normalized=${line//[[:space:]]/}

                if [[ $normalized == *'"id":"cmd"'* &&
                      $normalized == *'"return"'* ]]; then
                    rc=0
                    break
                fi

                if [[ $normalized == *'"id":"cmd"'* &&
                      $normalized == *'"error"'* ]]; then
                    echo "QMP error: $line" >&2
                    break
                fi
            done
        fi
    fi

    exec {fd_in}>&-
    exec {fd_out}<&-
    wait "$pid" 2>/dev/null || true

    return "$rc"
}

stop_vm() {
    require_root

    if ! qemu_running; then
        echo "HAOS already stopped."
        return 0
    fi

    echo "Requesting HAOS shutdown via QMP..."

    if ! qmp_command system_powerdown; then
        echo "ERROR: QMP shutdown request failed." >&2
        return 1
    fi

    echo "Waiting for HAOS to shut down..."

    if wait_for_exit 90; then
        echo "HAOS stopped."
        return 0
    fi

    echo "ERROR: HAOS did not stop within 90 seconds." >&2
    return 1
}

status_vm() {
    echo "--- systemd ---"
    systemctl status haos.service --no-pager || true

    echo "--- Network ---"
    ip -br link show br0 || true
    ip -br link show tap0 || true
    bridge link show dev tap0 || true

    echo "--- QEMU ---"
    pgrep -af '[q]emu-system-aarch64' || true

    echo "--- Sockets ---"
    ls -l "$CONSOLE_SOCK" "$MONITOR_SOCK" "$QMP_SOCK"\
        2>/dev/null || true

    echo "--- QMP ---"
    if qemu_running; then
        if qmp_command query-status; then
            echo "QMP: responding"
        else
            echo "QMP: ERROR"
        fi
    else
        echo "QMP: inactive (VM stopped)"
    fi

    echo "--- Poweroff / Reboot button check ---"
    if console_is_free; then
        check_poweroff
    else
        echo "HAOS PowerKey: UNKNOWN (console busy)"
        echo "Terminate console connection to enable PowerKey check."
    fi
}

connect_socket() {
    local sock=$1

    [[ -S "$sock" ]] || {
        echo "Socket not found: $sock" >&2
        return 1
    }

    exec socat -,raw,echo=0 "UNIX-CONNECT:$sock"
}

# Install the HAOS PowerKey workaround inside the guest, not on the host.
# Usage: patch-poweroff [SSH destination]
# Without a destination, generate a guest-side installer and print instructions.
# With an SSH destination (e.g. root@192.168.10.42), run it over SSH.
# The SSH endpoint must provide an HAOS host root shell, not the HA CLI.
patch_poweroff() {
    local destination=${1:-}
    local patch_file="$BASE/patch-haos-poweroff.sh"

    require_root
    mkdir -p "$BASE"
    cat > "$patch_file" <<'GUEST_PATCH'
#!/bin/sh
set -eu

# Run INSIDE HAOS as root. The overlay path persists across HAOS updates.
mkdir -p /mnt/overlay /etc/udev/rules.d
cat > /mnt/overlay/qemu-powerkey-fix.sh <<'POWER_FIX'
#!/bin/sh
set -eu
mkdir -p /run/systemd/logind.conf.d
cat > /run/systemd/logind.conf.d/90-qemu-powerkey.conf <<'LOGIND'
[Login]
HandlePowerKey=poweroff
LOGIND
systemctl restart systemd-logind.service
POWER_FIX
chmod 0755 /mnt/overlay/qemu-powerkey-fix.sh

# Trigger the runtime drop-in when the virtual Power Button input device appears.
cat > /etc/udev/rules.d/90-qemu-powerkey.rules <<'UDEV'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Power Button", RUN+="/usr/bin/systemd-run --no-block /mnt/overlay/qemu-powerkey-fix.sh"
UDEV

# Apply now; future boots use the udev rule.
/mnt/overlay/qemu-powerkey-fix.sh
udevadm control --reload-rules
printf '%s\n' 'PowerKey workaround installed. Verify with:'
printf '%s\n' '  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandlePowerKey'
GUEST_PATCH
    chmod 0644 "$patch_file"
    echo "Guest-side PowerKey patch prepared: $patch_file"

    if [[ -n "$destination" ]]; then
        if [[ "$destination" == -* ]]; then
            echo "ERROR: Invalid SSH destination." >&2
            return 2
        fi
        echo "Applying PowerKey patch inside HAOS via SSH: $destination"
        ssh -o BatchMode=yes -o ConnectTimeout=10 -- "$destination" 'sh -s' < "$patch_file"
    else
        echo "To install: copy the file into HAOS and run it as root in the HAOS host shell."
        echo "Or use: $0 patch-poweroff root@HAOS_HOST"
        echo "Note: HAOS debug SSH may use a nondefault port; configure SSH accordingly."
    fi
}

console_is_free() {
    local socket="${CONSOLE_SOCK:-/run/qemu-haos-console.sock}"

    [[ -S "$socket" ]] || return 1

    ! ss -xapnH state established |
        grep -Fq "$socket"
}

check_poweroff() {
    local output result
    local marker="__HAOSCTL_POWERKEY_DONE__"
    local cmd='busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandlePowerKey'

    require_root

    if [[ ! -S "$CONSOLE_SOCK" ]]; then
        echo "ERROR: HAOS console socket not found: $CONSOLE_SOCK" >&2
        return 1
    fi

    # The HAOS serial console must already be at a root shell.
    # Keep stdin open until socat is terminated by timeout.
    output=$(
        {
            printf '\r'
            sleep 1
            printf '%s\r' "$cmd"
            sleep 1
            printf 'printf "%s\\n" %s\r' "$marker" "$marker"
            sleep 3
        } | timeout -k 1s 8s socat - "UNIX-CONNECT:$CONSOLE_SOCK"
    )

    # Strip CR characters from serial terminal output.
    output=${output//$'\r'/}

    # Extract the property value from a complete response line.
    result=$(
        printf '%s\n' "$output" |
            grep -E '^s "(poweroff|ignore|reboot|halt|lock|kexec|suspend|hibernate|hybrid-sleep|suspend-then-hibernate)"$' |
            tail -n 1
    )

    if [[ "$output" != *"$marker"* ]]; then
        echo "ERROR: No complete response from HAOS console." >&2
        return 1
    fi

    case "$result" in
        's "poweroff"')
            echo "HAOS PowerKey: OK (poweroff)"
            return 0
            ;;
        "")
            echo "ERROR: Could not read HandlePowerKey." >&2
            return 1
            ;;
        *)
            echo "HAOS PowerKey: NOT OK ($result)"
            return 1
            ;;
    esac
}

# 
# User cli to anccess HAOS console and QEMU
# systemd service start/stop interface
#
case "${1:-}" in
    run)
        run_vm
        ;;
    stop)
        stop_vm
        ;;
    status)
        status_vm
        ;;
    check-network)
        check_network
        ;;
    console)
        connect_socket "$CONSOLE_SOCK"
        ;;
    monitor)
        connect_socket "$MONITOR_SOCK"
        ;;
    show-qemu-command)
        build_qemu_cmd
        printf '%q ' "${CMD[@]}"
        printf '\n'
        ;;
    patch-poweroff)
        patch_poweroff "${2:-}"
        ;;
    check-poweroff)
        check_poweroff
        ;;
    kill-console)
	close_own_console_clients
	;;
#    call)
#	shift
#	"$@"
#	;;
    *)
        cat >&2 <<'EOHELP'

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

   check-poweroff    Check if (virtual) poweroff button works properly.

   patch-poweroff    Generate patchfile to copy and run on HAOS
                     to enable safe HAOS reboot or shutdown.


   monitor           Connect to QEMUs mgmt console

   console           Connect to HAOS virtual serial console.
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
EOHELP
        exit 2
        ;;
esac

