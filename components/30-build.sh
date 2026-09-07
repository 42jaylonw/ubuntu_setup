#!/usr/bin/env bash

register_component build-essential label='Build essentials' category=build description='Compiler, linker, make, and headers' profiles=workstation probes='gcc make' packages='build-essential pkg-config' type=apt deps=bootstrap privilege=yes
register_component cmake label='CMake' category=build description='Cross-platform build generator' profiles=workstation probes=cmake packages=cmake type=apt deps=bootstrap privilege=yes
register_component ninja label='Ninja' category=build description='Fast build executor' profiles=workstation probes=ninja packages=ninja-build type=apt deps=bootstrap privilege=yes
register_component clang label='Clang toolchain' category=build description='Clang compiler, formatter, and language server' profiles=workstation probes='clang clangd clang-format' packages='clang clangd clang-format' type=apt deps=bootstrap privilege=yes
register_component gdb label='GDB' category=build description='Native debugger' profiles=workstation probes=gdb packages=gdb type=apt deps=bootstrap privilege=yes
register_component ccache label='ccache' category=build description='Compiler output cache' profiles=workstation probes=ccache packages=ccache type=apt deps=bootstrap privilege=yes

