#!/bin/bash
# =========================================================================
# Configuration
# =========================================================================
REMOTE_HOST="ozstar.swin.edu.au" # <-- Hardcode your remote server IP or hostname here
KEY_PATH="$HOME/.ssh/id_ed25519"
GPG_ENC_FILE="$HOME/.ssh/2fa_secret.gpg"
mkdir -p /home/vdiuser/.local/bin
REMOUNT_SCRIPT="/home/vdiuser/.local/bin/reconnect_ozstar"
MY_BASHRC="$HOME/.bashrc"   # Explicitly defining the path locally
# Required local packages
REQUIRED_PKGS=("oathtool" "gpg" "expect" "sshfs" "fuse3" "keychain" "xclip")
# -------------------------------------------------------------------------
# Step 0: Ensure Required Packages are Installed (APT)
# -------------------------------------------------------------------------
echo "=== Step 0: Checking System Dependencies ==="
MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "$pkg" &> /dev/null && ! dpkg -s "$pkg" &> /dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Missing dependencies found: ${MISSING_PKGS[*]}"
    echo "Installing missing packages via apt... (Root/sudo privileges required)"
    sudo apt-get update -y && \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PKGS[@]}"
    for pkg in "${MISSING_PKGS[@]}"; do
        if ! command -v "$pkg" &> /dev/null && ! dpkg -s "$pkg" &> /dev/null; then
            echo "Error: Failed to install '$pkg'. Please install it manually." >&2
            return 1 2>/dev/null || exit 1
        fi
    done
    echo "All dependencies successfully installed."
else
    echo "All required dependencies are already installed."
fi
echo ""
# -------------------------------------------------------------------------
# Step 1: Obtain Remote Username and Optional 2FA String
# -------------------------------------------------------------------------
echo "=== Step 1: User & 2FA Configuration ==="
# Obtain username at runtime
while true; do
    read -p "Enter ozstar username: " OZSTAR_USER
    if [ -n "$OZSTAR_USER" ]; then
        break
    fi
    echo "Error: Username cannot be empty."
done
# Build the complete target string
FULL_REMOTE_TARGET="${OZSTAR_USER}@${REMOTE_HOST}"
# Optional 2FA Setup String
read -r -p "Enter your ozstar 2FA Setup String (Leave blank to download from ozstar or input 2FA codes manually later): " TFA_SECRET
echo ""
USE_AUTO_2FA=false
if [ -n "$TFA_SECRET" ]; then
    echo "Encrypting 2FA secret..."
    echo "$TFA_SECRET" | gpg --symmetric --output "$GPG_ENC_FILE" --yes
    unset TFA_SECRET
    echo "Saved encrypted secret to $GPG_ENC_FILE"
    USE_AUTO_2FA=true
else
    echo "No 2FA setup string provided. You will be prompted for your 2FA code during connections."
    rm -f "$GPG_ENC_FILE"
fi
echo ""
# -------------------------------------------------------------------------
# Step 2: Generate the SSH Key (Enforcing Non-Empty Passphrase)
# -------------------------------------------------------------------------
echo "=== Step 2: SSH Key Generation ==="
if [ -f "$KEY_PATH" ]; then
    read -p "An SSH key already exists at $KEY_PATH. Overwrite? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting key generation."
        return 1 2>/dev/null || exit 1
    fi
    rm -f "$KEY_PATH" "${KEY_PATH}.pub"
fi
while true; do
    read -rs -p "Enter a new SSH passphrase (cannot be empty): " PASS1
    echo ""
    if [ -z "$PASS1" ]; then
        echo "Error: Passphrase cannot be empty."
        continue
    fi
    read -rs -p "Confirm SSH passphrase: " PASS2
    echo ""
    if [ "$PASS1" != "$PASS2" ]; then
        echo "Error: Passphrases do not match."
        continue
    fi
    break
