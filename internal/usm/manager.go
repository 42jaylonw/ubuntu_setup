package usm

import (
	"fmt"
	"maps"
	"os/exec"
	"slices"
	"sort"
	"strings"
)

type Options struct {
	Command        string
	IDs            []string
	Profile        string
	Category       string
	All            bool
	DryRun         bool
	Yes            bool
	JSON           bool
	Version        string
	AllowDowngrade bool
	Lock           string
	Output         string
	Modules        string
}
type Step struct {
	ID           string       `json:"id"`
	Backend      string       `json:"backend"`
	Action       string       `json:"action"`
	Reason       string       `json:"reason,omitempty"`
	Installed    Inventory    `json:"installed"`
	Managed      Inventory    `json:"managed,omitempty"`
	Pinned       Inventory    `json:"pinned,omitempty"`
	Drift        bool         `json:"drift,omitempty"`
	Capabilities Capabilities `json:"capabilities"`
	Versions     Inventory    `json:"requested_versions,omitempty"`
	Argv         []string     `json:"argv,omitempty"`
	DesiredPin   Inventory    `json:"-"`
	Receipt      *Receipt     `json:"-"`
	Packages     []string     `json:"-"`
}
type Manager struct {
	Catalog  Catalog
	Target   Target
	Store    Store
	Backends map[string]Backend
	LookPath func(string) (string, error)
}

