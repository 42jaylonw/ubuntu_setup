package usm

import (
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
)

// Runner is the only subprocess boundary. No command is passed through a shell.
type Runner interface {
	Run(name string, args ...string) (string, error)
}
type ExecRunner struct{}

func (ExecRunner) Run(name string, args ...string) (string, error) {
	c := exec.Command(name, args...)
	c.Env = append(os.Environ(), "LC_ALL=C", "DEBIAN_FRONTEND=noninteractive")
	data, err := c.CombinedOutput()
	if err != nil {
		return string(data), fmt.Errorf("%s %v: %w: %s", name, args, err, strings.TrimSpace(string(data)))
	}
	return string(data), nil
}

type Capabilities struct {
	Versions   bool `json:"versions"`
	Exact      bool `json:"exact_install"`
	Downgrade  bool `json:"downgrade"`
	NativeHold bool `json:"native_hold"`
}
type Inventory map[string]string

// Backends own package identity and version semantics; the planner owns policy.
type Backend interface {
	Inspect(Module) (Inventory, error)
	Versions(string) ([]string, error)
	Compare(string, string) (int, error)
	Prepare(string, []string, Inventory, bool, Inventory) ([]string, error)
	Fetch([]string) error
	Apply([]string) error
	Capabilities() Capabilities
}
type APT struct{ Runner Runner }

func (a APT) Capabilities() Capabilities { return Capabilities{true, true, true, true} }
func (a APT) Inspect(m Module) (Inventory, error) {
	pkgs, err := m.Packages()
	if err != nil {
		return nil, err
	}
	out := Inventory{}
	// Query the inventory once, so a missing package is distinct from a failed query.
	data, err := a.Runner.Run("dpkg-query", "-W", "-f=${Package}\t${Architecture}\t${db:Status-Status}\t${Version}\n")
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(data, "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 4 || f[2] != "installed" {
			continue
		}
		for _, p := range pkgs {
			if p == f[0] || p == f[0]+":"+f[1] {
				out[p] = f[3]
			}
		}
	}
	return out, nil
}
func (a APT) Versions(pkg string) ([]string, error) {
	data, err := a.Runner.Run("apt-cache", "madison", pkg)
	if err != nil {
		return nil, err
	}
	v := []string{}
	for _, line := range strings.Split(data, "\n") {
		f := strings.Split(line, "|")
		if len(f) >= 3 {
			s := strings.TrimSpace(f[1])
			if s != "" && !slices.Contains(v, s) {
				v = append(v, s)
			}
		}
	}
	return v, nil
}
func (a APT) Compare(x, y string) (int, error) {
	if x == y {
		return 0, nil
	}
	for _, op := range []string{"lt", "gt"} {
		_, err := a.Runner.Run("dpkg", "--compare-versions", x, op, y)
		if err == nil {
			if op == "lt" {
				return -1, nil
			}
			return 1, nil
		}
	}
	return 0, fmt.Errorf("cannot compare Debian versions %q and %q", x, y)
}
func (a APT) Prepare(action string, pkgs []string, versions Inventory, allowDown bool, pins Inventory) ([]string, error) {
	args := []string{"-o", "DPkg::Lock::Timeout=60", "-y", "--no-install-recommends", "--no-auto-remove"}
	if action != "remove" {
		args = append(args, "--no-remove")
		if allowDown {
			args = append(args, "--allow-downgrades")
		}
	}
	verb := "install"
	if action == "remove" {
		verb = "remove"
	}
	args = append(args, verb, "--")
	for _, p := range pkgs {
		if v := versions[p]; v != "" && action != "remove" {
			available, err := a.Versions(p)
			if err != nil {
				return nil, err
			}
			if !slices.Contains(available, v) {
				return nil, fmt.Errorf("%s=%s unavailable in local APT metadata; refresh indexes explicitly", p, v)
			}
			p += "=" + v
		}
		args = append(args, p)
	}
	// APT is the dependency solver. Refuse any implicit package removal.
	out, err := a.Runner.Run("apt-get", append([]string{"--simulate"}, args...)...)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) >= 3 && f[0] == "Inst" && pins[f[1]] != "" {
			next := ""
			for _, field := range f[2:] {
				if strings.HasPrefix(field, "(") {
					next = strings.TrimPrefix(field, "(")
					break
				}
			}
			if next != pins[f[1]] {
				return nil, fmt.Errorf("APT would change pinned package %s to %s; unpin its module first", f[1], next)
			}
		}
		if len(f) >= 2 && f[0] == "Remv" {
			if action != "remove" || !slices.Contains(pkgs, f[1]) {
				return nil, fmt.Errorf("APT would also remove %s; select its owning module explicitly", f[1])
			}
		}
	}
	return args, nil
}
func (a APT) Apply(args []string) error { _, err := a.Runner.Run("apt-get", args...); return err }

// APT authenticates repository metadata and verifies archive hashes during download.
func (a APT) Fetch(args []string) error {
	_, err := a.Runner.Run("apt-get", append([]string{"--download-only"}, args...)...)
	return err
}