done
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
echo "$PASS1" | ssh-keygen -p -f "$KEY_PATH" -N "$PASS1" -q
chmod 600 "$KEY_PATH"
echo "SSH key generated successfully."
echo ""
# -------------------------------------------------------------------------
# Step 2b: Load the New Key into a Persistent Agent via "keychain"
# -------------------------------------------------------------------------
echo "=== Step 2b: Loading Key via keychain ==="
echo "Starting/attaching to keychain-managed ssh-agent and adding $KEY_PATH..."
expect <<EOF
set timeout 10
spawn keychain --quiet --agents ssh "$KEY_PATH"
expect {
    -nocase "Enter passphrase" {
        send "$PASS1\r"
        exp_continue
    }
    eof
}
EOF
# keychain writes a sourceable file containing SSH_AUTH_SOCK / SSH_AGENT_PID
KEYCHAIN_SH="$HOME/.keychain/$(hostname)-sh"
if [ -f "$KEYCHAIN_SH" ]; then
    # shellcheck disable=SC1090
    source "$KEYCHAIN_SH"
else
    echo "Warning: keychain environment file not found at $KEYCHAIN_SH. Agent variables may not be set in this shell."
fi
# Validate that SSH_AUTH_SOCK actually points at a live socket. keychain
# tracks the agent it last started/reused by PID in ~/.keychain/, and only
# checks that a process with that PID is still running -- it does NOT
# verify the socket file itself still exists. If /tmp was wiped (session
# recycle, reboot, container rebuild) but the PID got reused by an
# unrelated process, keychain will happily hand back a dead socket path.
# If that's happened, wipe the stale state and force a genuinely fresh agent.
if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
    echo "Warning: keychain's recorded agent socket is stale or missing. Restarting agent..."
    keychain --stop all &>/dev/null
    rm -f "$HOME/.keychain/$(hostname)" "$HOME/.keychain/$(hostname)-sh" "$HOME/.keychain/$(hostname)-csh" 2>/dev/null
    expect <<EOF
set timeout 10
spawn keychain --quiet --agents ssh "$KEY_PATH"
expect {
    -nocase "Enter passphrase" {
        send "$PASS1\r"
        exp_continue
    }
    eof
}
EOF
    if [ -f "$KEYCHAIN_SH" ]; then
        # shellcheck disable=SC1090
        source "$KEYCHAIN_SH"
    fi
    if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
        echo "Error: Unable to establish a working keychain/ssh-agent socket. ssh/scp/sshfs calls below may prompt for the key passphrase directly." >&2
    else
        echo "Fresh agent started successfully."
    fi
fi
unset PASS1 PASS2
echo "Key loaded via keychain. The agent persists across terminals/sessions (until reboot or 'keychain --stop'),"
echo "so subsequent ssh/scp calls -- including in future shells -- won't re-prompt for the key passphrase."
echo ""
# -------------------------------------------------------------------------
# Step 3: Copy ID via Expect (Conditional 2FA Handling & Fallback)
# -------------------------------------------------------------------------
echo "=== Step 3: Copying SSH Key to $FULL_REMOTE_TARGET ==="
OTP_CODE=""
if [ "$USE_AUTO_2FA" = true ]; then
    echo "Decrypting 2FA setup string to generate live OTP..."
    CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
    if [ -z "$CODE" ]; then
        echo "Warning: Failed to decrypt or generate OTP code automatically. Falling back to manual entry."
        USE_AUTO_2FA=false
    else
        OTP_CODE="$CODE"
        echo "Generated automated OTP Token successfully."
    fi
