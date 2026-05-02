#!/usr/bin/env bash
# =============================================================================
#  Linux PC Transfer Script
#  Copies user files, config/dotfiles, browser data, and system info
#  to a USB drive or any destination folder.
#
#  Usage:
#    chmod +x pc-transfer.sh
#    ./pc-transfer.sh
#    sudo ./pc-transfer.sh     (recommended — needed for some system exports)
#
#  Tested on: Ubuntu, Debian, Fedora, Arch, Linux Mint, Pop!_OS
# =============================================================================

set -euo pipefail

# Print exact line/command if set -e kills the script unexpectedly
trap 'echo -e "\n${RED}[!!] Script died at line ${LINENO}: ${BASH_COMMAND}${RESET}" >&2' ERR
# Tee all stderr to a debug log
exec 2> >(tee /tmp/pc-transfer-debug.log >&2)

# ─────────────────────────────────────────────
#  CONFIGURATION — edit these if desired
# ─────────────────────────────────────────────
SKIP_BROWSER_DATA=false
SKIP_SSH_KEYS=false
SKIP_GPG_KEYS=false
SKIP_CRON_JOBS=false
SKIP_ENV_VARS=false
SKIP_DOTFILES=false

# rsync options: archive, skip newer, human-readable, no specials/devices
RSYNC_OPTS=(-a --update --human-readable --no-specials --no-devices
            --exclude="*.tmp" --exclude="*.log" --exclude="*.lock"
            --exclude=".cache" --exclude="cache" --exclude="Cache"
            --exclude="CacheStorage" --exclude="Code Cache"
            --exclude="GPUCache" --exclude="ShaderCache"
            --exclude="Service Worker" --exclude="Crashpad"
            --exclude="*.sock" --exclude="*.pid")

# ─────────────────────────────────────────────
#  COLOURS & HELPERS
# ─────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log_lines=()

header()  { echo -e "\n${CYAN}$(printf '=%.0s' {1..60})${RESET}"; \
             echo -e "${CYAN}  $1${RESET}"; \
             echo -e "${CYAN}$(printf '=%.0s' {1..60})${RESET}"; }
step()    { echo -e "\n${YELLOW}>> $1${RESET}"; }
ok()      { echo -e "   ${GREEN}[OK]${RESET} $1"; }
skip()    { echo -e "   \033[2m[--] $1${RESET}"; }
warn()    { echo -e "   ${RED}[!!]${RESET} $1"; }
add_log() { log_lines+=("[$(date '+%H:%M:%S')] $1"); }

format_bytes() {
    local b=$1
    if   (( b >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576 ));    then printf "%.1f MB" "$(echo "scale=1; $b/1048576" | bc)"
    else                             printf "%.1f KB" "$(echo "scale=1; $b/1024" | bc)"; fi
}

dir_size_bytes() {
    du -sb "$1" 2>/dev/null | awk '{print $1}' || echo 0
}

do_rsync() {
    local src="$1" dst="$2"
    shift 2
    if [[ ! -e "$src" ]]; then
        skip "Source not found, skipping: $src"
        return
    fi
    mkdir -p "$dst"
    if rsync "${RSYNC_OPTS[@]}" "$@" "$src/" "$dst/" 2>/dev/null; then
        ok "Copied: $src"
    else
        warn "rsync reported issues for: $src (exit $?)"
    fi
}

require_cmd() {
    command -v "$1" &>/dev/null || { warn "Required command '$1' not found. Install it and retry."; exit 1; }
}

# ─────────────────────────────────────────────
#  CHECKS
# ─────────────────────────────────────────────
require_cmd rsync
require_cmd bc

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ─────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────
clear
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║       Linux PC Transfer Script           ║"
echo "  ║   Copies files, configs & system info    ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}User    :${RESET} $REAL_USER"
echo -e "  ${BOLD}Home    :${RESET} $REAL_HOME"
echo -e "  ${BOLD}Host    :${RESET} $(hostname)"
echo -e "  ${BOLD}Distro  :${RESET} $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')"
echo -e "  ${BOLD}Date    :${RESET} $(date '+%Y-%m-%d %H:%M')"
echo

