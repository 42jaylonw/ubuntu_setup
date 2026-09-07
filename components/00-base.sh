#!/usr/bin/env bash

register_component bootstrap label='Bootstrap prerequisites' category=base description='Download and package-management prerequisites' profiles='' probes='curl wget' packages='ca-certificates curl wget gnupg software-properties-common unzip zip xz-utils' type=apt privilege=yes hidden=yes
register_component git label='Git' category=base description='Distributed version control' profiles='minimal workstation' probes='git' packages='git' type=apt deps=bootstrap privilege=yes
register_component git-lfs label='Git LFS' category=base description='Large file support for Git' profiles='minimal workstation' probes='git-lfs' packages='git-lfs' type=apt deps=git privilege=yes
register_component openssh label='OpenSSH client' category=base description='Secure remote access client' profiles='minimal workstation' probes='ssh' packages='openssh-client' type=apt deps=bootstrap privilege=yes

