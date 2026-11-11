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
REQUIRED_PKGS=("oathtool" "gpg" "expect" "sshfs" "fuse3" "keychain")

# -------------------------------------------------------------------------
# Step 0: Ensure Required Packages are Installed (APT)
# -------------------------------------------------------------------------
#echo "=== Step 0: Checking System Dependencies ==="

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "$pkg" &> /dev/null && ! dpkg -s "$pkg" &> /dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    #echo "Missing dependencies found: ${MISSING_PKGS[*]}"
    echo "Installing missing packages via apt... (Root/sudo privileges required)"

    sudo apt-get update -y && \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PKGS[@]}"

    for pkg in "${MISSING_PKGS[@]}"; do
        if ! command -v "$pkg" &> /dev/null && ! dpkg -s "$pkg" &> /dev/null; then
            #echo "Error: Failed to install '$pkg'. Please install it manually." >&2
            return 1 2>/dev/null || exit 1
        fi
    done
    #echo "All dependencies successfully installed."
#else
    #echo "All required dependencies are already installed."
fi
#echo ""

# -------------------------------------------------------------------------
# Step 1: Obtain Remote Username and Optional 2FA String
# -------------------------------------------------------------------------
#echo "=== Step 1: User & 2FA Configuration ==="

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
read -rs -p "Enter your ozstar 2FA Setup String (Leave blank to input 2FA codes manually later): " TFA_SECRET
echo ""

USE_AUTO_2FA=false
if [ -n "$TFA_SECRET" ]; then
    #echo "Encrypting 2FA secret..."
    #echo "$TFA_SECRET" | gpg --symmetric --output "$GPG_ENC_FILE" --yes
    unset TFA_SECRET
    #echo "Saved encrypted secret to $GPG_ENC_FILE"
    USE_AUTO_2FA=true
else
    echo "No 2FA setup string provided. You will be prompted for your 2FA code during connections."
    rm -f "$GPG_ENC_FILE"
fi
echo ""

# -------------------------------------------------------------------------
# Step 2: Generate the SSH Key (Enforcing Non-Empty Passphrase)
# -------------------------------------------------------------------------
#echo "=== Step 2: SSH Key Generation ==="
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
#echo "=== Step 2b: Loading Key via keychain ==="

#echo "Starting/attaching to keychain-managed ssh-agent and adding $KEY_PATH..."
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
    #else
        #echo "Fresh agent started successfully."
    fi
fi

unset PASS1 PASS2
#echo "Key loaded via keychain. The agent persists across terminals/sessions (until reboot or 'keychain --stop'),"
#echo "so subsequent ssh/scp calls -- including in future shells -- won't re-prompt for the key passphrase."
#echo ""

# -------------------------------------------------------------------------
# Step 3: Copy ID via Expect (Conditional 2FA Handling & Fallback)
# -------------------------------------------------------------------------
#echo "=== Step 3: Copying SSH Key to $FULL_REMOTE_TARGET ==="

OTP_CODE=""
if [ "$USE_AUTO_2FA" = true ]; then
    #echo "Decrypting 2FA setup string to generate live OTP..."
    CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)

    if [ -z "$CODE" ]; then
        echo "Warning: Failed to decrypt or generate OTP code automatically. Falling back to manual entry."
        USE_AUTO_2FA=false
    else
        OTP_CODE="$CODE"
        #echo "Generated automated OTP Token successfully."
    fi
fi

#echo "Initiating ssh-copy-id..."
#echo ""

# NOTE: the expect script is written to a temp file and invoked as
# `expect /path/to/file` (rather than piped in via a `<<EOF` heredoc on
# stdin). This matters because `interact` hands control of the *invoking
# process's* stdin/stdout over to the spawned program -- if that stdin is
# a heredoc, it is already exhausted/closed by the time `interact` runs,
# so the manual-password fallback would silently fail to let you type
# anything. Writing to a file instead leaves the real terminal's stdin
# untouched and available to `interact`.
STEP3_EXP=$(mktemp /tmp/setup_ssh_step3.XXXXXX.exp)
cat > "$STEP3_EXP" <<EOF
set timeout 30
spawn ssh-copy-id -i "${KEY_PATH}.pub" "$FULL_REMOTE_TARGET"

expect {
    -nocase -re "(verification code|otp|one-time password|token):" {
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
        interact
    }
    eof
}
EOF
expect "$STEP3_EXP"
rm -f "$STEP3_EXP"
#echo ""

