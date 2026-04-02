#!/usr/bin/env bash
# =============================================================================
#  lib/desktop.sh — Desktop environment helpers + dotfiles deploy
#
#  The DE package installation happens inside the chroot (chroot_base.sh).
#  This file owns the host-side post-install dotfiles deployment step,
#  which runs AFTER the chroot is done and /mnt is still mounted.
#
#  Functions:
#    deploy_dotfiles()    — Step 12 UI: ask for dotfiles source, deploy
#    _dl_from_git()       — clone a bare git repo and checkout to /mnt/home
#    _dl_from_local()     — rsync from a local path (USB drive etc.)
#    _dl_apply_chezmoi()  — run chezmoi apply inside chroot
# =============================================================================

# =============================================================================
#  Pure helpers
# =============================================================================

# _dl_from_git REPO_URL HOME_DIR USERNAME
function _dl_from_git() {
    # inputs: repo_url home_dir username / side-effects: files in home_dir
    local repo="$1" home_dir="$2" user="$3"
    local bare_dir="/tmp/dotfiles_bare_$$"

    run "git clone --bare ${repo} ${bare_dir}"

    # Checkout into home — ignore errors for files that already exist
    GIT_DIR="$bare_dir" GIT_WORK_TREE="$home_dir" \
        git checkout 2>&1 | grep -v "^error: Your local" || true

    run "chown -R ${user}:${user} ${home_dir}"
    rm -rf "$bare_dir"
    ok "Dotfiles checked out into ${home_dir}"
}

# _dl_from_local SRC_PATH HOME_DIR USERNAME
function _dl_from_local() {
    # inputs: src_path home_dir username / side-effects: files in home_dir
    local src="$1" home_dir="$2" user="$3"
    run "rsync -av --no-owner --no-group ${src}/ ${home_dir}/"
    run "chown -R ${user}:${user} ${home_dir}"
    ok "Dotfiles synced from ${src} into ${home_dir}"
}

# _dl_apply_chezmoi REPO_URL USERNAME — runs chezmoi inside arch-chroot
function _dl_apply_chezmoi() {
    # inputs: repo_url username / side-effects: dotfiles applied inside chroot
    local repo="$1" user="$2"
    run "arch-chroot /mnt sudo -u ${user} bash -c \
        'sh -c \"\$(curl -fsLS get.chezmoi.io)\" -- init --apply ${repo}'"
    ok "chezmoi: dotfiles applied for ${user}"
}

# =============================================================================
#  deploy_dotfiles — called after run_chroot, /mnt still mounted
# =============================================================================
function deploy_dotfiles() {
    # inputs: USERNAME / side-effects: optional dotfiles in /mnt/home/USERNAME
    section "Dotfiles (optional)"

    local home_dir="/mnt/home/${USERNAME}"

    if [[ "${NO_GUM:-false}" == false ]]; then
        gum style \
            --border        rounded \
            --border-foreground "$GUM_C_DIM" \
            --padding       "0 2" \
            --width         "$GUM_WIDTH" \
            "$(_clr "$GUM_C_INFO"  "  Deploy your personal configuration files now,")" \
            "$(_clr "$GUM_C_INFO"  "  while /mnt is still mounted.")" \
            "$(_clr "$GUM_C_DIM"   "  Skip this step and configure manually after reboot.")" \
            2>/dev/null || true
    else
        info "Deploy dotfiles into ${home_dir} now, or skip and do it manually."
    fi
    blank

    if ! confirm_gum "Deploy dotfiles?"; then
        info "Skipped — configure manually after reboot."
        return 0
    fi

    blank
    local method_sel
    method_sel=$(choose_one \
        "Git bare repo  — e.g. github.com/user/dotfiles" \
        "Git bare repo  — e.g. github.com/user/dotfiles" \
        "chezmoi        — template-based dotfile manager" \
        "Local path     — USB drive, NFS share, etc." \
        "Skip           — do it manually after reboot" \
        "$BACK")

    if [[ "$method_sel" == "$BACK" || "$method_sel" == "Skip"* ]]; then
        info "Dotfiles skipped."
        return 0
    fi

    case "${method_sel%% *}" in

        "Git bare repo"|Git)
            local repo_url
            repo_url=$(input_gum \
                "Git repository URL  (e.g. https://github.com/user/dotfiles.git)" \
                "")
            if [[ -z "$repo_url" || "$repo_url" == "$BACK" ]]; then
                info "Dotfiles skipped."
                return 0
            fi
            _dl_from_git "$repo_url" "$home_dir" "$USERNAME"
            ;;

        chezmoi)
            local chezmoi_repo
            chezmoi_repo=$(input_gum \
                "chezmoi source URL  (e.g. github.com/user/dotfiles)" \
                "")
            if [[ -z "$chezmoi_repo" || "$chezmoi_repo" == "$BACK" ]]; then
                info "Dotfiles skipped."
                return 0
            fi
            # chezmoi needs to be installed inside the chroot first
            if ! arch-chroot /mnt command -v chezmoi &>/dev/null; then
                run_spin "Installing chezmoi inside chroot…" \
                    "arch-chroot /mnt pacman -S --noconfirm --needed chezmoi"
            fi
            _dl_apply_chezmoi "$chezmoi_repo" "$USERNAME"
            ;;

        "Local path"|Local)
            info "Attach your USB drive or NFS share, then:"
            local src_path
            src_path=$(input_gum \
                "Source path  (e.g. /run/media/user/USB/dotfiles)" \
                "")
            if [[ -z "$src_path" || "$src_path" == "$BACK" ]]; then
                info "Dotfiles skipped."
                return 0
            fi
            if [[ ! -d "$src_path" ]]; then
                warn "Path not found: ${src_path}"
                info "Dotfiles skipped — sync manually after reboot."
                return 0
            fi
            _dl_from_local "$src_path" "$home_dir" "$USERNAME"
            ;;

        *)
            info "Dotfiles skipped."
            return 0 ;;
    esac

    # Verify the user's shell history/config wasn't clobbered
    if [[ -f "${home_dir}/.bashrc" || -f "${home_dir}/.zshrc" || \
          -d "${home_dir}/.config" ]]; then
        ok "Dotfiles present in ${home_dir}"
    fi

    blank
    return 0
}
