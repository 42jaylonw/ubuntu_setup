#!/usr/bin/env bash

install_ai() {
  has_command pixi || run_remote_installer pixi https://pixi.sh/install.sh sh
  has_command uv || run_remote_installer uv https://astral.sh/uv/install.sh sh
  append_zsh_block

  log "AI environment tools installed. Add model frameworks per project with Pixi or uv."
}

