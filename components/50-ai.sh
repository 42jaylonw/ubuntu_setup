#!/usr/bin/env bash

# OpenAI documents the same standalone installer for installation and updates:
# https://learn.chatgpt.com/docs/codex/cli
register_component codex label='OpenAI Codex CLI' category=ai description='OpenAI coding agent CLI (latest stable)' profiles=workstation probes=codex type=remote deps=bootstrap installer=https://chatgpt.com/codex/install.sh
register_component pixi label='Pixi' category=ai description='Reproducible Python/Conda environments' profiles=workstation probes=pixi type=remote deps=bootstrap installer=https://pixi.sh/install.sh
register_component uv label='uv' category=ai description='Fast Python package and tool manager' profiles=workstation probes=uv type=remote deps=bootstrap installer=https://astral.sh/uv/install.sh