# ─────────────────────────────────────────────
#  CHOOSE DESTINATION
# ─────────────────────────────────────────────
header "Choose Destination"

echo
echo -e "  Where do you want to copy the files?\n"
echo    "  [1] USB Drive  — list mounted removable drives and pick one"
echo    "  [2] Folder     — type a custom path (e.g. /mnt/backup)"
echo

read -rp "  Enter 1 or 2: " dest_choice

if [[ "$dest_choice" == "1" ]]; then
    echo
    echo -e "  Scanning for removable drives...\n"

    detect_usb_drives() {
        mount_paths=()
        display_lines=()

        # Search the standard auto-mount locations directly.
        # This avoids all lsblk column-parsing issues entirely.
        # Priority: /run/media/<user> (KDE/systemd), /media/<user> (GNOME), /media (legacy)
        local candidates=()
        local pattern

        for pattern in \
            "/run/media/$REAL_USER/"* \
            "/run/media/"*"/"* \
            "/media/$REAL_USER/"* \
            "/media/"*
        do
            [[ -d "$pattern" ]] && candidates+=("$pattern")
        done

        # Also catch anything findmnt reports with a removable filesystem type
        while IFS= read -r mnt; do
            [[ -d "$mnt" ]] && candidates+=("$mnt")
        done < <(findmnt -lo TARGET,FSTYPE 2>/dev/null | \
                 awk '$2~/vfat|exfat|ntfs|fuseblk/ {print $1}' || true)

        # Deduplicate while preserving order
        local seen=()
        local already mnt sz src lbl
        for mnt in "${candidates[@]}"; do
            already=false
            for s in "${seen[@]:-}"; do [[ "$s" == "$mnt" ]] && already=true && break; done
            $already && continue
            seen+=("$mnt")
            sz=$(df -h "$mnt" 2>/dev/null | awk 'NR==2{print $2}') || sz="?"
            src=$(findmnt -no SOURCE "$mnt" 2>/dev/null || true)
            lbl=$(lsblk -no LABEL "$src" 2>/dev/null || true)
            mount_paths+=("$mnt")
            display_lines+=("$mnt  (${sz}${lbl:+  \"$lbl\"})")
        done
    }

    detect_usb_drives

    if [[ ${#mount_paths[@]} -eq 0 ]]; then
        warn "No removable drives detected. Plug in your USB, then press Enter to retry."
        read -r
        detect_usb_drives
        [[ ${#mount_paths[@]} -eq 0 ]] && { warn "Still no drives found. Exiting."; exit 1; }
    fi

    echo "  Available drives:"
    for i in "${!display_lines[@]}"; do
        echo "    $((i+1)))  ${display_lines[$i]}"
    done
    echo

    while true; do
        read -rp "  Pick drive number [1-${#mount_paths[@]}]: " drv_num
        [[ "$drv_num" =~ ^[0-9]+$ ]] && \
        (( drv_num >= 1 && drv_num <= ${#mount_paths[@]} )) && break
        warn "Please enter a number between 1 and ${#mount_paths[@]}"
    done

    USB_MOUNT="${mount_paths[$((drv_num - 1))]}"
    echo -e "\n  ${CYAN}Selected: $USB_MOUNT${RESET}"
    DEST_ROOT="$USB_MOUNT/PC-Transfer_$(hostname)"

else
    echo
    read -rp "  Enter destination folder path: " custom_path
    DEST_ROOT="$custom_path/PC-Transfer_$(hostname)"
fi

echo
echo -e "  ${GREEN}Destination: $DEST_ROOT${RESET}"
add_log "Destination: $DEST_ROOT"
mkdir -p "$DEST_ROOT"

# ─────────────────────────────────────────────
#  SECTION 1 — USER FILES
# ─────────────────────────────────────────────
header "Section 1/6 — User Files"
add_log "--- User Files ---"

declare -A USER_DIRS=(
    [Desktop]="$REAL_HOME/Desktop"
    [Documents]="$REAL_HOME/Documents"
    [Downloads]="$REAL_HOME/Downloads"
    [Pictures]="$REAL_HOME/Pictures"
    [Videos]="$REAL_HOME/Videos"
    [Music]="$REAL_HOME/Music"
    [Templates]="$REAL_HOME/Templates"
    [Public]="$REAL_HOME/Public"
)

# Also include XDG user dirs if defined
if [[ -f "$REAL_HOME/.config/user-dirs.dirs" ]]; then
    # shellcheck disable=SC1090
    source "$REAL_HOME/.config/user-dirs.dirs" 2>/dev/null || true
    [[ -n "${XDG_DESKTOP_DIR:-}"   ]] && USER_DIRS[Desktop]="${XDG_DESKTOP_DIR/#\$HOME/$REAL_HOME}"
    [[ -n "${XDG_DOCUMENTS_DIR:-}" ]] && USER_DIRS[Documents]="${XDG_DOCUMENTS_DIR/#\$HOME/$REAL_HOME}"
    [[ -n "${XDG_DOWNLOAD_DIR:-}"  ]] && USER_DIRS[Downloads]="${XDG_DOWNLOAD_DIR/#\$HOME/$REAL_HOME}"
    [[ -n "${XDG_PICTURES_DIR:-}"  ]] && USER_DIRS[Pictures]="${XDG_PICTURES_DIR/#\$HOME/$REAL_HOME}"
    [[ -n "${XDG_VIDEOS_DIR:-}"    ]] && USER_DIRS[Videos]="${XDG_VIDEOS_DIR/#\$HOME/$REAL_HOME}"
    [[ -n "${XDG_MUSIC_DIR:-}"     ]] && USER_DIRS[Music]="${XDG_MUSIC_DIR/#\$HOME/$REAL_HOME}"
fi

for name in "${!USER_DIRS[@]}"; do
    src="${USER_DIRS[$name]}"
    step "Copying $name..."
    do_rsync "$src" "$DEST_ROOT/UserFiles/$name"
    add_log "User folder: $name"
done

# ─────────────────────────────────────────────
#  SECTION 2 — DOTFILES & CONFIG
# ─────────────────────────────────────────────
header "Section 2/6 — Dotfiles & Config"
add_log "--- Dotfiles ---"

if [[ "$SKIP_DOTFILES" == false ]]; then
    # Show size of ~/.config and notable dotfiles
    config_size=$(dir_size_bytes "$REAL_HOME/.config" 2>/dev/null || echo 0)
    echo
    echo -e "  ~/.config size: $(format_bytes "$config_size")"
    echo

    echo    "  Which config/dotfiles do you want to copy?"
    echo    "  (Press Enter to accept defaults shown in brackets)"
    echo

    read -rp "  Copy ~/.config (app settings, themes)? [Y/n]: " copy_config
    read -rp "  Copy shell configs (.bashrc .zshrc .profile etc.)? [Y/n]: " copy_shell
    read -rp "  Copy ~/.local/share (app data, fonts, icons)? [n/Y]: " copy_local_share

    if [[ ! "$copy_config" =~ ^[Nn]$ ]]; then
        step "Copying ~/.config..."
        do_rsync "$REAL_HOME/.config" "$DEST_ROOT/Config/dot-config" \
            --exclude="google-chrome/Default/Cache" \
            --exclude="chromium/Default/Cache" \
            --exclude="BraveSoftware/Brave-Browser/Default/Cache" \
            --exclude="*/Cache/*" \
            --exclude="*/GPUCache/*"
        add_log "~/.config copied"
    else skip "~/.config skipped"; fi

    if [[ ! "$copy_shell" =~ ^[Nn]$ ]]; then
        step "Copying shell configs..."
        shell_files=(.bashrc .bash_profile .bash_aliases .bash_history
                     .zshrc .zsh_history .zprofile .zshenv
                     .profile .inputrc .dircolors .aliases
                     .exports .functions .extra)
        mkdir -p "$DEST_ROOT/Config/shell"
        for f in "${shell_files[@]}"; do
            [[ -f "$REAL_HOME/$f" ]] && {
                cp "$REAL_HOME/$f" "$DEST_ROOT/Config/shell/$f"
                ok "Copied: ~/$f"
                add_log "Shell file: $f"
            }
        done
        # Copy shell plugin dirs (oh-my-zsh, bash-it, etc.)
        for d in .oh-my-zsh .bash_it .zinit .antigen .zplug .zcomet; do
            [[ -d "$REAL_HOME/$d" ]] && {
                step "Copying $d..."
                do_rsync "$REAL_HOME/$d" "$DEST_ROOT/Config/shell/$d"
                add_log "Shell plugin dir: $d"
            }
        done
    else skip "Shell configs skipped"; fi

    if [[ "$copy_local_share" =~ ^[Yy]$ ]]; then
        step "Copying ~/.local/share (this may take a while)..."
        do_rsync "$REAL_HOME/.local/share" "$DEST_ROOT/Config/local-share" \
            --exclude="Trash" --exclude="recently-used.xbel" \
            --exclude="gvfs-metadata" --exclude="*/Cache/*"
        add_log "~/.local/share copied"
    else skip "~/.local/share skipped"; fi

    # Misc common dotfiles/dirs
    step "Copying other dotfiles..."
    other_dots=(.gitconfig .gitignore_global .editorconfig .curlrc .wgetrc
                .nanorc .vimrc .vim .nvim .tmux.conf .tmux
                .screenrc .selected_editor .nvm .rbenv .pyenv
                .cargo .rustup .go .gradle .m2 .npm .npmrc .yarnrc)
    mkdir -p "$DEST_ROOT/Config/dotfiles"
    for item in "${other_dots[@]}"; do
        path="$REAL_HOME/$item"
        if [[ -e "$path" ]]; then
            if [[ -d "$path" ]]; then
                do_rsync "$path" "$DEST_ROOT/Config/dotfiles/$item"
            else
                cp "$path" "$DEST_ROOT/Config/dotfiles/$item"
                ok "Copied: ~/$item"
            fi
            add_log "Dotfile: $item"
        fi
    done
else
    skip "Dotfiles/config skipped"
fi

# ─────────────────────────────────────────────
#  SECTION 3 — BROWSER DATA
# ─────────────────────────────────────────────
header "Section 3/6 — Browser Data"
add_log "--- Browser Data ---"

if [[ "$SKIP_BROWSER_DATA" == false ]]; then
    declare -A BROWSERS=(
        [Chrome]="$REAL_HOME/.config/google-chrome"
        [Chromium]="$REAL_HOME/.config/chromium"
        [Firefox]="$REAL_HOME/.mozilla/firefox"
        [Brave]="$REAL_HOME/.config/BraveSoftware/Brave-Browser"
        [Vivaldi]="$REAL_HOME/.config/vivaldi"
        [Opera]="$REAL_HOME/.config/opera"
        [LibreWolf]="$REAL_HOME/.librewolf"
        [Waterfox]="$REAL_HOME/.waterfox"
        [Thunderbird]="$REAL_HOME/.thunderbird"
    )

    BROWSER_EXCLUDES=(
        --exclude="*/Cache/*" --exclude="*/cache2/*" --exclude="*/GPUCache/*"
        --exclude="*/Code Cache/*" --exclude="*/ShaderCache/*"
        --exclude="*/Service Worker/CacheStorage/*"
        --exclude="*.log" --exclude="*.dmp"
    )

    for bname in "${!BROWSERS[@]}"; do
        src="${BROWSERS[$bname]}"
        if [[ -d "$src" ]]; then
            step "Copying $bname..."
            do_rsync "$src" "$DEST_ROOT/Browsers/$bname" "${BROWSER_EXCLUDES[@]}"
            add_log "Browser: $bname"
        else
            skip "$bname not found"
        fi
    done
else
    skip "Browser data skipped"
fi

# ─────────────────────────────────────────────
#  SECTION 4 — INSTALLED PACKAGES
# ─────────────────────────────────────────────
header "Section 4/6 — Installed Packages"
add_log "--- Installed Packages ---"

mkdir -p "$DEST_ROOT/System"
step "Detecting package manager and exporting package list..."

# Detect distro family
if command -v apt &>/dev/null; then
    # Debian / Ubuntu / Mint
    step "APT packages (explicitly installed)..."
    apt-mark showmanual 2>/dev/null \
        > "$DEST_ROOT/System/packages-apt-manual.txt" && \
        ok "Saved packages-apt-manual.txt"
    dpkg --get-selections 2>/dev/null \
        > "$DEST_ROOT/System/packages-apt-all.txt" && \
        ok "Saved packages-apt-all.txt (all installed)"
    add_log "APT packages exported"

    # Snap
    if command -v snap &>/dev/null; then
        snap list 2>/dev/null > "$DEST_ROOT/System/packages-snap.txt" && \
            ok "Saved packages-snap.txt"
        add_log "Snap packages exported"
    fi

    # Flatpak
    if command -v flatpak &>/dev/null; then
        flatpak list --app --columns=application,name,version 2>/dev/null \
            > "$DEST_ROOT/System/packages-flatpak.txt" && \
            ok "Saved packages-flatpak.txt"
        add_log "Flatpak packages exported"
    fi

elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    # Fedora / RHEL / CentOS
    PKG_CMD=$(command -v dnf || command -v yum)
    step "DNF/YUM packages..."
    $PKG_CMD history userinstalled 2>/dev/null \
        > "$DEST_ROOT/System/packages-dnf.txt" || \
    rpm -qa --queryformat "%{NAME}\n" 2>/dev/null | sort \
        > "$DEST_ROOT/System/packages-rpm.txt"
    ok "Saved package list"
    add_log "DNF/YUM packages exported"

elif command -v pacman &>/dev/null; then
    # Arch / Manjaro
    step "Pacman packages (explicitly installed)..."
    pacman -Qe 2>/dev/null > "$DEST_ROOT/System/packages-pacman-explicit.txt" && \
        ok "Saved packages-pacman-explicit.txt"
    pacman -Qm 2>/dev/null > "$DEST_ROOT/System/packages-aur.txt" && \
        ok "Saved packages-aur.txt (AUR / foreign packages)"
    add_log "Pacman packages exported"

elif command -v zypper &>/dev/null; then
    # openSUSE
    step "Zypper packages..."
    zypper packages --installed-only 2>/dev/null \
        > "$DEST_ROOT/System/packages-zypper.txt" && \
        ok "Saved packages-zypper.txt"
    add_log "Zypper packages exported"

else
    warn "Unknown package manager — skipping package list"
fi

# Language package managers
for tool_info in "pip:pip freeze > $DEST_ROOT/System/packages-pip.txt" \
                 "pip3:pip3 freeze > $DEST_ROOT/System/packages-pip3.txt" \
                 "npm:npm list -g --depth=0 > $DEST_ROOT/System/packages-npm.txt 2>/dev/null" \
                 "gem:gem list > $DEST_ROOT/System/packages-gem.txt" \
                 "cargo:cargo install --list > $DEST_ROOT/System/packages-cargo.txt 2>/dev/null"; do
    tool="${tool_info%%:*}"
    cmd="${tool_info#*:}"
    if command -v "$tool" &>/dev/null; then
        eval "$cmd" 2>/dev/null && ok "Saved packages-${tool}.txt" || true
        add_log "$tool packages exported"
    fi
done

# ─────────────────────────────────────────────
#  SECTION 5 — SSH & GPG KEYS
# ─────────────────────────────────────────────
header "Section 5/6 — SSH & GPG Keys"
add_log "--- SSH & GPG ---"

if [[ "$SKIP_SSH_KEYS" == false ]]; then
    SSH_DIR="$REAL_HOME/.ssh"
    if [[ -d "$SSH_DIR" ]]; then
        step "Copying SSH keys and config..."
        mkdir -p "$DEST_ROOT/SSH"
        cp -r "$SSH_DIR/." "$DEST_ROOT/SSH/"
        chmod 700 "$DEST_ROOT/SSH"
        find "$DEST_ROOT/SSH" -name "*.pub" -exec chmod 644 {} \;
        find "$DEST_ROOT/SSH" -name "id_*" ! -name "*.pub" -exec chmod 600 {} \;
        ok "SSH keys copied (permissions preserved)"
        add_log "SSH keys copied"
    else
        skip "~/.ssh not found"
    fi
fi

if [[ "$SKIP_GPG_KEYS" == false ]]; then
    if command -v gpg &>/dev/null; then
        step "Exporting GPG keys..."
        mkdir -p "$DEST_ROOT/GPG"

        key_count=$(gpg --list-keys --with-colons 2>/dev/null | grep -c "^pub:" || true)
        if [[ "$key_count" -eq 0 ]]; then
            skip "No GPG keys found in keyring"
        else
            # Public keys — no passphrase needed
            if gpg --batch --yes --export --armor                     > "$DEST_ROOT/GPG/public-keys.asc" 2>/dev/null; then
                ok "GPG public keys exported"
                add_log "GPG public keys exported"
            else
                warn "GPG public key export failed"
            fi

            gpg --batch --export-ownertrust                 > "$DEST_ROOT/GPG/ownertrust.txt" 2>/dev/null || true

            # Secret keys — loopback keeps the prompt in terminal, not a GUI dialog
            echo
            echo -e "  ${YELLOW}GPG secret key export requires your passphrase.${RESET}"
            echo    "  Enter it at the prompt below, or press Ctrl+C to skip."
            echo
            if gpg --batch --yes --pinentry-mode loopback                    --export-secret-keys --armor                    > "$DEST_ROOT/GPG/secret-keys.asc" 2>/dev/null; then
                if [[ -s "$DEST_ROOT/GPG/secret-keys.asc" ]]; then
                    ok "GPG secret keys exported"
                    warn "SECRET KEYS on disk — keep this backup secure!"
                    add_log "GPG secret keys exported"
                else
                    rm -f "$DEST_ROOT/GPG/secret-keys.asc"
                    warn "GPG secret key export produced no output (smartcard key?)"
                fi
            else
                rm -f "$DEST_ROOT/GPG/secret-keys.asc"
                warn "GPG secret key export failed or was skipped"
                add_log "GPG secret key export failed/skipped"
            fi
        fi
    else
        skip "gpg not found"
    fi
fi

# ─────────────────────────────────────────────
#  SECTION 6 — SYSTEM INFO & MISC
# ─────────────────────────────────────────────
header "Section 6/6 — System Info & Miscellaneous"
add_log "--- System Info ---"

# Cron jobs
if [[ "$SKIP_CRON_JOBS" == false ]]; then
    step "Exporting cron jobs..."
    mkdir -p "$DEST_ROOT/System"
    crontab -l 2>/dev/null > "$DEST_ROOT/System/crontab-$REAL_USER.txt" && \
        ok "User crontab saved" || skip "No user crontab found"
    if [[ -d /etc/cron.d ]]; then
        cp -r /etc/cron.d "$DEST_ROOT/System/cron.d" 2>/dev/null && \
            ok "/etc/cron.d copied" || true
    fi
    add_log "Cron jobs exported"
fi

# Environment variables
if [[ "$SKIP_ENV_VARS" == false ]]; then
    step "Exporting environment variables..."
    {
        echo "Environment Variables — $(hostname)"
        echo "Exported: $(date '+%Y-%m-%d %H:%M')"
        echo ""
        env | sort
    } > "$DEST_ROOT/System/environment-variables.txt"
    ok "Environment variables saved"
    add_log "Environment variables exported"
fi

# System info
step "Capturing system information..."
{
    echo "System Information — $(hostname)"
    echo "Exported: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "=== OS Release ==="
    cat /etc/os-release 2>/dev/null || true
    echo ""
    echo "=== Kernel ==="
    uname -a
    echo ""
    echo "=== CPU ==="
    lscpu 2>/dev/null | grep -E "^(Architecture|Model name|CPU\(s\)|Thread|Core|Socket|Vendor)" || \
        cat /proc/cpuinfo | grep "model name" | head -1
    echo ""
    echo "=== Memory ==="
    free -h
    echo ""
    echo "=== Disk Usage ==="
    df -h
    echo ""
    echo "=== Block Devices ==="
    lsblk 2>/dev/null || true
    echo ""
    echo "=== Network Interfaces ==="
    ip addr 2>/dev/null || ifconfig 2>/dev/null || true
    echo ""
    echo "=== GPU ==="
    lspci 2>/dev/null | grep -iE "vga|3d|display" || echo "(lspci not available)"
    echo ""
    echo "=== Uptime ==="
    uptime
} > "$DEST_ROOT/System/system-info.txt" 2>/dev/null
ok "System info saved"

# Wi-Fi / Network Manager connections
step "Exporting network connections..."
NM_DIR="/etc/NetworkManager/system-connections"
if [[ -d "$NM_DIR" ]]; then
    mkdir -p "$DEST_ROOT/System/NetworkConnections"
    cp "$NM_DIR/"* "$DEST_ROOT/System/NetworkConnections/" 2>/dev/null && \
        ok "NetworkManager connections copied (contains Wi-Fi passwords — handle with care)" || \
        warn "Could not copy NM connections (try running as root)"
    add_log "NetworkManager connections exported"
else
    skip "NetworkManager connections dir not found"
fi

# Hosts file
[[ -f /etc/hosts ]] && {
    cp /etc/hosts "$DEST_ROOT/System/hosts.txt" 2>/dev/null && ok "/etc/hosts saved" || true
}

# Fstab
[[ -f /etc/fstab ]] && {
    cp /etc/fstab "$DEST_ROOT/System/fstab.txt" 2>/dev/null && ok "/etc/fstab saved" || true
}

# Fonts
FONT_DIR="$REAL_HOME/.local/share/fonts"
if [[ -d "$FONT_DIR" ]]; then
    step "Copying user fonts..."
    do_rsync "$FONT_DIR" "$DEST_ROOT/Fonts"
    add_log "User fonts copied"
fi

# Keyrings / passwords (GNOME Keyring)
KEYRING_DIR="$REAL_HOME/.local/share/keyrings"
if [[ -d "$KEYRING_DIR" ]]; then
    step "Copying GNOME Keyring..."
    mkdir -p "$DEST_ROOT/System/keyrings"
    cp -r "$KEYRING_DIR/." "$DEST_ROOT/System/keyrings/" 2>/dev/null && \
        ok "GNOME Keyring copied (keep this secure!)" || \
        warn "Could not copy keyring (may be locked)"
    add_log "GNOME Keyring copied"
fi

# ─────────────────────────────────────────────
#  WRITE TRANSFER LOG
# ─────────────────────────────────────────────
add_log "--- Transfer complete ---"
{
    printf '%s\n' "${log_lines[@]}"
} > "$DEST_ROOT/TransferLog.txt"

# ─────────────────────────────────────────────
#  RESTORE HINTS FILE
# ─────────────────────────────────────────────
cat > "$DEST_ROOT/RESTORE-NOTES.txt" << 'EOF'
Linux PC Transfer — Restore Notes
==================================

1. PACKAGES
   APT (Debian/Ubuntu):
     sudo dpkg --set-selections < System/packages-apt-all.txt
     sudo apt-get -y dselect-upgrade
   Or reinstall explicitly installed only:
     xargs sudo apt install -y < System/packages-apt-manual.txt

   Flatpak:
     xargs flatpak install -y < System/packages-flatpak.txt

   Pacman (Arch):
     pacman -S --needed - < System/packages-pacman-explicit.txt

   pip:
     pip install -r System/packages-pip3.txt

2. SSH KEYS
   cp -r SSH/. ~/.ssh/
   chmod 700 ~/.ssh
   chmod 600 ~/.ssh/id_*
   chmod 644 ~/.ssh/*.pub

3. GPG KEYS
   gpg --import GPG/public-keys.asc
   gpg --import GPG/secret-keys.asc
   gpg --import-ownertrust GPG/ownertrust.txt

4. BROWSER PROFILES
   Close browser first, then copy profile folder back to its original location:
     Chrome:    ~/.config/google-chrome
     Firefox:   ~/.mozilla/firefox
     Brave:     ~/.config/BraveSoftware/Brave-Browser

5. SHELL CONFIG
   cp Config/shell/.bashrc ~/.bashrc
   cp Config/shell/.zshrc ~/.zshrc   (etc.)
   source ~/.bashrc

6. NETWORK (Wi-Fi)
   sudo cp System/NetworkConnections/* /etc/NetworkManager/system-connections/
   sudo chmod 600 /etc/NetworkManager/system-connections/*
   sudo systemctl restart NetworkManager

7. GNOME KEYRING
   Close session, then copy:
   cp -r System/keyrings/. ~/.local/share/keyrings/

8. FONTS
   cp -r Fonts/. ~/.local/share/fonts/
   fc-cache -fv

9. CRON JOBS
   crontab System/crontab-<username>.txt

10. FSTAB (mount points)
    Review System/fstab.txt — UUIDs will differ on new drives.
    Use `blkid` to find new UUIDs and update /etc/fstab accordingly.
EOF
ok "RESTORE-NOTES.txt written"

# ─────────────────────────────────────────────
#  SUMMARY
# ─────────────────────────────────────────────
header "Transfer Complete"

total_size=$(dir_size_bytes "$DEST_ROOT")
echo
echo -e "  ${GREEN}Destination : $DEST_ROOT${RESET}"
echo -e "  ${GREEN}Total size  : $(format_bytes "$total_size")${RESET}"
echo
echo    "  What was saved:"
echo    "    UserFiles/              — Desktop, Documents, Downloads, etc."
echo    "    Config/                 — .config, dotfiles, shell configs"
echo    "    Browsers/               — Chrome, Firefox, Brave, etc."
echo    "    SSH/                    — SSH keys and config"
echo    "    GPG/                    — GPG public & secret keys"
echo    "    Fonts/                  — User-installed fonts"
echo    "    System/                 — Package lists, Wi-Fi, sysinfo, crontab"
echo    "    TransferLog.txt         — Full log of this session"
echo    "    RESTORE-NOTES.txt       — Step-by-step restore instructions"
echo
echo -e "  ${YELLOW}REMINDERS:${RESET}"
echo -e "  ${YELLOW}  - GPG secret keys and Wi-Fi profiles contain sensitive data${RESET}"
echo -e "  ${YELLOW}  - fstab UUIDs will need updating for new hardware${RESET}"
echo -e "  ${YELLOW}  - Re-install packages from the lists in System/${RESET}"
echo -e "  ${YELLOW}  - See RESTORE-NOTES.txt for full restore steps${RESET}"
echo
echo -e "  ${CYAN}Done!${RESET}"
echo