fi
echo "Initiating ssh-copy-id..."
echo ""
# NOTE: the expect script is written to a temp file and invoked as
# `expect /path/to/file` (rather than piped in via a `<<EOF` heredoc on
# stdin). This matters because `interact` hands control of the *invoking
# process's* stdin/stdout over to the spawned program -- if that stdin is
# a heredoc, it is already exhausted/closed by the time `interact` runs,
# so the manual-password fallback would silently fail to let you type
# anything. Writing to a file instead leaves the real terminal's stdin
# untouched and available to `interact`.
#
# NOTE: this host requires BOTH an account password AND a 2FA code in
# sequence (password prompt arrives first, 2FA prompt second) whenever
# the key being used isn't authorized yet. The "password:" branch below
# used to call a bare `interact`, which hands off ALL subsequent
# matching to the user -- so once it took over, the 2FA prompt that
# followed was never auto-answered, forcing you to type both the
# password and the OTP manually. Fixed by giving `interact` its own
# "-o" (watch process OUTPUT) pattern for the 2FA prompt: you still type
# the account password manually, but interact keeps watching in the
# background and auto-sends $OTP_CODE the moment the 2FA prompt appears,
# then continues interacting normally until the process exits.
STEP3_EXP=$(mktemp /tmp/setup_ssh_step3.XXXXXX.exp)
cat > "$STEP3_EXP" <<EOF
set timeout 30
spawn ssh-copy-id -i "${KEY_PATH}.pub" "$FULL_REMOTE_TARGET"
expect {
    -nocase -re "(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
        if { "$USE_AUTO_2FA" == "true" } {
            send "$OTP_CODE\r"
            exp_continue
        } else {
            interact
        }
    }
    "Are you sure you want to continue connecting" {
        send "yes\r"
        exp_continue
    }
    -nocase "password:" {
        interact {
            -o -re "(?i)(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
                if { "$USE_AUTO_2FA" == "true" } {
                    send -- "$OTP_CODE\r"
                }
            }
        }
    }
    eof
}
EOF
expect "$STEP3_EXP"
rm -f "$STEP3_EXP"
echo ""
# -------------------------------------------------------------------------
# Step 3b: Reconcile the 2FA Secret Between Local and Remote Host
#          (Every ssh/scp call below is wrapped in the same expect-driven
#          OTP-handling logic used in Step 3: auto-send $OTP_CODE when
#          USE_AUTO_2FA is true, otherwise fall through to manual "interact".
#          As in Step 3, each expect script is written to a temp file and
#          run as `expect file` rather than piped via a stdin heredoc, so
#          that `interact` has access to the real terminal stdin -- and
#          each "password:" branch's `interact` also watches for the 2FA
#          prompt via -o so the OTP still gets auto-sent after a manual
#          password entry.)
# -------------------------------------------------------------------------
echo "=== Step 3b: Reconciling 2FA Secret With Remote Host ==="
if [ "$USE_AUTO_2FA" = false ]; then
    # No local setup string was supplied -- check whether the remote host
    # already has one saved from a previous run, and pull it down if so.
    echo "No local 2FA setup string was provided. Checking $FULL_REMOTE_TARGET for ~/2fa_secret.gpg..."
    STEP3B_CHECK_EXP=$(mktemp /tmp/setup_ssh_step3b_check.XXXXXX.exp)
    cat > "$STEP3B_CHECK_EXP" <<EOF
set timeout 30
spawn ssh -i "$KEY_PATH" "$FULL_REMOTE_TARGET" {[ -f "\$HOME/2fa_secret.gpg" ]}
expect {
    -nocase -re "(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
        if { "$USE_AUTO_2FA" == "true" } {
            send "$OTP_CODE\r"
            exp_continue
        } else {
            interact
        }
    }
    "Are you sure you want to continue connecting" {
        send "yes\r"
        exp_continue
    }
    -nocase "password:" {
        interact {
            -o -re "(?i)(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
                if { "$USE_AUTO_2FA" == "true" } {
                    send -- "$OTP_CODE\r"
                }
            }
        }
    }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
    expect "$STEP3B_CHECK_EXP"
    REMOTE_FILE_EXISTS=$?
    rm -f "$STEP3B_CHECK_EXP"
    if [ "$REMOTE_FILE_EXISTS" -eq 0 ]; then
        echo "Found 2fa_secret.gpg on remote host. Copying to local machine..."
        STEP3B_PULL_EXP=$(mktemp /tmp/setup_ssh_step3b_pull.XXXXXX.exp)
        cat > "$STEP3B_PULL_EXP" <<EOF
