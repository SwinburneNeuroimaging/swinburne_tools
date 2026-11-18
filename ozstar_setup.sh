#!/usr/bin/env bash
set -u

REMOTE_HOST="ozstar.swin.edu.au"
KEY_PATH="$HOME/.ssh/id_ed25519"
CONTROL_DIR="$HOME/.ssh/controlmasters"
REMOUNT_SCRIPT="$HOME/.local/bin/reconnect_ozstar"
BASHRC="$HOME/.bashrc"

echo "=== Step 0: Checking/installing required components ==="
install_required_components() {
    local required=(ssh ssh-keygen ssh-add expect keychain sshfs mountpoint fusermount3 timeout)
    local missing=() cmd
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        echo "All required components are already installed."
        return 0
    fi
    echo "Missing commands: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing dependencies with apt-get..."
        sudo apt-get update || return 1
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            openssh-client expect keychain sshfs fuse3 util-linux coreutils || return 1
    elif command -v dnf >/dev/null 2>&1; then
        echo "Installing dependencies with dnf..."
        sudo dnf install -y openssh-clients expect keychain fuse-sshfs fuse3 util-linux coreutils || return 1
    elif command -v yum >/dev/null 2>&1; then
        echo "Installing dependencies with yum..."
        sudo yum install -y openssh-clients expect keychain fuse-sshfs fuse3 util-linux coreutils || return 1
    else
        echo "Error: supported package manager not found (apt-get, dnf, or yum)." >&2
        return 1
    fi
    missing=()
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: commands still unavailable after installation: ${missing[*]}" >&2
        return 1
    fi
    echo "Required components installed successfully."
}
install_required_components || return

mkdir -p "$HOME/.ssh" "$CONTROL_DIR" "$HOME/.local/bin"
chmod 700 "$HOME/.ssh" "$CONTROL_DIR"

echo "=== Step 1: OzSTAR credentials ==="
read -r -p "Enter OzSTAR username: " OZSTAR_USER
while [ -z "$OZSTAR_USER" ]; do
    read -r -p "Username cannot be empty. Enter OzSTAR username: " OZSTAR_USER
done

read -r -s -p "Enter OzSTAR password: " OZSTAR_PASSWORD
echo
while [ -z "$OZSTAR_PASSWORD" ]; do
    read -r -s -p "Password cannot be empty. Enter OzSTAR password: " OZSTAR_PASSWORD
    echo
done

read -r -s -p "Enter a passphrase for the new SSH key: " KEY_PASSPHRASE
echo
while [ -z "$KEY_PASSPHRASE" ]; do
    read -r -s -p "SSH key passphrase cannot be empty. Enter it again: " KEY_PASSPHRASE
    echo
done
read -r -s -p "Confirm the SSH key passphrase: " KEY_PASSPHRASE_CONFIRM
echo
if [ "$KEY_PASSPHRASE" != "$KEY_PASSPHRASE_CONFIRM" ]; then
    echo "Error: SSH key passphrases do not match." >&2
    return
fi
unset KEY_PASSPHRASE_CONFIRM

read -r -p "Enter the current OzSTAR 2FA code: " OTP_CODE
echo
if ! [[ "$OTP_CODE" =~ ^[0-9]{6}$ ]]; then
    echo "Error: the OzSTAR 2FA code must contain exactly six digits." >&2
    return
fi

REMOTE_TARGET="${OZSTAR_USER}@${REMOTE_HOST}"
CONTROL_SOCKET="$CONTROL_DIR/ozstar-${OZSTAR_USER}"

