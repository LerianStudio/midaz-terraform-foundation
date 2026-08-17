.PHONY: init hooks deps

init: deps
	@echo "Initializing git hooks..."
	@rm -rf .git/hooks
	@mkdir -p .git/hooks
	@cp scripts/pre-commit.sh .git/hooks/pre-commit
	@cp scripts/commit-msg.sh .git/hooks/commit-msg
	@chmod +x .git/hooks/pre-commit
	@chmod +x .git/hooks/commit-msg
	@echo "Git hooks initialized!"

deps:
	@echo "Installing dependencies..."
	@npm install --save-dev @commitlint/cli @commitlint/config-conventional
	@echo "Dependencies installed!"

hooks: init

# Go targets for cmd/lerian-infra. lint is deliberately gofmt + go vet and not
# golangci-lint: these are the same two checks the Go job in .github/workflows/ci.yml
# runs, so a green `make lint` means a green CI, and neither needs anything
# installed beyond the Go toolchain.
.PHONY: build test lint

build:
	@echo "Building lerian-infra..."
	@go build -o bin/lerian-infra ./cmd/lerian-infra
	@echo "Built bin/lerian-infra"

test:
	@echo "Running Go tests..."
	@go test ./... -cover

lint:
	@echo "Checking gofmt..."
	@unformatted=$$(gofmt -l .); \
	if [ -n "$$unformatted" ]; then \
		echo "Not gofmt-formatted:"; echo "$$unformatted"; exit 1; \
	fi
	@echo "Running go vet..."
	@go vet ./...
	@echo "Go lint passed!"