set timeout 30
spawn scp -i "$KEY_PATH" {${FULL_REMOTE_TARGET}:/home/$OZSTAR_USER/2fa_secret.gpg} "$HOME/.ssh/2fa_secret.gpg"
expect {
    -nocase -re "(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
        if { "$USE_AUTO_2FA" == "true" } {
            send "$OTP_CODE\r"
            exp_continue
        } else {
            interact
        }
    }
    "Are you sure you want to continue connecting" {
        send "yes\r"
        exp_continue
    }
    -nocase "password:" {
        interact {
            -o -re "(?i)(verification code|otp|one-time password|token|passcode|2fa code|2fa):" {
                if { "$USE_AUTO_2FA" == "true" } {
                    send -- "$OTP_CODE\r"
                }
            }
        }
    }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
        expect "$STEP3B_PULL_EXP"
        SCP_STATUS=$?
        rm -f "$STEP3B_PULL_EXP"
        if [ "$SCP_STATUS" -eq 0 ]; then
            GPG_ENC_FILE="$HOME/.ssh/2fa_secret.gpg"
            USE_AUTO_2FA=true
            echo "Copied remote 2FA secret to $GPG_ENC_FILE"
        else
            echo "Warning: Failed to copy remote 2FA secret file. Continuing without automated 2FA."
        fi
    else
        echo "No 2fa_secret.gpg found in the remote home directory. Continuing without automated 2FA."
    fi
else
    # Local 2FA secret exists. Create one authenticated ControlMaster here,
    # then reuse it for the existence check, scp, and all SSHFS mounts.
    CONTROL_DIR="$HOME/.ssh/controlmasters"
    CONTROL_SOCKET="$CONTROL_DIR/ozstar-${OZSTAR_USER}"
    mkdir -p "$CONTROL_DIR"
    chmod 700 "$CONTROL_DIR"
    echo "Local 2FA setup string was provided. Establishing/reusing an authenticated ControlMaster..."

    if ! ssh -S "$CONTROL_SOCKET" -O check "$FULL_REMOTE_TARGET" &>/dev/null; then
        rm -f "$CONTROL_SOCKET"
        USED_OTP="$OTP_CODE"
        OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
        WAITED=0
        while [ -n "$OTP_CODE" ] && [ "$OTP_CODE" = "$USED_OTP" ] && [ "$WAITED" -lt 35 ]; do
            [ "$WAITED" -eq 0 ] && echo "Waiting for a fresh 2FA code before creating the ControlMaster..."
            sleep 1; WAITED=$((WAITED + 1))
            OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
        done
        CONTROL_SOCKET="$CONTROL_SOCKET" FULL_REMOTE_TARGET="$FULL_REMOTE_TARGET" OTP_CODE="$OTP_CODE" expect -c '
            set timeout 45
            spawn ssh -M -S $env(CONTROL_SOCKET) -o ControlMaster=yes -o ControlPersist=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -f $env(FULL_REMOTE_TARGET)
            expect {
                -nocase -re {OzSTAR[[:space:]]+2FA code:} { send -- "$env(OTP_CODE)\r"; exp_continue }
                -nocase -re {(verification code|otp|one-time password|token|passcode|2fa code|2fa):} { send -- "$env(OTP_CODE)\r"; exp_continue }
                "Are you sure you want to continue connecting" { send -- "yes\r"; exp_continue }
                timeout { exit 124 }
                eof { catch wait result; exit [lindex $result 3] }
            }
        '
    else
        echo "Reusing existing authenticated OzSTAR ControlMaster."
    fi

    if ! ssh -S "$CONTROL_SOCKET" -O check "$FULL_REMOTE_TARGET" &>/dev/null; then
        echo "Error: Could not establish authenticated ControlMaster." >&2
        exit 1
    fi

    echo "Checking $FULL_REMOTE_TARGET for an existing ~/2fa_secret.gpg through the ControlMaster..."
    if ssh -S "$CONTROL_SOCKET" -o ControlMaster=no -o BatchMode=yes "$FULL_REMOTE_TARGET" '[ -f "$HOME/2fa_secret.gpg" ]'; then
        echo "Remote host already has 2fa_secret.gpg. Leaving it unchanged."
    else
        echo "No 2fa_secret.gpg found on remote host. Copying local copy through the ControlMaster..."
        if scp -o ControlPath="$CONTROL_SOCKET" -o ControlMaster=no -o BatchMode=yes "$GPG_ENC_FILE" "${FULL_REMOTE_TARGET}:/home/$OZSTAR_USER/2fa_secret.gpg"; then
            echo "Copied $GPG_ENC_FILE to ${FULL_REMOTE_TARGET}:~/2fa_secret.gpg"
        else
            echo "Warning: Failed to copy 2FA secret through the ControlMaster."
        fi
    fi
