package usm

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
)

type Platform struct {
	OS            string   `json:"os"`
	Version       string   `json:"min_version"`
	Architectures []string `json:"architectures"`
}
type Module struct {
	Schema      int      `json:"schema_version"`
	ID          string   `json:"id"`
	Label       string   `json:"label"`
	Description string   `json:"description"`
	Category    string   `json:"category"`
	Profiles    []string `json:"profiles"`
	Hidden      bool     `json:"hidden"`
	Platform    Platform `json:"platform"`
	Depends     []string `json:"depends_on"`
	Detect      struct {
		Commands []string `json:"commands"`
	} `json:"detect"`
	Backend   string          `json:"backend"`
	Spec      json.RawMessage `json:"spec"`
	Lifecycle struct {
		Install  string `json:"install"`
		Update   string `json:"update"`
		Remove   string `json:"remove"`
		Preserve bool   `json:"preserve_user_data"`
	} `json:"lifecycle"`
	Legacy string `json:"legacy_source"`
	Digest string `json:"-"`
}
type Catalog map[string]Module

var identifier = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
var packageID = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*(?::(?:amd64|arm64))?$`)

func decode(data []byte, value any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("expected one JSON value")
	}
	return nil
}
func Load(dir string) (Catalog, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("no modules in %s", dir)
	}
	c := Catalog{}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var m Module
		if err = decode(data, &m); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if !identifier.MatchString(m.ID) || filepath.Base(path) != m.ID+".json" || m.Schema != 1 || m.Label == "" || m.Category == "" {
			return nil, fmt.Errorf("%s: invalid module identity/schema", path)
		}
		if m.Platform.OS != "ubuntu" || release(m.Platform.Version) < 2404 || len(m.Platform.Architectures) == 0 {
			return nil, fmt.Errorf("%s: invalid platform", m.ID)
		}
		for _, a := range m.Platform.Architectures {
			if a != "amd64" && a != "arm64" {
				return nil, fmt.Errorf("%s: invalid architecture", m.ID)
			}
		}
		if m.Lifecycle.Install != "ensure-present" || m.Lifecycle.Update != "existing-only" || !m.Lifecycle.Preserve || !slices.Contains([]string{"recorded-packages", "recorded-files", "recorded-backend", "managed-block-and-file"}, m.Lifecycle.Remove) {
			return nil, fmt.Errorf("%s: invalid lifecycle", m.ID)
		}
		var spec map[string]json.RawMessage
		if err = json.Unmarshal(m.Spec, &spec); err != nil {
			return nil, err
		}
		field, ok := map[string]string{"apt": "packages", "deb": "url", "vendor": "installer_url", "symlink": "target_command", "adapter": "adapter"}[m.Backend]
		if !ok || len(spec[field]) == 0 {
			return nil, fmt.Errorf("%s: invalid backend spec", m.ID)
		}
		if m.Backend == "apt" {
			if _, err = m.Packages(); err != nil {
				return nil, err
			}
		}
		var canonical any
		if err = json.Unmarshal(data, &canonical); err != nil {
			return nil, err
		}
		normalized, _ := json.Marshal(canonical)
		sum := sha256.Sum256(normalized)
		m.Digest = hex.EncodeToString(sum[:])
		c[m.ID] = m
	}
	_, err = c.Order(c.IDs(), true)
	return c, err
}
func (m Module) Packages() ([]string, error) {
	var s struct {
		Packages []string `json:"packages"`
	}
	if err := decode(m.Spec, &s); err != nil {
		return nil, fmt.Errorf("%s: %w", m.ID, err)
	}
	if len(s.Packages) == 0 {
		return nil, fmt.Errorf("%s: empty packages", m.ID)
	}
	seen := map[string]bool{}
	for _, p := range s.Packages {
		if !packageID.MatchString(p) || seen[p] {
			return nil, fmt.Errorf("%s: invalid/duplicate package %q", m.ID, p)
		}
		seen[p] = true
	}
	return s.Packages, nil
}
func (c Catalog) IDs() []string {
	ids := make([]string, 0, len(c))
	for id := range c {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}
func (c Catalog) Order(ids []string, dependencies bool) ([]string, error) {
	marks := map[string]int{}
	var out []string
	var visit func(string) error
	visit = func(id string) error {
		m, ok := c[id]
		if !ok {
			return fmt.Errorf("unknown module %q", id)
		}
		if marks[id] == 1 {
			return fmt.Errorf("dependency cycle at %s", id)
		}
		if marks[id] == 2 {
			return nil
		}
		marks[id] = 1
		for _, dep := range m.Depends {
			if _, ok := c[dep]; !ok {
				return fmt.Errorf("%s: unknown dependency %s", id, dep)
			}
			if dependencies || slices.Contains(ids, dep) {
				if err := visit(dep); err != nil {
					return err
				}
			}
		}
		marks[id] = 2
		out = append(out, id)
		return nil
	}
	for _, id := range ids {
		if err := visit(id); err != nil {
			return nil, err
		}
	}
	return out, nil
}
func release(s string) int {
	parts := strings.Split(s, ".")
	if len(parts) != 2 {
		return 0
	}
	a, e := strconv.Atoi(parts[0])
	b, f := strconv.Atoi(parts[1])
	if e != nil || f != nil || a < 1 || b < 0 || b > 99 {
		return 0
	}
	return a*100 + b
}

type Target struct {
	OS      string `json:"os"`
	Release string `json:"release"`
	Arch    string `json:"architecture"`
}

func Host() (Target, error) {
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return Target{}, err
	}
	t := Target{}
	for _, line := range strings.Split(string(data), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if ok {
			v = strings.Trim(v, `"`)
			switch k {
			case "ID":
				t.OS = v
			case "VERSION_ID":
				t.Release = v
			}
		}
	}
	out, err := ExecRunner{}.Run("dpkg", "--print-architecture")
	t.Arch = strings.TrimSpace(out)
	return t, err
}
func (m Module) Supports(t Target) bool {
	return t.OS == m.Platform.OS && release(t.Release) >= release(m.Platform.Version) && slices.Contains(m.Platform.Architectures, t.Arch)
}