echo
echo "=== Step 2: Starting initial SSH ControlMaster ==="
rm -f "$CONTROL_SOCKET"
OZSTAR_PASSWORD="$OZSTAR_PASSWORD" OTP_CODE="$OTP_CODE" REMOTE_TARGET="$REMOTE_TARGET" CONTROL_SOCKET="$CONTROL_SOCKET" expect -c '
    log_user 1
    set timeout 60
    set password $env(OZSTAR_PASSWORD)
    set otp $env(OTP_CODE)
    spawn ssh -M -S $env(CONTROL_SOCKET) \
        -o ControlMaster=yes -o ControlPersist=yes \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -o PreferredAuthentications=keyboard-interactive,password,hostbased \
        -o PubkeyAuthentication=no -N -f $env(REMOTE_TARGET)
    expect {
        "Are you sure you want to continue connecting" {
            send -- "yes\r"
            exp_continue
        }
        -nocase -re {password:} {
            send -- "$password\r"
            exp_continue
        }
        -nocase -re {OzSTAR[[:space:]]+2FA code:} {
            send -- "$otp\r"
            exp_continue
        }
        -nocase -re {(verification code|otp|one-time password|token|passcode|2fa code|2fa):} {
            send -- "$otp\r"
            exp_continue
        }
        timeout {
            puts stderr "Error: timed out while authenticating the initial ControlMaster."
            return
        }
        eof {
            catch wait result
            exit [lindex $result 3]
        }
    }
'
MASTER_STATUS=$?
unset OZSTAR_PASSWORD OTP_CODE
if [ "$MASTER_STATUS" -ne 0 ] || ! ssh -S "$CONTROL_SOCKET" -O check "$REMOTE_TARGET" >/dev/null 2>&1; then
    echo "Error: failed to establish the initial OzSTAR ControlMaster." >&2
    rm -f "$CONTROL_SOCKET"
    return
fi
echo "Initial authenticated ControlMaster established."

echo
echo "=== Step 3: Creating and loading the SSH key ==="
if [ -e "$KEY_PATH" ] || [ -e "$KEY_PATH.pub" ]; then
    BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"
    echo "Existing SSH key found; backing it up with suffix .$BACKUP_SUFFIX"
    [ -e "$KEY_PATH" ] && mv "$KEY_PATH" "$KEY_PATH.$BACKUP_SUFFIX"
    [ -e "$KEY_PATH.pub" ] && mv "$KEY_PATH.pub" "$KEY_PATH.pub.$BACKUP_SUFFIX"
fi

KEY_PATH="$KEY_PATH" KEY_PASSPHRASE="$KEY_PASSPHRASE" expect -c '
    log_user 1
    set timeout 30
    spawn ssh-keygen -t ed25519 -f $env(KEY_PATH) -C "$env(USER)@[info hostname]"
    expect {
        -nocase "Enter passphrase" { send -- "$env(KEY_PASSPHRASE)\r"; exp_continue }
        -nocase "Enter same passphrase again" { send -- "$env(KEY_PASSPHRASE)\r"; exp_continue }
        eof
    }
    catch wait result
    exit [lindex $result 3]
'
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

KEYCHAIN_SH="$HOME/.keychain/$(hostname)-sh"
keychain --stop all >/dev/null 2>&1 || true
rm -f "$HOME/.keychain/$(hostname)" "$HOME/.keychain/$(hostname)-sh" "$HOME/.keychain/$(hostname)-csh" 2>/dev/null
KEY_PATH="$KEY_PATH" KEY_PASSPHRASE="$KEY_PASSPHRASE" expect -c '
    log_user 1
    set timeout 30
    spawn keychain --quiet --agents ssh $env(KEY_PATH)
    expect {
        -nocase "Enter passphrase" { send -- "$env(KEY_PASSPHRASE)\r"; exp_continue }
        eof
    }
    catch wait result
    exit [lindex $result 3]
'
unset KEY_PASSPHRASE
[ -f "$KEYCHAIN_SH" ] && source "$KEYCHAIN_SH"
if ! ssh-add -l >/dev/null 2>&1; then
    echo "Error: the SSH key was not loaded into the keychain-managed agent." >&2
    return
fi
echo "SSH key loaded into the keychain-managed ssh-agent."

