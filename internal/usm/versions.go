package usm

import (
	"fmt"
	"maps"
	"os"
	"slices"
)

type LockEntry struct {
	ID           string            `json:"id"`
	Digest       string            `json:"manifest_digest"`
	Backend      string            `json:"backend"`
	Channel      string            `json:"channel,omitempty"`
	Packages     Inventory         `json:"packages"`
	Pin          Inventory         `json:"pin,omitempty"`
	Checksums    map[string]string `json:"checksums,omitempty"`
	Reproducible bool              `json:"reproducible"`
	Reason       string            `json:"reason,omitempty"`
}
type Lockfile struct {
	Schema  int         `json:"schema_version"`
	Target  Target      `json:"target"`
	Modules []LockEntry `json:"modules"`
}

func (m *Manager) Export(ids []string) (Lockfile, error) {
	lock := Lockfile{Schema: 1, Target: m.Target, Modules: []LockEntry{}}
	ids = slices.Clone(ids)
	slices.Sort(ids)
	for _, id := range ids {
		s, err := m.Inspect(id)
		if err != nil {
			return lock, err
		}
		if s.Receipt == nil {
			continue
		}
		if s.Action == "conflict" || s.Action == "unsupported" || len(s.Managed) == 0 || s.Receipt.Outcome != "success" {
			return lock, fmt.Errorf("%s: installation is not verified; repair before exporting", id)
		}
		if s.Drift {
			return lock, fmt.Errorf("%s: pin drift; restore the pinned version or unpin before exporting", id)
		}
		mod := m.Catalog[id]
		pkgs, _ := mod.Packages()
		entry := LockEntry{ID: id, Digest: mod.Digest, Backend: mod.Backend, Packages: s.Installed, Pin: s.Pinned, Reproducible: s.Capabilities.Exact && len(s.Installed) == len(pkgs)}
		if !entry.Reproducible {
			entry.Reason = "incomplete installation or backend cannot install exact versions"
		}
		lock.Modules = append(lock.Modules, entry)
	}
	return lock, nil
}
func (m *Manager) ReadLock(path string) (Lockfile, error) {
	var lock Lockfile
	data, err := os.ReadFile(path)
	if err != nil {
		return lock, err
	}
	if err = decode(data, &lock); err != nil {
		return lock, err
	}
	if lock.Schema != 1 || lock.Target != m.Target {
		return lock, fmt.Errorf("lock schema or Ubuntu release/architecture is incompatible with this host")
	}
	seen := map[string]bool{}
	for _, e := range lock.Modules {
		mod, ok := m.Catalog[e.ID]
		if !ok || seen[e.ID] {
			return lock, fmt.Errorf("unknown/duplicate locked module %q", e.ID)
		}
		seen[e.ID] = true
		if mod.Digest != e.Digest || mod.Backend != e.Backend || e.Channel != "" {
			return lock, fmt.Errorf("%s: manifest or provider changed; restore the locked manifest", e.ID)
		}
		b, ok := m.Backends[e.Backend]
		if !ok || !b.Capabilities().Exact || !e.Reproducible {
			return lock, fmt.Errorf("%s: exact reproduction is unsupported", e.ID)
		}
		pkgs, err := mod.Packages()
		if err != nil {
			return lock, err
		}
		if len(pkgs) != len(e.Packages) {
			return lock, fmt.Errorf("%s: lock must include every module package", e.ID)
		}
		for p, v := range e.Packages {
			if !slices.Contains(pkgs, p) || v == "" {
				return lock, fmt.Errorf("%s: invalid locked package/version", e.ID)
			}
			if pin := e.Pin[p]; pin != "" && pin != v {
				return lock, fmt.Errorf("%s: locked version conflicts with pin", e.ID)
			}
		}
		for p := range e.Pin {
			if e.Packages[p] == "" {
				return lock, fmt.Errorf("%s: pin is outside locked packages", e.ID)
			}
		}
		if len(e.Checksums) > 0 {
			return lock, fmt.Errorf("%s: APT artifact checksums in lock are unsupported", e.ID)
		}
	}
	return lock, nil
}
func (m *Manager) Pin(ids []string, unpin, dry bool) ([]Step, error) {
	steps := []Step{}
	for _, id := range ids {
		s, err := m.Inspect(id)
		if err != nil {
			return nil, err
		}
		pkgs, _ := m.Catalog[id].Packages()
		if s.Receipt == nil || s.Action == "conflict" || s.Action == "unsupported" || len(s.Managed) == 0 || (!unpin && (len(s.Installed) != len(pkgs) || s.Receipt.Outcome != "success")) {
			return nil, fmt.Errorf("%s: pin requires a verified managed installation", id)
		}
		s.Action = "pin"
		s.Pinned = maps.Clone(s.Installed)
		if unpin {
			s.Action = "unpin"
			s.Pinned = nil
		}
		steps = append(steps, s)
	}
	if !dry {
		for _, s := range steps {
			s.Receipt.Pin = s.Pinned
			if err := m.Store.Write(s.Receipt); err != nil {
				return steps, err
			}
			if err := m.Store.Log(s.ID, s.Action, "success"); err != nil {
				return steps, err
			}
		}
	}
	return steps, nil
}