fi
echo ""
# -------------------------------------------------------------------------
# Step 4: Write out the persistent, reusable Remounting Script
# -------------------------------------------------------------------------
echo "=== Step 4: Creating Reusable Mount Script ==="
# Initialize the remount file safely
printf '#!/bin/bash\n# Reusable Mounting Script\n\n' > "$REMOUNT_SCRIPT"
# Inject the configurations safely using robust variable printing
printf 'REMOTE_HOST="%s"\n' "$REMOTE_HOST" >> "$REMOUNT_SCRIPT"
printf 'OZSTAR_USER="%s"\n' "$OZSTAR_USER" >> "$REMOUNT_SCRIPT"
printf 'KEY_PATH="%s"\n' "$KEY_PATH" >> "$REMOUNT_SCRIPT"
printf 'GPG_ENC_FILE="%s"\n' "$GPG_ENC_FILE" >> "$REMOUNT_SCRIPT"
printf 'USE_AUTO_2FA="%s"\n\n' "$USE_AUTO_2FA" >> "$REMOUNT_SCRIPT"
# Append directory arrays and operational logic safely
cat << 'REMOUNT_BLOCK' >> "$REMOUNT_SCRIPT"
SYNC_DIRS=("/fred" "/dagg" "/home/${OZSTAR_USER}")
CONTROL_DIR="$HOME/.ssh/controlmasters"
CONTROL_SOCKET="$CONTROL_DIR/ozstar-${OZSTAR_USER}"
REMOTE_TARGET="${OZSTAR_USER}@${REMOTE_HOST}"
mkdir -p "$CONTROL_DIR"; chmod 700 "$CONTROL_DIR"

# During setup Step 3b has already authenticated this master. On a later
# reconnect_ozstar invocation, recreate it only when necessary.
if ! ssh -S "$CONTROL_SOCKET" -O check "$REMOTE_TARGET" &>/dev/null; then
    echo "ControlMaster is unavailable. Creating a new authenticated master..."
    rm -f "$CONTROL_SOCKET"
    OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
    [ -z "$OTP_CODE" ] && { echo "Error: Could not generate 2FA code." >&2; exit 1; }
    CONTROL_SOCKET="$CONTROL_SOCKET" REMOTE_TARGET="$REMOTE_TARGET" OTP_CODE="$OTP_CODE" expect -c '
        set timeout 45
        spawn ssh -M -S $env(CONTROL_SOCKET) -o ControlMaster=yes -o ControlPersist=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -N -f $env(REMOTE_TARGET)
        expect {
            -nocase -re {OzSTAR[[:space:]]+2FA code:} { send -- "$env(OTP_CODE)\r"; exp_continue }
            -nocase -re {(verification code|otp|one-time password|token|passcode|2fa code|2fa):} { send -- "$env(OTP_CODE)\r"; exp_continue }
            "Are you sure you want to continue connecting" { send -- "yes\r"; exp_continue }
            timeout { exit 124 }
            eof { catch wait result; exit [lindex $result 3] }
        }
    '
