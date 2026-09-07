package usm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

type Receipt struct {
	Schema   int       `json:"schema_version"`
	ID       string    `json:"id"`
	Digest   string    `json:"manifest_digest"`
	Backend  string    `json:"backend"`
	Scope    string    `json:"scope"`
	Packages Inventory `json:"packages"`
	Before   Inventory `json:"before,omitempty"`
	Pin      Inventory `json:"pin,omitempty"`
	Outcome  string    `json:"outcome"`
	Error    string    `json:"error,omitempty"`
}
type Store struct {
	Dir    string
	Secure bool
}

func (s Store) check(path string) error {
	if !s.Secure {
		return nil
	}
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || info.Mode()&0022 != 0 || (!info.IsDir() && !info.Mode().IsRegular()) {
		return fmt.Errorf("untrusted system state path: %s", path)
	}
	return nil
}
func (s Store) Read(id string) (*Receipt, error) {
	if !identifier.MatchString(id) {
		return nil, fmt.Errorf("invalid receipt ID")
	}
	if err := s.check(s.Dir); err != nil {
		return nil, err
	}
	if err := s.check(filepath.Join(s.Dir, id+".json")); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(s.Dir, id+".json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var r Receipt
	if err = decode(data, &r); err != nil {
		return nil, err
	}
	if r.Schema != 1 || r.ID != id || r.Backend != "apt" || r.Scope != "system" || len(r.Packages) == 0 {
		return nil, fmt.Errorf("%s: invalid receipt", id)
	}
	for p := range r.Packages {
		if !packageID.MatchString(p) {
			return nil, fmt.Errorf("%s: invalid receipt package", id)
		}
	}
	for p, v := range r.Pin {
		if !packageID.MatchString(p) || v == "" {
			return nil, fmt.Errorf("%s: invalid receipt pin", id)
		}
	}
	return &r, nil
}
func atomicJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".usm-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0644); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func (s Store) Write(r *Receipt) error { return atomicJSON(filepath.Join(s.Dir, r.ID+".json"), r) }
func (s Store) Delete(id string) error {
	err := os.Remove(filepath.Join(s.Dir, id+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
func (s Store) Lock() (func(), error) {
	if err := s.check(s.Dir); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(s.Dir, 0755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(s.Dir, "operation.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another USM mutation is active: %w", err)
	}
	return func() { f.Close() }, nil
}
func (s Store) Log(id, action, outcome string) error {
	f, err := os.OpenFile(filepath.Join(s.Dir, "operations.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = json.NewEncoder(f).Encode(map[string]string{"time": time.Now().UTC().Format(time.RFC3339), "module": id, "action": action, "outcome": outcome}); err != nil {
		return err
	}
	return f.Sync()
}
