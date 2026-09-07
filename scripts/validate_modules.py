#!/usr/bin/env python3
"""Offline checks for the migration catalog; no third-party dependencies."""

import json
from pathlib import Path
import re
import shlex
import sys


def validate(root):
    modules = {}
    required = {
        "schema_version",
        "id",
        "label",
        "description",
        "category",
        "profiles",
        "hidden",
        "platform",
        "depends_on",
        "detect",
        "backend",
        "spec",
        "lifecycle",
        "legacy_source",
    }
    backend_fields = {
        "apt": "packages",
        "deb": "url",
        "vendor": "installer_url",
        "symlink": "target_command",
        "adapter": "adapter",
    }

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    for path in sorted((root / "modules").glob("*.json")):
        data = json.loads(path.read_text())
        name = path.stem
        require(set(data) == required, f"{name}: incorrect top-level fields")
        require(
            data["id"] == name and re.fullmatch(r"[a-z0-9][a-z0-9-]*", name),
            f"{name}: invalid ID",
        )
        require(data["schema_version"] == 1, f"{name}: unknown schema version")
        for field in ("profiles", "depends_on"):
            require(
                isinstance(data[field], list)
                and all(isinstance(item, str) for item in data[field]),
                f"{name}: {field} must be a string list",
            )
        platform = data["platform"]
        require(
            platform["os"] == "ubuntu" and platform["min_version"] == "24.04",
            f"{name}: incorrect Ubuntu target",
        )
        require(
            bool(platform["architectures"])
            and set(platform["architectures"]) <= {"amd64", "arm64"},
            f"{name}: invalid architectures",
        )
        backend = data["backend"]
        require(backend in backend_fields, f"{name}: unknown backend")
        require(
            bool(data["spec"].get(backend_fields[backend])),
            f"{name}: missing backend data",
        )
        lifecycle = data["lifecycle"]
        require(
            lifecycle["install"] == "ensure-present"
            and lifecycle["update"] == "existing-only"
            and lifecycle["preserve_user_data"] is True
            and lifecycle["remove"]
            in {
                "recorded-packages",
                "recorded-files",
                "recorded-backend",
                "managed-block-and-file",
            },
            f"{name}: invalid lifecycle policy",
        )
        require(
            (root / data["legacy_source"]).is_file(), f"{name}: missing legacy source"
        )
        modules[name] = data

    legacy = {}
    for path in sorted((root / "components").glob("*.sh")):
        for line in path.read_text().splitlines():
            if line.startswith("register_component "):
                tokens = shlex.split(line)
                legacy[tokens[1]] = dict(token.split("=", 1) for token in tokens[2:])
    require(
        bool(modules) and set(modules) == set(legacy),
        f"catalog mismatch: missing={set(legacy) - set(modules)}, "
        f"extra={set(modules) - set(legacy)}",
    )
    for name, data in modules.items():
        old = legacy[name]
        for field, old_field in [("profiles", "profiles"), ("depends_on", "deps")]:
            require(
                data[field] == old.get(old_field, "").split(),
                f"{name}: {field} differs from legacy registry",
            )
        if old["type"] == "apt":
            require(
                data["backend"] == "apt"
                and data["spec"]["packages"] == old["packages"].split(),
                f"{name}: APT packages differ from legacy registry",
            )

    visited = set()

    def visit(name, visiting):
        require(name in modules, f"unknown dependency: {name}")
        require(name not in visiting, f"dependency cycle at {name}")
        if name in visited:
            return
        for dependency in modules[name]["depends_on"]:
            visit(dependency, visiting | {name})
        visited.add(name)

    for name in modules:
        visit(name, set())
    print(
        f"Validated {len(modules)} modules; complete legacy coverage; no dependency cycles."
    )


if __name__ == "__main__":
    try:
        validate(Path(__file__).resolve().parent.parent)
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Module validation failed: {error}", file=sys.stderr)
        sys.exit(1)