# -------------------------------------------------------------------------
# Step 3b: Reconcile the 2FA Secret Between Local and Remote Host
#          (Every ssh/scp call below is wrapped in the same expect-driven
#          OTP-handling logic used in Step 3: auto-send $OTP_CODE when
#          USE_AUTO_2FA is true, otherwise fall through to manual "interact".
#          As in Step 3, each expect script is written to a temp file and
#          run as `expect file` rather than piped via a stdin heredoc, so
#          that `interact` has access to the real terminal stdin.)
# -------------------------------------------------------------------------
#echo "=== Step 3b: Reconciling 2FA Secret With Remote Host ==="

if [ "$USE_AUTO_2FA" = false ]; then
    # No local setup string was supplied -- check whether the remote host
    # already has one saved from a previous run, and pull it down if so.
    echo "No local 2FA setup string was provided. Checking $FULL_REMOTE_TARGET for ~/2fa_secret.gpg..."

    STEP3B_CHECK_EXP=$(mktemp /tmp/setup_ssh_step3b_check.XXXXXX.exp)
    cat > "$STEP3B_CHECK_EXP" <<EOF
set timeout 30
spawn ssh -i "$KEY_PATH" "$FULL_REMOTE_TARGET" {[ -f "\$HOME/2fa_secret.gpg" ]}