echo
echo "=== Step 4: Installing the public key through the ControlMaster ==="
PUBKEY=$(cat "$KEY_PATH.pub")
printf '%s\n' "$PUBKEY" | ssh -S "$CONTROL_SOCKET" -o ControlMaster=no -o BatchMode=yes "$REMOTE_TARGET" '
    umask 077
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    IFS= read -r key
    grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh/authorized_keys"
'
if [ "$?" -ne 0 ]; then
    echo "Error: failed to install the public key through the ControlMaster." >&2
    return
fi
echo "Public key installed on OzSTAR."

echo
echo "=== Step 5: Creating reconnect_ozstar ==="
cat > "$REMOUNT_SCRIPT" <<RECONNECT_HEADER
#!/usr/bin/env bash
REMOTE_HOST="$REMOTE_HOST"
OZSTAR_USER="$OZSTAR_USER"
KEY_PATH="$KEY_PATH"
CONTROL_DIR="$CONTROL_DIR"
CONTROL_SOCKET="$CONTROL_SOCKET"
REMOTE_TARGET="$REMOTE_TARGET"
RECONNECT_HEADER
cat >> "$REMOUNT_SCRIPT" <<'RECONNECT_BODY'
SYNC_DIRS=("/fred" "/dagg" "/home/${OZSTAR_USER}")

load_agent() {
    local keychain_sh="$HOME/.keychain/$(hostname)-sh"
    [ -f "$keychain_sh" ] && source "$keychain_sh"
    if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
        echo "The keychain agent is unavailable. Starting it; your SSH key passphrase may be requested."
        keychain --quiet --agents ssh "$KEY_PATH"
        [ -f "$keychain_sh" ] && source "$keychain_sh"
    fi
}

master_alive() {
    ssh -S "$CONTROL_SOCKET" -O check "$REMOTE_TARGET" >/dev/null 2>&1
}

start_master() {
    master_alive && return 0
    rm -f "$CONTROL_SOCKET"
    local otp
    read -r -p "Enter a fresh OzSTAR 2FA code: " otp
    echo
    if ! [[ "$otp" =~ ^[0-9]{6}$ ]]; then
        echo "Error: the 2FA code must contain exactly six digits." >&2
        return 1
    fi
    CONTROL_SOCKET="$CONTROL_SOCKET" REMOTE_TARGET="$REMOTE_TARGET" OTP_CODE="$otp" expect -c '
        log_user 1
        set timeout 60
        spawn ssh -M -S $env(CONTROL_SOCKET) \
            -o ControlMaster=yes -o ControlPersist=yes \
            -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
            -N -f $env(REMOTE_TARGET)
        expect {
            "Are you sure you want to continue connecting" { send -- "yes\r"; exp_continue }
            -nocase -re {OzSTAR[[:space:]]+2FA code:} { send -- "$env(OTP_CODE)\r"; exp_continue }
            -nocase -re {(verification code|otp|one-time password|token|passcode|2fa code|2fa):} { send -- "$env(OTP_CODE)\r"; exp_continue }
            -nocase -re {password:} { interact }
            timeout { return }
            eof { catch wait result; exit [lindex $result 3] }
        }
    '
    unset otp
    master_alive
}

mount_healthy() {
    local dir="$1"
    mountpoint -q "$dir" && timeout 5 stat "$dir/." >/dev/null 2>&1
}

mount_one() {
    local dir="$1"
    if mount_healthy "$dir"; then
        echo "$dir is already mounted and responsive."
        return 0
    fi
    if mountpoint -q "$dir"; then
        echo "Removing stale mount at $dir..."
        fusermount3 -uz "$dir" >/dev/null 2>&1 || true
    fi
    if [ ! -d "$dir" ]; then
        echo "Creating mountpoint $dir..."
        sudo mkdir -p "$dir" || return 1
        sudo chown "$(whoami)":"$(whoami)" "$dir" || return 1
    fi
    echo "Mounting $dir through the authenticated ControlMaster..."
    sshfs "${REMOTE_TARGET}:${dir}" "$dir" \
        -o IdentityFile="$KEY_PATH" \
        -o ControlPath="$CONTROL_SOCKET" \
        -o ControlMaster=no \
        -o BatchMode=yes \
        -o workaround=rename \
        -o reconnect \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3
    mount_healthy "$dir"
}

