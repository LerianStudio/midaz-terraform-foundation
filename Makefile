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