fi
ssh -S "$CONTROL_SOCKET" -O check "$REMOTE_TARGET" &>/dev/null || { echo "Error: ControlMaster unavailable." >&2; exit 1; }
echo "Reusing authenticated OzSTAR ControlMaster for SSHFS mounts."

for DIR in "${SYNC_DIRS[@]}"; do
    echo "-------------------------------------------------------"; echo "Mounting Path: $DIR"; echo "-------------------------------------------------------"
    if [ ! -d "$DIR" ]; then
        echo "Directory $DIR does not exist. Creating it (requires sudo for top-level paths)..."
        sudo mkdir -p "$DIR" && sudo chown "$(whoami)":"$(whoami)" "$DIR"
    elif mountpoint -q "$DIR" &>/dev/null; then
        fusermount3 -u "$DIR" &>/dev/null || fusermount3 -uz "$DIR" &>/dev/null
    fi
    sshfs "${REMOTE_TARGET}:${DIR}" "$DIR" \
        -o IdentityFile="$KEY_PATH" \
        -o ControlPath="$CONTROL_SOCKET" \
        -o ControlMaster=no \
        -o BatchMode=yes \
        -o workaround=rename \
        -o reconnect \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3
    rc=$?
    if [ "$rc" -eq 0 ] && mountpoint -q "$DIR"; then echo "Mounted $DIR successfully through the ControlMaster."; else echo "Error: sshfs mount failed for $DIR (status $rc)." >&2; fi
done
echo "=== Mount synchronization script completed ==="
REMOUNT_BLOCK
chmod +x "$REMOUNT_SCRIPT"
echo "Persistent script written successfully to: $REMOUNT_SCRIPT"
echo ""
# -------------------------------------------------------------------------
# Step 4b: Add reconnect_ozstar's directory to PATH via ~/.bashrc
# -------------------------------------------------------------------------
echo "=== Step 4b: Adding $(dirname "$REMOUNT_SCRIPT") to PATH in $MY_BASHRC ==="
REMOUNT_SCRIPT_DIR=$(dirname "$REMOUNT_SCRIPT")
PATH_MARKER="# >>> reconnect_ozstar PATH >>>"
if grep -qF "$PATH_MARKER" "$MY_BASHRC"; then
    echo "reconnect_ozstar PATH entry already present in $MY_BASHRC. Skipping injection."
    :
else
    echo "Appending PATH export for $REMOUNT_SCRIPT_DIR to $MY_BASHRC..."
    cat << PATH_BLOCK >> "$MY_BASHRC"
$PATH_MARKER
# Ensures reconnect_ozstar (and anything else dropped in this directory)
# can be run by name from any new shell, without needing the full path.
if [[ ":\$PATH:" != *":${REMOUNT_SCRIPT_DIR}:"* ]]; then
    export PATH="\$PATH:${REMOUNT_SCRIPT_DIR}"
fi
# <<< reconnect_ozstar PATH <<<
PATH_BLOCK
    echo "PATH entry added successfully!"
fi
echo ""
# -------------------------------------------------------------------------
# Step 5: Execute the newly written file to trigger initial mounting
# -------------------------------------------------------------------------
echo "=== Step 5: Running Mount Operations ==="
bash "$REMOUNT_SCRIPT"
# -------------------------------------------------------------------------
# Step 6: Inject automated sshoz shortcut into ~/.bashrc (CONDITIONAL)
# -------------------------------------------------------------------------
if [ "$USE_AUTO_2FA" = true ]; then
    echo ""
    echo "=== Step 6: Adding sshoz shortcut to $MY_BASHRC ==="
    if grep -q "sshoz()" "$MY_BASHRC"; then
        echo "sshoz function already exists in $MY_BASHRC. Skipping injection."
        :
    else
        echo "Appending sshoz function to $MY_BASHRC..."
        TEMP_FUNC_FILE=$(mktemp)
        cat << 'BASHRC_FUNC' > "$TEMP_FUNC_FILE"
