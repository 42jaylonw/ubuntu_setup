package usm

import (
	"bytes"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

type fakeBackend struct {
	installed Inventory
	available map[string][]string
	failures  map[string]bool
	calls     []string
	fetched   int
}

func (f *fakeBackend) Inspect(m Module) (Inventory, error) {
	p, _ := m.Packages()
	v := Inventory{}
	for _, p := range p {
		if f.installed[p] != "" {
			v[p] = f.installed[p]
		}
	}
	return v, nil
}
func (f *fakeBackend) Versions(p string) ([]string, error) {
	if v, ok := f.available[p]; ok {
		return v, nil
	}
	return []string{"1", "2", "3"}, nil
}
func (f *fakeBackend) Compare(a, b string) (int, error) { return strings.Compare(a, b), nil }
func (f *fakeBackend) Capabilities() Capabilities       { return Capabilities{true, true, true, true} }
func (f *fakeBackend) Prepare(action string, p []string, v Inventory, down bool, pins Inventory) ([]string, error) {
	args := []string{action}
	for _, p := range p {
		if v[p] != "" {
			p += "=" + v[p]
		}
		args = append(args, p)
	}
	return args, nil
}
func (f *fakeBackend) Fetch([]string) error { f.fetched++; return nil }
func (f *fakeBackend) Apply(args []string) error {
	for _, spec := range args[1:] {
		p, v, _ := strings.Cut(spec, "=")
		f.calls = append(f.calls, args[0]+" "+p)
		if f.failures[p] {
			return errors.New("injected failure")
		}
		if args[0] == "remove" {
			delete(f.installed, p)
		} else {
			if v == "" {
				v = "2"
			}
			f.installed[p] = v
		}
	}
	return nil
}
func module(id string, deps ...string) Module {
	m := Module{Schema: 1, ID: id, Label: id, Category: "base", Profiles: []string{"minimal", "workstation"}, Backend: "apt", Depends: deps, Digest: "digest-" + id, Platform: Platform{"ubuntu", "24.04", []string{"amd64", "arm64"}}}
	m.Spec = json.RawMessage(`{"packages":["` + id + `"]}`)
	return m
}
func fixture(t *testing.T) (*Manager, *fakeBackend) {
	t.Helper()
	f := &fakeBackend{installed: Inventory{}, failures: map[string]bool{}, available: map[string][]string{}}
	m := &Manager{Catalog: Catalog{"git": module("git", "bootstrap"), "bootstrap": module("bootstrap"), "jq": module("jq")}, Target: Target{"ubuntu", "24.04", "amd64"}, Store: Store{Dir: filepath.Join(t.TempDir(), "state")}, Backends: map[string]Backend{"apt": f}, LookPath: func(string) (string, error) { return "", errors.New("not found") }}
	return m, f
}
func own(t *testing.T, m *Manager, f *fakeBackend, id, v string) {
	t.Helper()
	f.installed[id] = v
	r := &Receipt{Schema: 1, ID: id, Digest: m.Catalog[id].Digest, Backend: "apt", Scope: "system", Packages: Inventory{id: v}, Outcome: "success"}
	if err := m.Store.Write(r); err != nil {
		t.Fatal(err)
	}
}
func apply(t *testing.T, m *Manager, o Options) []Step {
	t.Helper()
	ids, err := m.Select(o)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := m.Plan(o, ids, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := m.Apply(o, plan)
	if err != nil {
		t.Fatal(err)
	}
	return got
}
func TestAPTLifecycle(t *testing.T) {
	m, f := fixture(t)
	o := Options{Command: "install", IDs: []string{"git"}}
	apply(t, m, o)
	if !slices.Equal(f.calls, []string{"install bootstrap", "install git"}) {
		t.Fatal(f.calls)
	}
	f.calls = nil
	apply(t, m, o)
	if len(f.calls) != 0 {
		t.Fatal("repeat install mutated", f.calls)
	}
	o.Command = "update"
	apply(t, m, o)
	if !slices.Equal(f.calls, []string{"update git"}) {
		t.Fatal(f.calls)
	}
	o.Command = "remove"
	apply(t, m, o)
	r, err := m.Store.Read("git")
	if err != nil || r != nil {
		t.Fatal(r, err)
	}
	if f.installed["bootstrap"] == "" {
		t.Fatal("removed unselected dependency")
	}
}
func TestExternalOwnership(t *testing.T) {
	m, f := fixture(t)
	f.installed["git"] = "1"
	f.installed["bootstrap"] = "1"
	for _, action := range []string{"install", "update", "remove"} {
		apply(t, m, Options{Command: action, IDs: []string{"git"}})
	}
	if len(f.calls) != 0 {
		t.Fatal(f.calls)
	}
	if r, _ := m.Store.Read("git"); r != nil {
		t.Fatal("adopted external install")
	}
	mod := m.Catalog["git"]
	mod.Spec = json.RawMessage(`{"packages":["git","git-extra"]}`)
	m.Catalog["git"] = mod
	apply(t, m, Options{Command: "install", IDs: []string{"git"}})
	r, _ := m.Store.Read("git")
	if !maps.Equal(r.Packages, Inventory{"git-extra": "2"}) {
		t.Fatal(r)
	}
	apply(t, m, Options{Command: "remove", IDs: []string{"git"}})
	if f.installed["git"] != "1" {
		t.Fatal("removed preexisting package")
	}
}
func TestFailureBlocksDependentsAndContinues(t *testing.T) {
	m, f := fixture(t)
	f.failures["bootstrap"] = true
	o := Options{Command: "install"}
	plan, err := m.Plan(o, []string{"git", "jq"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := m.Apply(o, plan)
	if err == nil || got[0].Action != "failed" || got[1].Action != "blocked" || got[2].Action != "success" {
		t.Fatal(got, err)
	}
	r, err := m.Store.Read("bootstrap")
	if err != nil || r == nil || r.Outcome != "failed" {
		t.Fatal(r, err)
	}
	f.failures["bootstrap"] = false
	apply(t, m, Options{Command: "install", IDs: []string{"git"}})
}
func TestRemoveDependencyGuards(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "bootstrap", "1")
	own(t, m, f, "git", "1")
	if _, err := m.Plan(Options{Command: "remove"}, []string{"bootstrap"}, nil); err == nil {
		t.Fatal("removed retained dependency")
	}
	plan, err := m.Plan(Options{Command: "remove"}, []string{"bootstrap", "git"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if plan[0].ID != "git" {
		t.Fatal(plan)
	}
	f.failures["git"] = true
	got, err := m.Apply(Options{Command: "remove"}, plan)
	if err == nil || got[1].Action != "blocked" {
		t.Fatal(got, err)
	}
}
func TestPinsAndDrift(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "1")
	if _, err := m.Pin([]string{"git"}, false, false); err != nil {
		t.Fatal(err)
	}
	plan, err := m.Plan(Options{Command: "update"}, []string{"git"}, nil)
	if err != nil || plan[0].Action != "skip" {
		t.Fatal(plan, err)
	}
	f.installed["git"] = "2"
	s, err := m.Inspect("git")
	if err != nil || !s.Drift {
		t.Fatal(s, err)
	}
	if _, err = m.Plan(Options{Command: "update", Version: "3"}, []string{"git"}, nil); err == nil {
		t.Fatal("overrode pin")
	}
	if _, err = m.Plan(Options{Command: "install"}, []string{"git"}, nil); err == nil {
		t.Fatal("silently downgraded drift")
	}
	if _, err = m.Pin([]string{"git"}, true, false); err != nil {
		t.Fatal(err)
	}
	plan, err = m.Plan(Options{Command: "update", Version: "1", AllowDowngrade: true}, []string{"git"}, nil)
	if err != nil || plan[0].Versions["git"] != "1" {
		t.Fatal(plan, err)
	}
}
func TestDryRunWritesNothing(t *testing.T) {
	m, f := fixture(t)
	var out bytes.Buffer
	if err := m.Run(Options{Command: "install", IDs: []string{"git"}, DryRun: true, JSON: true}, strings.NewReader(""), &out, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(m.Store.Dir); !os.IsNotExist(err) {
		t.Fatal("dry run wrote state", err)
	}
	if len(f.calls) != 0 || f.fetched != 0 {
		t.Fatal("dry run mutated")
	}
	var steps []Step
	if err := json.Unmarshal(out.Bytes(), &steps); err != nil || len(steps) != 2 {
		t.Fatal(out.String(), err)
	}
}
func TestLocksDeterministicAndValidated(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "1")
	own(t, m, f, "jq", "2")
	a, err := m.Export([]string{"jq", "git"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.Export([]string{"git", "jq"})
	if err != nil {
		t.Fatal(err)
	}
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	if !bytes.Equal(x, y) {
		t.Fatal("unstable export")
	}
	path := filepath.Join(t.TempDir(), "usm.lock.json")
	if err = atomicJSON(path, a); err != nil {
		t.Fatal(err)
	}
	if _, err = m.ReadLock(path); err != nil {
		t.Fatal(err)
	}
	a.Target.Arch = "arm64"
	atomicJSON(path, a)
	if _, err = m.ReadLock(path); err == nil {
		t.Fatal("accepted incompatible target")
	}
	a.Target = m.Target
	a.Modules[0].Digest = "changed"
	atomicJSON(path, a)
	if _, err = m.ReadLock(path); err == nil {
		t.Fatal("accepted changed manifest")
	}
}
func TestSyncPreflightAndPartialFailure(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "1")
	own(t, m, f, "bootstrap", "1")
	own(t, m, f, "jq", "1")
	lock, err := m.Export([]string{"git", "bootstrap", "jq"})
	if err != nil {
		t.Fatal(err)
	}
	for i := range lock.Modules {
		e := &lock.Modules[i]
		e.Packages[e.ID] = "2"
	}
	path := filepath.Join(t.TempDir(), "lock.json")
	atomicJSON(path, lock)
	f.available["jq"] = []string{"1"}
	var out bytes.Buffer
	o := Options{Command: "sync", Lock: path, Yes: true, JSON: true}
	if err = m.Run(o, strings.NewReader(""), &out, &out); err == nil {
		t.Fatal("accepted unavailable version")
	}
	if len(f.calls) != 0 {
		t.Fatal("mutated before validating all entries")
	}
	delete(f.available, "jq")
	f.failures["git"] = true
	out.Reset()
	if err = m.Run(o, strings.NewReader(""), &out, &out); err == nil {
		t.Fatal("missed failure")
	}
	r, _ := m.Store.Read("git")
	if r.Outcome != "failed" || r.Packages["git"] != "1" {
		t.Fatal(r)
	}
	r, _ = m.Store.Read("jq")
	if r.Packages["jq"] != "2" {
		t.Fatal(r)
	}
}
func TestPendingReceiptRecovery(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "2")
	r, _ := m.Store.Read("git")
	r.Outcome = "pending"
	r.Packages["git"] = ""
	m.Store.Write(r)
	s, err := m.Inspect("git")
	if err != nil || s.Managed["git"] != "2" {
		t.Fatal(s, err)
	}
	apply(t, m, Options{Command: "remove", IDs: []string{"git"}})
}
func TestSelectionAndParse(t *testing.T) {
	o, err := Parse([]string{"install", "git", "--dry-run", "--version", "1", "--json"})
	if err != nil || !o.DryRun || o.Version != "1" || !slices.Equal(o.IDs, []string{"git"}) {
		t.Fatal(o, err)
	}
	m, _ := fixture(t)
	for _, o := range []Options{{Command: "update", Category: "base"}, {Command: "remove"}, {Command: "install", IDs: []string{"nope"}}, {Command: "install", Category: "base,nope"}, {Command: "install", IDs: []string{"git", "jq"}, Version: "1"}} {
		if _, err = m.Select(o); err == nil {
			t.Fatal("accepted", o)
		}
	}
}
func TestCatalog(t *testing.T) {
	c, err := Load("../../modules")
	if err != nil || len(c) != 41 {
		t.Fatal(len(c), err)
	}
	m := c["git"]
	m.Depends = []string{"git"}
	c["git"] = m
	if _, err = c.Order([]string{"git"}, true); err == nil {
		t.Fatal("accepted cycle")
	}
	dir := t.TempDir()
	data, _ := os.ReadFile("../../modules/git.json")
	data = bytes.Replace(data, []byte(`"schema_version": 1`), []byte(`"schema_version": 1, "unknown": true`), 1)
	os.WriteFile(filepath.Join(dir, "git.json"), data, 0600)
	if _, err = Load(dir); err == nil {
		t.Fatal("accepted unknown field")
	}
}
func TestStoreRejectsCorruptionAndConcurrentWriter(t *testing.T) {
	m, _ := fixture(t)
	unlock, err := m.Store.Lock()
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if release, err := m.Store.Lock(); err == nil {
		release()
		t.Fatal("allowed simultaneous writer")
	}
	os.WriteFile(filepath.Join(m.Store.Dir, "git.json"), []byte(`{"schema_version": 99}`), 0600)
	if _, err = m.Store.Read("git"); err == nil {
		t.Fatal("accepted corrupt receipt")
	}
	if _, err = m.Store.Read("../git"); err == nil {
		t.Fatal("accepted traversal")
	}
}

func TestAllAPTModulesLifecycle(t *testing.T) {
	m, f := fixture(t)
	c, err := Load("../../modules")
	if err != nil {
		t.Fatal(err)
	}
	m.Catalog = c
	ids := []string{}
	for _, id := range c.IDs() {
		if c[id].Backend == "apt" {
			ids = append(ids, id)
		}
	}
	apply(t, m, Options{Command: "install", IDs: ids})
	f.calls = nil
	apply(t, m, Options{Command: "install", IDs: ids})
	if len(f.calls) > 0 {
		t.Fatal("repeat installation mutated", f.calls)
	}
	apply(t, m, Options{Command: "update", IDs: ids})
	apply(t, m, Options{Command: "remove", IDs: ids})
	if len(f.installed) > 0 {
		t.Fatal("left managed packages", f.installed)
	}
}
func TestUnsupportedTargetsAndAdapters(t *testing.T) {
	m, _ := fixture(t)
	for _, target := range []Target{{"ubuntu", "22.04", "amd64"}, {"debian", "26.04", "amd64"}, {"ubuntu", "24.04", "riscv64"}} {
		m.Target = target
		steps, err := m.Plan(Options{Command: "install"}, []string{"git"}, nil)
		if err != nil || steps[1].Action != "blocked" {
			t.Fatal(steps, err)
		}
	}
	m.Target = Target{"ubuntu", "26.04", "arm64"}
	steps, err := m.Plan(Options{Command: "install"}, []string{"git"}, nil)
	if err != nil || steps[1].Action != "install" {
		t.Fatal(steps, err)
	}
	mod := m.Catalog["bootstrap"]
	mod.Backend = "vendor"
	m.Catalog["bootstrap"] = mod
	steps, err = m.Plan(Options{Command: "install"}, []string{"git"}, nil)
	if err != nil || steps[1].Action != "blocked" {
		t.Fatal(steps, err)
	}
	if _, err = m.Plan(Options{Command: "install", Version: "2"}, []string{"bootstrap"}, nil); err == nil {
		t.Fatal("unsupported exact request accepted")
	}
}
func TestReinstallReconcilesInterruptedReceipt(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "2")
	f.installed["bootstrap"] = "1"
	r, _ := m.Store.Read("git")
	r.Outcome = "pending"
	r.Packages["git"] = ""
	m.Store.Write(r)
	apply(t, m, Options{Command: "install", IDs: []string{"git"}})
	r, err := m.Store.Read("git")
	if err != nil || r.Outcome != "success" || r.Packages["git"] != "2" {
		t.Fatal(r, err)
	}
}
func TestInventoryChangeAfterPlanningIsNotAdopted(t *testing.T) {
	m, f := fixture(t)
	steps, err := m.Plan(Options{Command: "install"}, []string{"jq"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.installed["jq"] = "1"
	result, err := m.Apply(Options{Command: "install"}, steps)
	if err == nil || result[0].Action != "failed" || len(f.calls) > 0 {
		t.Fatal(result, err)
	}
	r, err := m.Store.Read("jq")
	if err != nil || r != nil {
		t.Fatal(r, err)
	}
}

func TestSyncPersistsPinsWithEachVerifiedModule(t *testing.T) {
	m, f := fixture(t)
	own(t, m, f, "git", "1")
	own(t, m, f, "bootstrap", "1")
	own(t, m, f, "jq", "1")
	lock, err := m.Export([]string{"bootstrap", "git", "jq"})
	if err != nil {
		t.Fatal(err)
	}
	for i := range lock.Modules {
		e := &lock.Modules[i]
		e.Packages[e.ID] = "2"
		e.Pin = Inventory{e.ID: "2"}
	}
	path := filepath.Join(t.TempDir(), "lock.json")
	if err = atomicJSON(path, lock); err != nil {
		t.Fatal(err)
	}
	f.failures["jq"] = true
	var out bytes.Buffer
	if err = m.Run(Options{Command: "sync", Lock: path, Yes: true, JSON: true}, strings.NewReader(""), &out, &out); err == nil {
		t.Fatal("expected partial failure")
	}
	r, err := m.Store.Read("git")
	if err != nil || r.Pin["git"] != "2" || r.Outcome != "success" {
		t.Fatal(r, err)
	}
	r, err = m.Store.Read("jq")
	if err != nil || len(r.Pin) > 0 || r.Outcome != "failed" {
		t.Fatal(r, err)
	}
}