load_agent
if ! start_master; then
    echo "Error: could not establish the OzSTAR ControlMaster." >&2
    return
fi

failed=0
for dir in "${SYNC_DIRS[@]}"; do
    mount_one "$dir" || { echo "Error: failed to mount $dir" >&2; failed=1; }
done
exit "$failed"
RECONNECT_BODY
chmod 700 "$REMOUNT_SCRIPT"
echo "Created $REMOUNT_SCRIPT"

echo
echo "=== Step 6: Installing sshoz in $BASHRC ==="
START_MARKER="# >>> sshoz OzSTAR ControlMaster function >>>"
END_MARKER="# <<< sshoz OzSTAR ControlMaster function <<<"
if grep -qF "$START_MARKER" "$BASHRC" 2>/dev/null; then
    sed -i "\|^$START_MARKER$|,\|^$END_MARKER$|d" "$BASHRC"
fi
cat >> "$BASHRC" <<BASHRC_BLOCK
$START_MARKER
sshoz() {
    local remote_target="$REMOTE_TARGET"
    local control_socket="$CONTROL_SOCKET"
    local key_path="$KEY_PATH"
    local keychain_sh="\$HOME/.keychain/\$(hostname)-sh"

    [ -f "\$keychain_sh" ] && source "\$keychain_sh"
    if ! ssh -S "\$control_socket" -O check "\$remote_target" >/dev/null 2>&1; then
        echo "OzSTAR ControlMaster is unavailable."
        local otp
        read -r -p "Enter a fresh OzSTAR 2FA code: " otp
        echo
        if ! [[ "\$otp" =~ ^[0-9]{6}\$ ]]; then
            echo "Error: the 2FA code must contain exactly six digits." >&2
            return 1
        fi
        rm -f "\$control_socket"
        CONTROL_SOCKET="\$control_socket" REMOTE_TARGET="\$remote_target" OTP_CODE="\$otp" expect -c '
            log_user 1
            set timeout 60
            spawn ssh -M -S \$env(CONTROL_SOCKET) -o ControlMaster=yes -o ControlPersist=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -f \$env(REMOTE_TARGET)
            expect {
                "Are you sure you want to continue connecting" { send -- "yes\\r"; exp_continue }
                -nocase -re {OzSTAR[[:space:]]+2FA code:} { send -- "\$env(OTP_CODE)\\r"; exp_continue }
                -nocase -re {(verification code|otp|one-time password|token|passcode|2fa code|2fa):} { send -- "\$env(OTP_CODE)\\r"; exp_continue }
                -nocase -re {password:} { interact }
                timeout { return }
                eof { catch wait result; exit [lindex \$result 3] }
            }
        '
        unset otp
    fi
    if ! ssh -S "\$control_socket" -O check "\$remote_target" >/dev/null 2>&1; then
        echo "Error: failed to establish the OzSTAR ControlMaster." >&2
        return 1
    fi
    ssh -Y -S "\$control_socket" -o ControlMaster=no -o BatchMode=yes "\$remote_target"
}
$END_MARKER
BASHRC_BLOCK

PATH_MARKER="# >>> reconnect_ozstar PATH >>>"
if ! grep -qF "$PATH_MARKER" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<PATH_BLOCK
$PATH_MARKER
if [[ ":\$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="\$PATH:$HOME/.local/bin"
fi
# <<< reconnect_ozstar PATH <<<
PATH_BLOCK
fi

echo
echo "=== Step 7: Initial SSHFS mounts ==="
"$REMOUNT_SCRIPT"

echo
echo "=== Setup complete ==="
echo "Open a new terminal or run: source \"$BASHRC\""
echo "Then use 'sshoz' for an OzSTAR shell or 'reconnect_ozstar' to check/repair mounts."
