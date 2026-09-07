package usm

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const Usage = `Usage: usm <command> [module...] [options]
Commands: list, status, install, update, remove, versions, pin, unpin, lock, sync
Options:
  --profile NAME       Select a profile
  --category NAME,...  Filter by categories
  --all                Select managed modules (update/remove)
  --yes                Apply without confirmation
  --dry-run            Read-only plan; no state writes or cache refresh
  --json               Machine-readable output (use --yes to apply)
  --version VERSION    Exact version for one install/update module
  --allow-downgrade    Permit an explicit downgrade
  --lock PATH          Lock file for sync
  --output PATH        Lock export destination (default: usm.lock.json)
  --modules PATH       Module catalog (default: modules beside executable or ./modules)

APT mutations and pins require root: sudo ./usm install git --yes
The Bash ./setup entry point remains available for unmigrated adapters.
`

func Parse(args []string) (Options, error) {
	o := Options{Output: "usm.lock.json"}
	if len(args) == 0 {
		return o, errors.New(Usage)
	}
	o.Command = args[0]
	if !slices.Contains([]string{"list", "status", "install", "update", "remove", "versions", "pin", "unpin", "lock", "sync"}, o.Command) {
		return o, fmt.Errorf("unknown command %q\n%s", o.Command, Usage)
	}
	f := flag.NewFlagSet("usm", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&o.Profile, "profile", "", "")
	f.StringVar(&o.Category, "category", "", "")
	f.BoolVar(&o.All, "all", false, "")
	f.BoolVar(&o.DryRun, "dry-run", false, "")
	f.BoolVar(&o.Yes, "yes", false, "")
	f.BoolVar(&o.JSON, "json", false, "")
	f.StringVar(&o.Version, "version", "", "")
	f.BoolVar(&o.AllowDowngrade, "allow-downgrade", false, "")
	f.StringVar(&o.Lock, "lock", "", "")
	f.StringVar(&o.Output, "output", o.Output, "")
	f.StringVar(&o.Modules, "modules", "", "")
	// The standard flag package stops at IDs; collect flags while preserving their values.
	flags := []string{}
	for i := 1; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			o.IDs = append(o.IDs, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(a, "-") {
			o.IDs = append(o.IDs, a)
			continue
		}
		flags = append(flags, a)
		name := strings.TrimLeft(strings.SplitN(a, "=", 2)[0], "-")
		if slices.Contains([]string{"profile", "category", "version", "lock", "output", "modules"}, name) && !strings.Contains(a, "=") {
			i++
			if i == len(args) {
				return o, fmt.Errorf("--%s needs a value", name)
			}
			flags = append(flags, args[i])
		}
	}
	if err := f.Parse(flags); err != nil {
		return o, err
	}
	if o.All && o.Command != "update" && o.Command != "remove" && o.Command != "status" && o.Command != "lock" {
		return o, fmt.Errorf("--all is not supported for %s", o.Command)
	}
	if o.AllowDowngrade && o.Command != "install" && o.Command != "update" && o.Command != "sync" {
		return o, fmt.Errorf("--allow-downgrade requires install/update/sync")
	}
	if o.Lock != "" && o.Command != "sync" {
		return o, fmt.Errorf("--lock requires sync")
	}
	return o, nil
}
func output(w io.Writer, jsonMode bool, value any) error {
	if jsonMode {
		e := json.NewEncoder(w)
		e.SetIndent("", "  ")
		return e.Encode(value)
	}
	switch v := value.(type) {
	case []Step:
		for _, s := range v {
			if _, err := fmt.Fprintf(w, "%-18s %-11s %s", s.ID, s.Action, s.Reason); err != nil {
				return err
			}
			if len(s.Installed) > 0 {
				fmt.Fprintf(w, " installed=%v", s.Installed)
			}
			if len(s.Pinned) > 0 {
				fmt.Fprintf(w, " pinned=%v drift=%t", s.Pinned, s.Drift)
			}
			fmt.Fprintln(w)
			if len(s.Argv) > 0 {
				fmt.Fprintf(w, "  %q\n", s.Argv)
			}
		}
	default:
		e := json.NewEncoder(w)
		e.SetIndent("", "  ")
		return e.Encode(value)
	}
	return nil
}
func confirm(o Options, in io.Reader, errOut io.Writer) error {
	if o.Yes || o.DryRun {
		return nil
	}
	if o.JSON {
		return errors.New("--json mutations require --yes or --dry-run")
	}
	fmt.Fprint(errOut, "Apply this plan? [y/N] ")
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil && err != io.EOF {
		return err
	}
	if strings.ToLower(strings.TrimSpace(line)) != "y" {
		return errors.New("cancelled")
	}
	return nil
}
func (m *Manager) Run(o Options, in io.Reader, out, errOut io.Writer) error {
	if o.Command == "lock" && len(o.IDs) == 0 {
		o.All = true
	}
	var lock Lockfile
	exact := map[string]Inventory{}
	if o.Command == "sync" {
		if o.Lock == "" {
			return errors.New("sync requires --lock PATH")
		}
		var err error
		lock, err = m.ReadLock(o.Lock)
		if err != nil {
			return err
		}
		if len(o.IDs) == 0 {
			for _, e := range lock.Modules {
				o.IDs = append(o.IDs, e.ID)
			}
		}
		for _, e := range lock.Modules {
			exact[e.ID] = e.Packages
		}
		for _, id := range o.IDs {
			if _, ok := exact[id]; !ok {
				return fmt.Errorf("%s is not in lock", id)
			}
		}
	}
	ids, err := m.Select(o)
	if err != nil {
		return err
	}
	switch o.Command {
	case "list":
		type entry struct {
			ID           string       `json:"id"`
			Label        string       `json:"label"`
			Category     string       `json:"category"`
			Backend      string       `json:"backend"`
			Supported    bool         `json:"supported"`
			Capabilities Capabilities `json:"capabilities"`
		}
		rows := []entry{}
		for _, id := range ids {
			mod := m.Catalog[id]
			b, ok := m.Backends[mod.Backend]
			caps := Capabilities{}
			if ok {
				caps = b.Capabilities()
			}
			rows = append(rows, entry{id, mod.Label, mod.Category, mod.Backend, ok && mod.Supports(m.Target), caps})
		}
		if o.JSON {
			return output(out, true, rows)
		}
		for _, r := range rows {
			fmt.Fprintf(out, "%-18s %-10s %-8s %s (supported=%t)\n", r.ID, r.Category, r.Backend, r.Label, r.Supported)
		}
		return nil
	case "status":
		steps := []Step{}
		for _, id := range ids {
			s, err := m.Inspect(id)
			if err != nil {
				return err
			}
			steps = append(steps, s)
		}
		return output(out, o.JSON, steps)
	case "versions":
		if len(ids) != 1 {
			return errors.New("versions requires one module")
		}
		mod := m.Catalog[ids[0]]
		b, ok := m.Backends[mod.Backend]
		if !ok || !b.Capabilities().Versions {
			return fmt.Errorf("%s: version enumeration unsupported by this adapter", mod.ID)
		}
		pkgs, _ := mod.Packages()
		versions := map[string][]string{}
		for _, p := range pkgs {
			versions[p], err = b.Versions(p)
			if err != nil {
				return err
			}
		}
		return output(out, o.JSON, versions)
	case "lock":
		lock, err := m.Export(ids)
		if err != nil {
			return err
		}
		if !o.DryRun {
			if err = atomicJSON(o.Output, lock); err != nil {
				return err
			}
		}
		return output(out, o.JSON, lock)
	case "pin", "unpin":
		if len(ids) == 0 {
			return errors.New("pin/unpin requires module IDs or a selection")
		}
		steps, err := m.Pin(ids, o.Command == "unpin", true)
		if err != nil {
			return err
		}
		if o.DryRun {
			return output(out, o.JSON, steps)
		}
		if !o.JSON {
			output(errOut, false, steps)
		}
		if err = confirm(o, in, errOut); err != nil {
			return err
		}
		steps, err = m.Pin(ids, o.Command == "unpin", false)
		if err != nil {
			return err
		}
		return output(out, o.JSON, steps)
	}
	steps, err := m.Plan(o, ids, exact)
	if err != nil {
		return err
	}
	if o.Command == "sync" {
		for i := range steps {
			for _, e := range lock.Modules {
				if steps[i].ID == e.ID && len(steps[i].Pinned) == 0 {
					steps[i].DesiredPin = e.Pin
				}
			}
		}
	}
	if o.DryRun {
		if err = output(out, o.JSON, steps); err != nil {
			return err
		}
		for _, s := range steps {
			if s.Action == "blocked" {
				return errors.New("plan contains blocked modules")
			}
		}
		return nil
	}
	if !o.JSON {
		fmt.Fprintln(errOut, "Plan (APT uses local package indexes):")
		output(errOut, false, steps)
	}
	if err = confirm(o, in, errOut); err != nil {
		return err
	}
	// Resolve and authenticate all archives before changing any installed software.
	for _, s := range steps {
		if (s.Action == "install" || s.Action == "update") && len(s.Argv) > 1 {
			if err = m.Backends[s.Backend].Fetch(s.Argv[1:]); err != nil {
				return fmt.Errorf("%s: download preflight failed: %w", s.ID, err)
			}
		}
	}
	result, applyErr := m.Apply(o, steps)
	if err = output(out, o.JSON, result); err != nil {
		return err
	}
	return applyErr
}
func Main(args []string, in io.Reader, out, errOut io.Writer) int {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		fmt.Fprint(out, Usage)
		return 0
	}
	o, err := Parse(args)
	run := func() error {
		if err != nil {
			return err
		}
		if o.Modules == "" {
			exe, e := os.Executable()
			if e == nil {
				o.Modules = filepath.Join(filepath.Dir(exe), "modules")
			}
			if _, e = os.Stat(o.Modules); e != nil {
				o.Modules = "modules"
			}
		}
		c, err := Load(o.Modules)
		if err != nil {
			return err
		}
		t, err := Host()
		if err != nil {
			return err
		}
		m := Manager{Catalog: c, Target: t, Store: Store{Dir: "/var/lib/usm", Secure: true}, Backends: map[string]Backend{"apt": APT{ExecRunner{}}}}
		mutating := slices.Contains([]string{"install", "update", "remove", "pin", "unpin", "sync"}, o.Command) && !o.DryRun
		if mutating {
			if t.OS != "ubuntu" || release(t.Release) < 2404 {
				return errors.New("mutations require Ubuntu 24.04 or newer")
			}
			if os.Geteuid() != 0 {
				return errors.New("APT mutations and system pins require root; run this command with sudo (dry-run needs no elevation)")
			}
			unlock, err := m.Store.Lock()
			if err != nil {
				return err
			}
			defer unlock()
		}
		return m.Run(o, in, out, errOut)
	}
	if err = run(); err != nil {
		if o.JSON {
			json.NewEncoder(errOut).Encode(map[string]string{"error": err.Error()})
		} else {
			fmt.Fprintln(errOut, "usm:", err)
		}
		return 1
	}
	return 0
}