func (m *Manager) Select(o Options) ([]string, error) {
	selected := map[string]bool{}
	for _, id := range o.IDs {
		if _, ok := m.Catalog[id]; !ok {
			return nil, fmt.Errorf("unknown module %q", id)
		}
		selected[id] = true
	}
	if (o.Command == "update" || o.Command == "remove") && len(o.IDs) == 0 && !o.All {
		return nil, fmt.Errorf("%s requires module IDs or --all (managed modules)", o.Command)
	}
	if o.All && len(o.IDs) > 0 {
		return nil, fmt.Errorf("--all cannot be combined with module IDs")
	}
	knownProfile, knownCategory := o.Profile == "", o.Category == ""
	categories := strings.Split(o.Category, ",")
	for _, id := range m.Catalog.IDs() {
		mod := m.Catalog[id]
		profile := slices.Contains(mod.Profiles, o.Profile)
		category := slices.Contains(categories, mod.Category)
		knownProfile = knownProfile || profile
		knownCategory = knownCategory || category
		if o.All {
			r, err := m.Store.Read(id)
			if err != nil {
				return nil, err
			}
			if r != nil {
				selected[id] = true
			}
		}
		if len(o.IDs) == 0 && !o.All && (o.Command == "list" || o.Command == "status" || profile || category) {
			if !mod.Hidden {
				selected[id] = true
			}
		}
	}
	if !knownProfile {
		return nil, fmt.Errorf("unknown profile %q", o.Profile)
	}
	if !knownCategory {
		return nil, fmt.Errorf("unknown category %q", o.Category)
	}
	for _, cat := range categories {
		if cat == "" {
			continue
		}
		found := false
		for _, mod := range m.Catalog {
			found = found || mod.Category == cat
		}
		if !found {
			return nil, fmt.Errorf("unknown category %q", cat)
		}
	}
	ids := []string{}
	for _, id := range m.Catalog.IDs() {
		mod := m.Catalog[id]
		if selected[id] && (o.Profile == "" || slices.Contains(mod.Profiles, o.Profile)) && (o.Category == "" || slices.Contains(categories, mod.Category)) {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 && o.Command == "install" {
		return nil, fmt.Errorf("install requires module IDs, --profile, or --category")
	}
	if o.Version != "" && (len(ids) != 1 || (o.Command != "install" && o.Command != "update")) {
		return nil, fmt.Errorf("--version requires one install/update module")
	}
	return ids, nil
}
func (m *Manager) Inspect(id string) (Step, error) {
	mod := m.Catalog[id]
	s := Step{ID: id, Backend: mod.Backend, Action: "missing", Installed: Inventory{}}
	r, err := m.Store.Read(id)
	if err != nil {
		return s, fmt.Errorf("%s: %w", id, err)
	}
	s.Receipt = r
	if !mod.Supports(m.Target) {
		s.Action = "unsupported"
		s.Reason = "requires Ubuntu " + mod.Platform.Version + "+ on " + strings.Join(mod.Platform.Architectures, ",")
		return s, nil
	}
	b, ok := m.Backends[mod.Backend]
	if !ok {
		s.Action = "unsupported"
		s.Reason = "adapter lifecycle is not implemented; use the existing setup runner for installation"
		return s, nil
	}
	s.Capabilities = b.Capabilities()
	s.Installed, err = b.Inspect(mod)
	if err != nil {
		return s, fmt.Errorf("%s: %w", id, err)
	}
	pkgs, err := mod.Packages()
	if err != nil {
		return s, err
	}
	if len(s.Installed) == len(pkgs) {
		s.Action = "external"
	} else if len(s.Installed) > 0 {
		s.Action = "partial"
	}
	if r != nil {
		if r.Digest != mod.Digest || r.Backend != mod.Backend {
			s.Action = "conflict"
			s.Reason = "receipt manifest/backend differs; restore the original manifest before mutation"
			return s, nil
		}
		s.Managed = Inventory{}
		s.Pinned = r.Pin
		for p := range r.Packages {
			if !slices.Contains(pkgs, p) {
				return s, fmt.Errorf("%s: receipt owns package outside manifest: %s", id, p)
			}
			if v := s.Installed[p]; v != "" {
				s.Managed[p] = v
			}
		}
		if len(s.Managed) > 0 {
			s.Action = "managed"
		} else {
			s.Reason = "stale receipt: no recorded packages remain"
		}
		if r.Outcome == "pending" || r.Outcome == "failed" {
			s.Reason = "recoverable " + r.Outcome + " operation; inventory reconciled"
		}
		for p, v := range r.Pin {
			if s.Installed[p] != v {
				s.Drift = true
			}
		}
	}
	if len(s.Installed) == 0 && r == nil {
		look := m.LookPath
		if look == nil {
			look = exec.LookPath
		}
		for _, cmd := range mod.Detect.Commands {
			if _, err := look(cmd); err == nil {
				s.Action = "external"
				s.Reason = "command exists outside the selected package inventory; provider is unknown"
				break
			}
		}
	}
	return s, nil
}
func (m *Manager) pins() (Inventory, error) {
	pins := Inventory{}
	for _, id := range m.Catalog.IDs() {
		r, err := m.Store.Read(id)
		if err != nil {
			return nil, err
		}
		if r != nil {
			for p, v := range r.Pin {
				if old := pins[p]; old != "" && old != v {
					return nil, fmt.Errorf("conflicting receipts pin %s to different versions", p)
				}
				pins[p] = v
			}
		}
	}
	return pins, nil
}
func (m *Manager) Plan(o Options, ids []string, exact map[string]Inventory) ([]Step, error) {
	pins, err := m.pins()
	if err != nil {
		return nil, err
	}
	ordered, err := m.Catalog.Order(ids, o.Command == "install" || o.Command == "sync")
	if err != nil {
		return nil, err
	}
	if o.Command == "remove" {
		slices.Reverse(ordered)
	}
	steps := make([]Step, 0, len(ordered))
	for _, id := range ordered {
		mod := m.Catalog[id]
		s, err := m.Inspect(id)
		if err != nil {
			return nil, err
		}
		if s.Action == "unsupported" || s.Action == "conflict" {
			if o.Version != "" || len(exact[id]) > 0 {
				return nil, fmt.Errorf("%s: exact installation unavailable: %s", id, s.Reason)
			}
			s.Action = "blocked"
			steps = append(steps, s)
			continue
		}
		pkgs, _ := mod.Packages()
		s.Versions = maps.Clone(exact[id])
		if s.Versions == nil {
			s.Versions = Inventory{}
		}
		if o.Version != "" && slices.Contains(ids, id) {
			if len(pkgs) != 1 {
				return nil, fmt.Errorf("%s: --version requires a single-package module; use a lock for package sets", id)
			}
			s.Versions[pkgs[0]] = o.Version
		}
		if s.Receipt != nil {
			for p, v := range s.Receipt.Pin {
				if want := s.Versions[p]; want != "" && want != v {
					return nil, fmt.Errorf("%s is pinned to %s; unpin first", id, v)
				}
				if o.Command == "install" || o.Command == "sync" {
					s.Versions[p] = v
				}
			}
		}
		switch o.Command {
		case "install", "sync":
			if len(s.Installed) == len(pkgs) && len(s.Versions) == 0 {
				s.Action = "skip"
				s.Reason = "already satisfied"
			} else if s.Action == "external" && len(s.Installed) == 0 {
				s.Action = "skip"
			} else {
				for _, p := range pkgs {
					v := s.Installed[p]
					want := s.Versions[p]
					if v == "" {
						s.Packages = append(s.Packages, p)
					} else if want != "" && want != v {
						if s.Managed[p] == "" {
							return nil, fmt.Errorf("%s: refusing to change external package %s", id, p)
						}
						s.Packages = append(s.Packages, p)
					}
				}
				if len(s.Packages) == 0 {
					s.Action = "skip"
					s.Reason = "already satisfied"
				} else {
					s.Action = "install"
				}
			}
		case "update":
			if len(s.Pinned) > 0 && len(s.Versions) == 0 {
				s.Action = "skip"
				s.Reason = "pinned; unpin to update"
			} else if len(s.Managed) == 0 {
				s.Action = "skip"
				s.Reason = "missing or externally installed; ownership is required for updates"
			} else {
				s.Action = "update"
				for _, p := range pkgs {
					if s.Managed[p] != "" {
						s.Packages = append(s.Packages, p)
					}
				}
			}
		case "remove":
			if len(s.Managed) == 0 {
				s.Action = "skip"
				s.Reason = "absent or externally installed"
			} else {
				s.Action = "remove"
				for p := range s.Managed {
					s.Packages = append(s.Packages, p)
				}
				sort.Strings(s.Packages)
			}
		default:
			return nil, fmt.Errorf("unknown plan operation %s", o.Command)
		}
		if s.Action == "skip" && len(s.Versions) > 0 {
			for p, v := range s.Versions {
				if s.Installed[p] != v {
					return nil, fmt.Errorf("%s: cannot satisfy exact version %s=%s without adopting external software", id, p, v)
				}
			}
		}
		for p, want := range s.Versions {
			if !slices.Contains(pkgs, p) || want == "" || strings.ContainsAny(want, "\r\n\x00") {
				return nil, fmt.Errorf("%s: invalid exact package/version", id)
			}
			available, err := m.Backends[s.Backend].Versions(p)
			if err != nil {
				return nil, err
			}
			if !slices.Contains(available, want) {
				return nil, fmt.Errorf("%s=%s unavailable in local APT metadata", p, want)
			}
			if have := s.Installed[p]; have != "" && want != have {
				cmp, err := m.Backends[s.Backend].Compare(want, have)
				if err != nil {
					return nil, err
				}
				if cmp < 0 && !o.AllowDowngrade {
					return nil, fmt.Errorf("%s: %s → %s requires --allow-downgrade", id, have, want)
				}
			}
		}
		if o.Command == "sync" && len(s.Packages) > 0 && len(exact[id]) == 0 {
			return nil, fmt.Errorf("%s: missing prerequisite is not locked; install it explicitly or export a complete lock", id)
		}
		for _, prior := range steps {
			if prior.Action == "blocked" && slices.Contains(mod.Depends, prior.ID) && o.Command != "remove" {
				s.Action = "blocked"
				s.Reason = "dependency " + prior.ID + " is blocked"
				s.Packages = nil
			}
		}
		if len(s.Packages) > 0 {
			args, err := m.Backends[s.Backend].Prepare(s.Action, s.Packages, s.Versions, o.AllowDowngrade, pins)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", id, err)
			}
			s.Argv = append([]string{"apt-get"}, args...)
		}
		steps = append(steps, s)
	}
	if o.Command == "remove" {
		// Include transitive module dependencies, even when the intermediate module is external.
		for _, id := range m.Catalog.IDs() {
			if slices.Contains(ids, id) {
				continue
			}
			s, err := m.Inspect(id)
			if err != nil {
				return nil, err
			}
			if s.Receipt == nil || (len(s.Managed) == 0 && s.Action != "conflict" && s.Action != "unsupported") {
				continue
			}
			deps, err := m.Catalog.Order([]string{id}, true)
			if err != nil {
				return nil, err
			}
			for _, step := range steps {
				if step.Action == "remove" {
					needed, _ := m.Catalog[id].Packages()
					for _, p := range step.Packages {
						if slices.Contains(needed, p) {
							return nil, fmt.Errorf("cannot remove %s: retained managed module %s needs package %s", step.ID, id, p)
						}
					}
				}
				if step.Action == "remove" && slices.Contains(deps, step.ID) {
					return nil, fmt.Errorf("cannot remove %s: retained managed module %s depends on it", step.ID, id)
				}
			}
		}
	}
	return steps, nil
}
func (m *Manager) Apply(o Options, steps []Step) ([]Step, error) {
	pins, err := m.pins()
	if err != nil {
		return steps, err
	}
	failed := map[string]bool{}
	anyFailure := false
	for i := range steps {
		s := &steps[i]
		mod := m.Catalog[s.ID]
		for _, dep := range mod.Depends {
			if o.Command != "remove" && failed[dep] {
				s.Action = "blocked"
				s.Reason = "dependency " + dep + " failed"
			}
		}
		if o.Command == "remove" {
			for id := range failed {
				deps, _ := m.Catalog.Order([]string{id}, true)
				if slices.Contains(deps, s.ID) {
					s.Action = "blocked"
					s.Reason = "dependent " + id + " failed"
				}
			}
		}
		if s.Action == "blocked" {
			failed[s.ID] = true
			anyFailure = true
			continue
		}
		if s.Action == "skip" {
			if s.Receipt != nil {
				r := s.Receipt
				if len(s.Managed) == 0 && len(s.Pinned) == 0 {
					if err := m.Store.Delete(s.ID); err != nil {
						return steps, err
					}
				} else if len(s.Managed) > 0 {
					r.Packages = maps.Clone(s.Managed)
					packages, _ := mod.Packages()
					if len(s.Installed) == len(packages) {
						if s.DesiredPin != nil {
							r.Pin = maps.Clone(s.DesiredPin)
							s.Pinned = r.Pin
						}
						r.Outcome = "success"
						r.Error = ""
						r.Before = nil
					}
					if err := m.Store.Write(r); err != nil {
						return steps, err
					}
				}
			}
			continue
		}
		// Reinspect immediately before each mutation; an external package tool may have run since planning.
		current, err := m.Backends[s.Backend].Inspect(mod)
		if err != nil {
			return steps, err
		}
		if !maps.Equal(current, s.Installed) {
			s.Action = "failed"
			s.Reason = "package inventory changed after planning; rerun"
			failed[s.ID] = true
			anyFailure = true
			continue
		}
		r := s.Receipt
		if r == nil {
			r = &Receipt{Schema: 1, ID: s.ID, Digest: mod.Digest, Backend: s.Backend, Scope: "system", Packages: Inventory{}}
		}
		r.Packages = maps.Clone(s.Managed)
		if r.Packages == nil {
			r.Packages = Inventory{}
		}
		// Persist intended ownership before execution so interrupted installs can recover.
		for _, p := range s.Packages {
			if current[p] == "" {
				r.Packages[p] = ""
			}
		}
		r.Before = maps.Clone(current)
		r.Outcome = "pending"
		r.Error = ""
		if err = m.Store.Write(r); err != nil {
			return steps, err
		}
		action := s.Action
		if err = m.Store.Log(s.ID, action, "pending"); err != nil {
			return steps, err
		}
		// Repeat the backend safety check after preceding modules changed APT's graph.
		args, err := m.Backends[s.Backend].Prepare(action, s.Packages, s.Versions, o.AllowDowngrade, pins)
		if err == nil {
			err = m.Backends[s.Backend].Apply(args)
		}
		after, inspectErr := m.Backends[s.Backend].Inspect(mod)
		if inspectErr != nil {
			err = fmt.Errorf("verification failed: %w (apply: %v)", inspectErr, err)
		} else {
			for p := range r.Packages {
				if v := after[p]; v != "" {
					r.Packages[p] = v
				} else if err == nil {
					delete(r.Packages, p)
				}
			}
			for _, p := range s.Packages {
				if action == "remove" && after[p] != "" {
					err = fmt.Errorf("%s remains installed", p)
				}
				if action != "remove" && (after[p] == "" || (s.Versions[p] != "" && s.Versions[p] != after[p])) {
					err = fmt.Errorf("%s did not reach requested state", p)
				}
			}
			if err == nil && s.DesiredPin != nil {
				r.Pin = maps.Clone(s.DesiredPin)
				s.Pinned = r.Pin
			}
			s.Installed = after
			s.Managed = maps.Clone(r.Packages)
			s.Drift = false
			for p, v := range r.Pin {
				if after[p] != v {
					s.Drift = true
				}
			}
		}
		r.Outcome = "success"
		r.Before = nil
		if err != nil {
			r.Outcome = "failed"
			r.Error = err.Error()
			s.Action = "failed"
			s.Reason = err.Error()
			failed[s.ID] = true
			anyFailure = true
		} else {
			s.Action = "success"
			s.Reason = action + " verified"
		}
		if len(r.Packages) == 0 && err == nil {
			err = m.Store.Delete(s.ID)
		} else {
			err = m.Store.Write(r)
		}
		if err != nil {
			return steps, err
		}
		if err = m.Store.Log(s.ID, action, r.Outcome); err != nil {
			return steps, err
		}
	}
	if anyFailure {
		return steps, fmt.Errorf("one or more modules failed or were blocked")
	}
	return steps, nil
}