expect {
    -nocase -re "(verification code|otp|one-time password|token):" {
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
        interact
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
    -nocase -re "(verification code|otp|one-time password|token):" {
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
        interact
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
    # A local setup string WAS supplied and encrypted into $GPG_ENC_FILE.
    # If the remote host doesn't already have a copy, push it up now so
    # future connections (e.g. from other machines) can reuse it.
    #echo "Local 2FA setup string was provided. Checking $FULL_REMOTE_TARGET for an existing ~/2fa_secret.gpg..."

    # Regenerate a fresh OTP right before use -- TOTP codes rotate (typically
    # every ~30s), and the $OTP_CODE generated back in Step 3 may have
    # expired by the time execution reaches here.
    OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)

    STEP3B_CHECK2_EXP=$(mktemp /tmp/setup_ssh_step3b_check2.XXXXXX.exp)
    cat > "$STEP3B_CHECK2_EXP" <<EOF
set timeout 30
spawn ssh -i "$KEY_PATH" "$FULL_REMOTE_TARGET" {[ -f "\$HOME/2fa_secret.gpg" ]}

expect {
    -nocase -re "(verification code|otp|one-time password|token):" {
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
        interact
    }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
    expect "$STEP3B_CHECK2_EXP"
    REMOTE_FILE_EXISTS=$?
    rm -f "$STEP3B_CHECK2_EXP"

    if [ "$REMOTE_FILE_EXISTS" -eq 0 ]; then
        echo "Remote host already has 2fa_secret.gpg. Leaving it unchanged."
    else
        echo "No 2fa_secret.gpg found on remote host. Copying local copy there for future use..."

        # Regenerate again -- the existence-check ssh call above may have
        # consumed enough wall-clock time to roll over to the next TOTP window.
        OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)

        STEP3B_PUSH_EXP=$(mktemp /tmp/setup_ssh_step3b_push.XXXXXX.exp)
        cat > "$STEP3B_PUSH_EXP" <<EOF
set timeout 30
spawn scp -i "$KEY_PATH" "$GPG_ENC_FILE" {${FULL_REMOTE_TARGET}:/home/$OZSTAR_USER/2fa_secret.gpg}

expect {
    -nocase -re "(verification code|otp|one-time password|token):" {
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
        interact
    }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
        expect "$STEP3B_PUSH_EXP"
        SCP_STATUS=$?
        rm -f "$STEP3B_PUSH_EXP"

        if [ "$SCP_STATUS" -eq 0 ]; then
            echo "Copied $GPG_ENC_FILE to ${FULL_REMOTE_TARGET}:~/2fa_secret.gpg"
        else
            echo "Warning: Failed to copy 2FA secret to remote host. You can retry this manually later."
        fi
    fi
fi
echo ""

# -------------------------------------------------------------------------
# Step 4: Write out the persistent, reusable Remounting Script
# -------------------------------------------------------------------------
#echo "=== Step 4: Creating Reusable Mount Script ==="

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
SYNC_DIRS=(
    "/fred"
    "/dagg"
    "/home/${OZSTAR_USER}"
)

for DIR in "${SYNC_DIRS[@]}"; do
    #echo "-------------------------------------------------------"
    #echo "Mounting Path: $DIR"
    #echo "-------------------------------------------------------"

    if [ -d "$DIR" ]; then
        #echo "Directory $DIR already exists. Skipping creation."
        if mountpoint -q "$DIR" &>/dev/null; then
            fusermount3 -u "$DIR" &>/dev/null
        fi
    else
        #echo "Directory $DIR does not exist. Creating it (requires sudo for top-level paths)..."
        sudo mkdir -p "$DIR"
        sudo chown "$(whoami)":"$(whoami)" "$DIR"
    fi

    CURRENT_AUTO_2FA="$USE_AUTO_2FA"
    if [ "$CURRENT_AUTO_2FA" = true ]; then
        if [ -f "$GPG_ENC_FILE" ]; then
            OTP_CODE=$(gpg -q -d "$GPG_ENC_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
            if [ -z "$OTP_CODE" ]; then
                echo "Warning: Token generation failed. Falling back to manual entry for this path."
                CURRENT_AUTO_2FA=false
            fi
        else
            #echo "Warning: Persistent GPG secret file missing. Falling back to manual entry."
            CURRENT_AUTO_2FA=false
        fi
    fi

    # Re-attach this (sub)shell to the persistent keychain-managed ssh-agent
    # so SSH_AUTH_SOCK is set before sshfs is spawned, letting it use the
    # already-unlocked key instead of needing the passphrase typed again.
    KEYCHAIN_SH="$HOME/.keychain/$(hostname)-sh"
    if [ -f "$KEYCHAIN_SH" ]; then
        # shellcheck disable=SC1090
        source "$KEYCHAIN_SH"
    fi

    # Validate the socket is actually live -- keychain only confirms the
    # recorded agent PID is still running, not that its socket file still
    # exists. If /tmp was cleared since the agent was started (session
    # recycle, reboot) but the PID got reused by something else, keychain
    # will hand back a path to a socket that no longer exists. In that
    # case, clear the stale state and start a genuinely fresh agent,
    # prompting interactively for the key passphrase if needed.
    if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
        #echo "Warning: keychain agent socket is stale or missing. Restarting agent..."
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
            # shellcheck disable=SC1090
            source "$KEYCHAIN_SH"
        fi

        if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
            echo "Error: Still no working agent socket for $DIR. sshfs mount below will likely fail to authenticate." >&2
        fi
    fi

    # sshfs via the system OpenSSH client -- it picks up SSH_AUTH_SOCK (and
    # thus the already-unlocked keychain-managed key) the same way plain
    # ssh/scp do, with no equivalent of rclone's key_file+key_use_agent bug.
    #
    # NOTE: sshfs does NOT support a standalone `-i <path>` flag the way
    # ssh/scp do. Passing -i directly confuses its argument parser and
    # causes it to misread the mountpoint as an unexpected extra argument
    # ("invalid argument `/fred'"). The identity file must instead be
    # passed through sshfs's generic -o option mechanism as
    # -o IdentityFile=<path>.
    #
    # NOTE: SSHFS_CMD contains embedded double quotes (around the socket
    # path and key path). Passing it to Tcl as `spawn bash -c "$SSHFS_CMD"`
    # would close the Tcl string early once bash substitutes the quotes in
    # ("extra characters after close-quote"). Using Tcl brace-quoting
    # `{$SSHFS_CMD}` instead avoids this: bash still expands the variable
    # before Tcl parses the line, but braces make Tcl treat the whole
    # expanded text (quotes included) as one literal argument.
    SSHFS_CMD="env SSH_AUTH_SOCK=\"$SSH_AUTH_SOCK\" sshfs -o IdentityFile=\"$KEY_PATH\" ${OZSTAR_USER}@${REMOTE_HOST}:${DIR} ${DIR} -o workaround=rename -o reconnect -o ServerAliveInterval=15"

    expect <<OUTER_EOF
    set timeout 20
    spawn bash -c {$SSHFS_CMD}

    expect {
        -nocase -re "(verification code|otp|one-time password|token):" {
            if { "\$CURRENT_AUTO_2FA" == "true" } {
                send "$OTP_CODE\r"
                exp_continue
            } else {
                interact
            }
        }
        -nocase "password:" {
            interact
        }
        eof
    }
OUTER_EOF
done

#echo "=== Mount synchronization script completed ==="
REMOUNT_BLOCK

chmod +x "$REMOUNT_SCRIPT"
#echo "Persistent script written successfully to: $REMOUNT_SCRIPT"
#echo ""

# -------------------------------------------------------------------------
# Step 4b: Add reconnect_ozstar's directory to PATH via ~/.bashrc
# -------------------------------------------------------------------------
#echo "=== Step 4b: Adding $(dirname "$REMOUNT_SCRIPT") to PATH in $MY_BASHRC ==="

REMOUNT_SCRIPT_DIR=$(dirname "$REMOUNT_SCRIPT")
PATH_MARKER="# >>> reconnect_ozstar PATH >>>"
if grep -qF "$PATH_MARKER" "$MY_BASHRC"; then
    #echo "reconnect_ozstar PATH entry already present in $MY_BASHRC. Skipping injection."
else
    #echo "Appending PATH export for $REMOUNT_SCRIPT_DIR to $MY_BASHRC..."
    cat << PATH_BLOCK >> "$MY_BASHRC"

$PATH_MARKER
# Ensures reconnect_ozstar (and anything else dropped in this directory)
# can be run by name from any new shell, without needing the full path.
if [[ ":\$PATH:" != *":${REMOUNT_SCRIPT_DIR}:"* ]]; then
    export PATH="\$PATH:${REMOUNT_SCRIPT_DIR}"
fi
# <<< reconnect_ozstar PATH <<<
PATH_BLOCK
    #echo "PATH entry added successfully!"
fi
#echo ""

# -------------------------------------------------------------------------
# Step 5: Execute the newly written file to trigger initial mounting
# -------------------------------------------------------------------------
#echo "=== Step 5: Running Mount Operations ==="
bash "$REMOUNT_SCRIPT"

# -------------------------------------------------------------------------
# Step 6: Inject automated sshoz shortcut into ~/.bashrc (CONDITIONAL)
# -------------------------------------------------------------------------
if [ "$USE_AUTO_2FA" = true ]; then
    #echo ""
    #echo "=== Step 6: Adding sshoz shortcut to $MY_BASHRC ==="

    if grep -q "sshoz()" "$MY_BASHRC"; then
        #echo "sshoz function already exists in $MY_BASHRC. Skipping injection."
    else
        #echo "Appending sshoz function to $MY_BASHRC..."

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
        #echo "Warning: keychain agent socket is stale or missing. Restarting agent..."
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
        #echo "Error: Automated 2FA secret file missing ($SECRET_FILE)."
        #echo "Launching standard connection instead..."
        ssh -Y TARGET_PLACEHOLDER
        return
    fi

    local CODE
    CODE=$(gpg -q -d "$SECRET_FILE" 2>/dev/null | oathtool --base32 --totp - 2>/dev/null)
    if [ -z "$CODE" ]; then
        #echo "Error: Failed to generate 2FA token (GPG decryption failed)."
        #echo "Launching standard connection..."
        ssh -Y TARGET_PLACEHOLDER
        return
    fi

    #echo "Generated 2FA Code: $CODE"

    if command -v xclip &> /dev/null; then
        echo -n "$CODE" | xclip -sel clip
        #echo "(Copied to Clipboard via xclip)"
    elif command -v wl-copy &> /dev/null; then
        echo -n "$CODE" | wl-copy
        #echo "(Copied to Clipboard via wl-copy)"
    elif command -v xsel &> /dev/null; then
        echo -n "$CODE" | xsel -b
        #echo "(Copied to Clipboard via xsel)"
    else
        echo "(Clipboard utility not found. Please type or copy the code manually)"
    fi

    #echo "Connecting to TARGET_PLACEHOLDER..."
    ssh -Y TARGET_PLACEHOLDER
}
BASHRC_FUNC

        sed -i "s|TARGET_PLACEHOLDER|$FULL_REMOTE_TARGET|g" "$TEMP_FUNC_FILE"
        cat "$TEMP_FUNC_FILE" >> "$MY_BASHRC"
        rm -f "$TEMP_FUNC_FILE"

        #echo "Shortcut added successfully!"
    fi
#else
    #echo ""
    #echo "=== Step 6: Skipping sshoz Shortcut ==="
    #echo "Automated 2FA string was not supplied; skipping .bashrc modification."
fi

# -------------------------------------------------------------------------
# Step 7: Source the updated configuration natively (Method 1)
# -------------------------------------------------------------------------
#echo ""
#echo "=== Step 7: Automatically Sourcing Changes ==="
if [ -f "$MY_BASHRC" ]; then
    #echo "Sourcing $MY_BASHRC to update active shell..."
    source "$MY_BASHRC"
fi

#echo ""
#echo "=== Setup Complete ==="
if [ "$USE_AUTO_2FA" = true ]; then
    #echo "You can now run 'sshoz' directly in this terminal window!"
fi
