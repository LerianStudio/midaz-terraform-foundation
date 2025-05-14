# Contributing to midaz-terraform-foundation

Thank you for your interest in contributing to midaz-terraform-foundation! This document provides guidelines and instructions for contributing.

## Development Workflow

1. Fork the repository
2. Create a new branch from `main` following the naming convention:
   - `feature/*` for new features
   - `fix/*` for bug fixes
3. Make your changes
4. Ensure all tests pass and code is properly formatted
5. Submit a pull request to the `develop` branch
6. After review and testing, changes will be merged into `main`

## Git Flow

We follow this git flow:
1. Feature/fix branches from main
2. Pull requests to develop
3. Testing on develop
4. Merge into main

## Commit Messages

Follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Types:
- feat: new feature
- fix: bug fix
- docs: documentation changes
- style: formatting changes
- refactor: code restructuring
- test: adding/modifying tests
- chore: maintenance tasks

## Code Standards

1. Use official Terraform modules when available
2. Follow Terraform best practices
3. Include proper documentation
4. Ensure security best practices
5. Write clear and descriptive variable/output names

## Testing

Before submitting a PR:
1. Run `make hooks` to install git hooks
2. Ensure `terraform fmt` passes
3. Ensure `terraform validate` passes
4. Run security checks with `tfsec`

## Documentation

- Update README.md if necessary
- Include module-specific documentation
- Document variables and outputs
- Provide usage examples