# Custom automated shortcut to SSH into your remote 2FA host
sshoz() {
    local KEY_PATH="$HOME/.ssh/id_ed25519"
    # Re-attach to the persistent keychain-managed ssh-agent in this shell
    local KEYCHAIN_SH="$HOME/.keychain/$(hostname)-sh"
    if [ -f "$KEYCHAIN_SH" ]; then
        source "$KEYCHAIN_SH"
    fi
    # Validate the socket is actually live -- keychain only confirms the
    # recorded agent PID is still running, not that its socket file still
    # exists (it can go stale across session/container recycles). If
    # that's happened, clear the stale state and start a fresh agent,
    # prompting interactively for the passphrase if needed.
    if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
        echo "Warning: keychain agent socket is stale or missing. Restarting agent..."
        keychain --stop all &>/dev/null
        rm -f "$HOME/.keychain/$(hostname)" "$HOME/.keychain/$(hostname)-sh" "$HOME/.keychain/$(hostname)-csh" 2>/dev/null
        expect -c "
            set timeout 15
            spawn keychain --quiet --agents ssh \"$KEY_PATH\"
            expect {
                -nocase \"Enter passphrase\" {
                    interact
                }
                eof
            }
        "
        if [ -f "$KEYCHAIN_SH" ]; then
            source "$KEYCHAIN_SH"
        fi
    fi
    local SECRET_FILE="$HOME/.ssh/2fa_secret.gpg"
    if [ ! -f "$SECRET_FILE" ]; then
        echo "Error: Automated 2FA secret file missing ($SECRET_FILE)."
        echo "Launching standard connection instead..."
        ssh -Y TARGET_PLACEHOLDER
        return
    fi
    local CODE
    CODE=$(gpg -q -d "$SECRET_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
    if [ -z "$CODE" ]; then
        echo "Error: Failed to generate 2FA token (GPG decryption failed)."
        echo "Launching standard connection..."
        ssh -Y TARGET_PLACEHOLDER
        return
    fi
    echo "Generated 2FA Code: $CODE"
    if command -v xclip &> /dev/null; then
        echo -n "$CODE" | xclip -sel clip
        echo "(Copied to Clipboard via xclip)"
    elif command -v wl-copy &> /dev/null; then
        echo -n "$CODE" | wl-copy
        echo "(Copied to Clipboard via wl-copy)"
    elif command -v xsel &> /dev/null; then
        echo -n "$CODE" | xsel -b
        echo "(Copied to Clipboard via xsel)"
    else
        echo "(Clipboard utility not found. Please type or copy the code manually)"
    fi
    echo "Connecting to TARGET_PLACEHOLDER..."
    ssh -Y TARGET_PLACEHOLDER
}
BASHRC_FUNC
        sed -i "s|TARGET_PLACEHOLDER|$FULL_REMOTE_TARGET|g" "$TEMP_FUNC_FILE"
        cat "$TEMP_FUNC_FILE" >> "$MY_BASHRC"
        rm -f "$TEMP_FUNC_FILE"
        echo "Shortcut added successfully!"
    fi
else
    echo ""
    echo "=== Step 6: Skipping sshoz Shortcut ==="
    echo "Automated 2FA string was not supplied; skipping .bashrc modification."
fi
# -------------------------------------------------------------------------
# Step 7: Source the updated configuration natively (Method 1)
# -------------------------------------------------------------------------
echo ""
echo "=== Step 7: Automatically Sourcing Changes ==="
if [ -f "$MY_BASHRC" ]; then
    echo "Sourcing $MY_BASHRC to update active shell..."
    source "$MY_BASHRC"
fi
echo ""
echo "=== Setup Complete ==="
if [ "$USE_AUTO_2FA" = true ]; then
    echo "You can now run 'sshoz' directly in this terminal window!"
fi
