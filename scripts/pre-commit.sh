#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "Running pre-commit hooks..."

# Run terraform fmt check
echo "Running terraform fmt check..."
terraform fmt -check -recursive
if [ $? -ne 0 ]; then
    echo -e "${RED}Terraform fmt check failed. Please run 'terraform fmt -recursive' to fix formatting issues.${NC}"
    exit 1
fi
echo -e "${GREEN}Terraform fmt check passed.${NC}"

# Run terraform validate
echo "Running terraform validate..."
terraform init -backend=false
terraform validate
if [ $? -ne 0 ]; then
    echo -e "${RED}Terraform validate failed.${NC}"
    exit 1
fi
echo -e "${GREEN}Terraform validate passed.${NC}"

# Run tfsec for security checks
echo "Running tfsec security checks..."
if ! command -v tfsec &> /dev/null; then
    echo -e "${RED}tfsec not found. Please install it first: https://github.com/aquasecurity/tfsec${NC}"
    exit 1
fi

tfsec .
if [ $? -ne 0 ]; then
    echo -e "${RED}Security checks failed.${NC}"
    exit 1
fi
echo -e "${GREEN}Security checks passed.${NC}"

echo -e "${GREEN}All checks passed!${NC}"
exit 0
