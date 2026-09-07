#!/usr/bin/env bash

install_base() {
  run sudo apt-get update
  apt_install \
    ca-certificates curl wget gnupg software-properties-common \
    git git-lfs openssh-client unzip zip xz-utils zsh

  if ! ((DRY_RUN)); then
    git lfs install
  fi

  if [[ "${SHELL:-}" != */zsh ]] && has_command zsh; then
    if ((DRY_RUN)); then
      log "Would change the login shell to zsh"
    else
      chsh -s "$(command -v zsh)" || warn "could not change login shell; run: chsh -s $(command -v zsh)"
    fi
  fi
}

