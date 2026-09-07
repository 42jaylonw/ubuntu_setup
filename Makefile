GO ?= go
.DEFAULT_GOAL := build

.PHONY: build test check clean check-go

check-go:
	@command -v "$(GO)" >/dev/null 2>&1 || { \
		echo 'Go 1.23+ is required. Install Go on PATH or use make GO=/path/to/go build.' >&2; \
		exit 1; \
	}

build: check-go
	"$(GO)" build -trimpath -o usm ./cmd/usm

test: check-go
	"$(GO)" test ./...
	python3 scripts/validate_modules.py
	bash tests/run.sh

check: check-go
	"$(GO)" vet ./...
	bash -n setup install.sh scripts/*.sh components/*.sh tests/*.sh

clean:
	$(RM) usm
