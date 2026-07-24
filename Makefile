# TcpQuality Go port — build / test helpers.
# The probing engine uses raw sockets and targets Linux; build there (or
# cross-compile) and run as root.

BINARY := tcpquality
PKG    := ./cmd/tcpquality
GOFLAGS :=

.PHONY: all build linux test vet fmt cover clean run

all: test build

build:
	go build $(GOFLAGS) -o $(BINARY) $(PKG)

# Cross-compile a static-ish Linux amd64 binary from any host.
linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(GOFLAGS) -o dist/$(BINARY)-linux-amd64 $(PKG)
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build $(GOFLAGS) -o dist/$(BINARY)-linux-arm64 $(PKG)

test:
	go test ./...

vet:
	go vet ./...
	GOOS=linux GOARCH=amd64 go vet ./...

fmt:
	gofmt -w .

cover:
	go test -cover ./internal/...

# Run the tool (needs root for raw sockets).
run: build
	sudo ./$(BINARY) $(ARGS)

clean:
	rm -f $(BINARY) $(BINARY).exe
	rm -rf dist
