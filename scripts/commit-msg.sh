#!/bin/sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Running commit-msg hook..."

# Find the root of the git repository
git_root=$(git rev-parse --show-toplevel)

# Run commitlint
if ! command -v npx >/dev/null 2>&1; then
    echo -e "${RED}Error: npx is not installed. Please install Node.js and npm.${NC}"
    exit 1
fi

# Run commitlint against the commit message
npx --no-install commitlint --edit "$1"
result=$?

if [ $result -eq 0 ]; then
    echo -e "${GREEN}Commit message follows conventional commit format.${NC}"
    exit 0
else
    echo -e "${RED}Error: Commit message does not follow conventional commit format.${NC}"
    echo "Example formats:"
    echo "  feat: add new feature"
    echo "  fix: resolve issue with X"
    echo "  docs: update README"
    echo "  style: format code"
    echo "  refactor: restructure Y component"
    echo "  test: add tests for Z"
    echo "  chore: update dependencies"
    exit 1
fi
