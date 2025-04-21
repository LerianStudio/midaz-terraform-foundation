#!/bin/bash

set -e

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check placeholders in backend files
check_placeholders() {
    local provider=$1
    local components=("network" "dns" "database" "redis" "kubernetes")
    local has_placeholders=false

    for component in "${components[@]}"; do
        local backend_file=""
        case $provider in
            "aws")
                case $component in
                    "network") backend_file="examples/aws/vpc/backend.tf" ;;
                    "dns") backend_file="examples/aws/route53/backend.tf" ;;
                    "database") backend_file="examples/aws/rds/backend.tf" ;;
                    "redis") backend_file="examples/aws/elasticache/backend.tf" ;;
                    "kubernetes") backend_file="examples/aws/eks/backend.tf" ;;
                esac
                ;;
            "azure")
                case $component in
                    "network") backend_file="examples/azure/network/backend.tf" ;;
                    "dns") backend_file="examples/azure/dns/backend.tf" ;;
                    "database") backend_file="examples/azure/database/backend.tf" ;;
                    "redis") backend_file="examples/azure/redis/backend.tf" ;;
                    "kubernetes") backend_file="examples/azure/aks/backend.tf" ;;
                esac
                ;;
            "gcp")
                case $component in
                    "network") backend_file="examples/gcp/vpc/backend.tf" ;;
                    "dns") backend_file="examples/gcp/cloud-dns/backend.tf" ;;
                    "database") backend_file="examples/gcp/cloud-sql/backend.tf" ;;
                    "redis") backend_file="examples/gcp/memorystore/backend.tf" ;;
                    "kubernetes") backend_file="examples/gcp/gke/backend.tf" ;;
                esac
                ;;
        esac

        if [ -f "$backend_file" ]; then
            if grep -q "<.*>" "$backend_file"; then
                print_message "$RED" "Found placeholders in $backend_file"
                has_placeholders=true
            fi
        fi
    done

    if [ "$has_placeholders" = true ]; then
        print_message "$RED" "Please update all placeholders in the backend files before proceeding."
        exit 1
    fi
}

# Function to deploy a component
deploy_component() {
    local provider=$1
    local component=$2
    local component_path=""

    case $provider in
        "aws")
            case $component in
                "network") component_path="examples/aws/vpc" ;;
                "dns") component_path="examples/aws/route53" ;;
                "database") component_path="examples/aws/rds" ;;
                "redis") component_path="examples/aws/elasticache" ;;
                "kubernetes") component_path="examples/aws/eks" ;;
            esac
            ;;
        "azure")
            case $component in
                "network") component_path="examples/azure/network" ;;
                "dns") component_path="examples/azure/dns" ;;
                "database") component_path="examples/azure/database" ;;
                "redis") component_path="examples/azure/redis" ;;
                "kubernetes") component_path="examples/azure/aks" ;;
            esac
            ;;
        "gcp")
            case $component in
                "network") component_path="examples/gcp/vpc" ;;
                "dns") component_path="examples/gcp/cloud-dns" ;;
                "database") component_path="examples/gcp/cloud-sql" ;;
                "redis") component_path="examples/gcp/memorystore" ;;
                "kubernetes") component_path="examples/gcp/gke" ;;
            esac
            ;;
    esac

    if [ -d "$component_path" ]; then
        print_message "$YELLOW" "\nDeploying $component in $provider..."
        cd "$component_path"
        
        print_message "$YELLOW" "Running terraform init..."
        terraform init
        
        print_message "$YELLOW" "Running terraform plan..."
        terraform plan -out=tfplan
        
        print_message "$YELLOW" "Running terraform apply..."
        terraform apply tfplan
        
        cd - > /dev/null
        print_message "$GREEN" "$component deployment completed successfully!"
    else
        print_message "$RED" "Component path $component_path not found!"
        exit 1
    fi
}

# Main script
print_message "$GREEN" "Welcome to the Infrastructure Deployment Helper!"
print_message "$YELLOW" "\nAvailable cloud providers:"
print_message "$NC" "1) AWS"
print_message "$NC" "2) Azure"
print_message "$NC" "3) GCP"

read -p "Select a cloud provider (1-3): " provider_choice

case $provider_choice in
    1) provider="aws" ;;
    2) provider="azure" ;;
    3) provider="gcp" ;;
    *)
        print_message "$RED" "Invalid choice!"
        exit 1
        ;;
esac

# Check for placeholders
print_message "$YELLOW" "\nChecking for placeholders in backend configurations..."
check_placeholders "$provider"

# Deploy components in order
components=("network" "dns" "database" "redis" "kubernetes")
for component in "${components[@]}"; do
    deploy_component "$provider" "$component"
done

print_message "$GREEN" "\nInfrastructure deployment completed successfully!"
