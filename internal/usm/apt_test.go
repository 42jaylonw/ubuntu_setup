package usm

import (
	"errors"
	"slices"
	"strings"
	"testing"
)

type runnerFunc func(string, ...string) (string, error)

func (f runnerFunc) Run(name string, args ...string) (string, error) { return f(name, args...) }
func TestAPTInventoryUsesPackageIdentity(t *testing.T) {
	a := APT{runnerFunc(func(name string, args ...string) (string, error) {
		if name != "dpkg-query" {
			t.Fatal(name)
		}
		return "git\tamd64\tinstalled\t1:2.4-0ubuntu1\ngit-extra\tamd64\tconfig-files\t1\n", nil
	})}
	got, err := a.Inspect(module("git"))
	if err != nil || len(got) != 1 || got["git"] != "1:2.4-0ubuntu1" {
		t.Fatal(got, err)
	}
	a.Runner = runnerFunc(func(string, ...string) (string, error) { return "", errors.New("inventory unavailable") })
	if _, err = a.Inspect(module("git")); err == nil {
		t.Fatal("query failure mistaken for missing")
	}
}
func TestAPTSimulationGuards(t *testing.T) {
	for _, tc := range []struct {
		name, action, simulation string
		pins                     Inventory
		reject                   bool
	}{
		{"safe removal", "remove", "Remv git [1]", nil, false},
		{"collateral removal", "remove", "Remv git [1]\nRemv unrelated [1]", nil, true},
		{"install removal", "install", "Remv unrelated [1]", nil, true},
		{"pin violated", "install", "Inst other [1] (2 Ubuntu:24.04/noble [amd64])", Inventory{"other": "1"}, true},
		{"pin respected", "install", "Inst other (1 Ubuntu:24.04/noble [amd64])", Inventory{"other": "1"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := APT{runnerFunc(func(name string, args ...string) (string, error) {
				if name != "apt-get" || args[0] != "--simulate" {
					t.Fatal(name, args)
				}
				if !slices.Contains(args, "--") {
					t.Fatal("no option terminator")
				}
				return tc.simulation, nil
			})}
			_, err := a.Prepare(tc.action, []string{"git"}, nil, false, tc.pins)
			if (err != nil) != tc.reject {
				t.Fatal(err)
			}
		})
	}
}
func TestAPTExactVersionNeverFallsBack(t *testing.T) {
	calls := 0
	a := APT{runnerFunc(func(name string, args ...string) (string, error) {
		calls++
		if name != "apt-cache" {
			t.Fatal("unavailable version reached apt-get")
		}
		return " git | 1:2.4-0ubuntu1 | repository\n", nil
	})}
	if _, err := a.Prepare("install", []string{"git"}, Inventory{"git": "3"}, false, nil); err == nil || calls != 1 {
		t.Fatal(err, calls)
	}
	a.Runner = runnerFunc(func(name string, args ...string) (string, error) {
		if name == "apt-cache" {
			return "git | 1:2.4-0ubuntu1 | repository", nil
		}
		if !slices.Contains(args, "git=1:2.4-0ubuntu1") || !slices.Contains(args, "--no-remove") {
			t.Fatal(args)
		}
		return "", nil
	})
	if _, err := a.Prepare("install", []string{"git"}, Inventory{"git": "1:2.4-0ubuntu1"}, false, nil); err != nil {
		t.Fatal(err)
	}
}
func TestAPTFetchOnlyDownloads(t *testing.T) {
	a := APT{runnerFunc(func(name string, args ...string) (string, error) {
		if name != "apt-get" || args[0] != "--download-only" || strings.Contains(strings.Join(args, " "), " update") {
			t.Fatal(name, args)
		}
		return "", nil
	})}
	if err := a.Fetch([]string{"install", "--", "git"}); err != nil {
		t.Fatal(err)
	}
}
