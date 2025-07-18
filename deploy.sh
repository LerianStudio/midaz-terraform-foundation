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

# Print table header
print_table_header() {
    printf "\n%-15s %-10s %-20s %-10s\n" "Component" "Action" "Status" "Duration"
    printf "%-15s %-10s %-20s %-10s\n" "---------" "------" "------" "--------"
}

# Print a row in the table with color on status
print_table_row() {
    local component=$1
    local action=$2
    local status=$3
    local color=$4
    local duration=$5
    printf "%-15s %-10s ${color}%-20s${NC} %-10s\n" "$component" "$action" "$status" "$duration"
}

# Function to check placeholders in backend files
check_placeholders() {
    local provider=$1
    local components=("network" "dns" "database" "valkey" "kubernetes")
    local has_placeholders=false

    for component in "${components[@]}"; do
        local backend_file=""
        case $provider in
            "aws")
                case $component in
                    "network") backend_file="examples/aws/vpc/backend.tf" ;;
                    "dns") backend_file="examples/aws/route53/backend.tf" ;;
                    "database") backend_file="examples/aws/rds/backend.tf" ;;
                    "valkey") backend_file="examples/aws/valkey/backend.tf" ;;
                    "rabbitmq") backend_file="examples/aws/amazonmq/backend.tf" ;;
                    "mongodb") backend_file="examples/aws/documentdb/backend.tf" ;;
                    "kubernetes") backend_file="examples/aws/eks/backend.tf" ;;
                esac
                ;;
            "azure")
                case $component in
                    "network") backend_file="examples/azure/network/backend.tf" ;;
                    "dns") backend_file="examples/azure/dns/backend.tf" ;;
                    "database") backend_file="examples/azure/database/backend.tf" ;;
                    "valkey") backend_file="examples/azure/redis/backend.tf" ;;
                    "kubernetes") backend_file="examples/azure/aks/backend.tf" ;;
                    "mongodb") backend_file="examples/azure/cosmosdb/backend.tf" ;;
                esac
                ;;
            "gcp")
                case $component in
                    "network") backend_file="examples/gcp/vpc/backend.tf" ;;
                    "dns") backend_file="examples/gcp/cloud-dns/backend.tf" ;;
                    "database") backend_file="examples/gcp/cloud-sql/backend.tf" ;;
                    "valkey") backend_file="examples/gcp/valkey/backend.tf" ;;
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

# Function to deploy a component with timing
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
                "valkey") component_path="examples/aws/valkey" ;;
                "rabbitmq") component_path="examples/aws/amazonmq" ;;
                "mongodb") component_path="examples/aws/documentdb" ;;
                "kubernetes") component_path="examples/aws/eks" ;;
            esac
            ;;
        "azure")
            case $component in
                "network") component_path="examples/azure/network" ;;
                "dns") component_path="examples/azure/dns" ;;
                "database") component_path="examples/azure/database" ;;
                "valkey") component_path="examples/azure/redis" ;;
                "kubernetes") component_path="examples/azure/aks" ;;
                "mongodb") component_path="examples/azure/cosmosdb" ;;
            esac
            ;;
        "gcp")
            case $component in
                "network") component_path="examples/gcp/vpc" ;;
                "dns") component_path="examples/gcp/cloud-dns" ;;
                "database") component_path="examples/gcp/cloud-sql" ;;
                "valkey") component_path="examples/gcp/valkey" ;;
                "kubernetes") component_path="examples/gcp/gke" ;;
            esac
            ;;
    esac

    if [ -d "$component_path" ]; then
        print_message "$YELLOW" "\nDeploying $component in $provider..."
        cd "$component_path"

        start_time=$(date +%s)

        terraform init -input=false -no-color > /dev/null
        terraform plan -var-file="midaz.tfvars" -out=tfplan -input=false -no-color > /dev/null
        terraform apply -input=false -auto-approve -no-color tfplan > /dev/null

        end_time=$(date +%s)
        duration=$((end_time - start_time))s

        cd - > /dev/null
        print_table_row "$component" "Deploy" "Success" "$GREEN" "$duration"
    else
        print_message "$RED" "Component path $component_path not found!"
        exit 1
    fi
}

# Function to destroy a component with timing
destroy_component() {
    local provider=$1
    local component=$2
    local component_path=""

    case $provider in
        "aws")
            case $component in
                "network") component_path="examples/aws/vpc" ;;
                "dns") component_path="examples/aws/route53" ;;
                "database") component_path="examples/aws/rds" ;;
                "valkey") component_path="examples/aws/valkey" ;;
                "rabbitmq") component_path="examples/aws/amazonmq" ;;
                "mongodb") component_path="examples/aws/documentdb" ;;
                "kubernetes") component_path="examples/aws/eks" ;;
            esac
            ;;
        "azure")
            case $component in
                "network") component_path="examples/azure/network" ;;
                "dns") component_path="examples/azure/dns" ;;
                "database") component_path="examples/azure/database" ;;
                "valkey") component_path="examples/azure/redis" ;;
                "kubernetes") component_path="examples/azure/aks" ;;
                "mongodb") component_path="examples/azure/cosmosdb" ;;
            esac
            ;;
        "gcp")
            case $component in
                "network") component_path="examples/gcp/vpc" ;;
                "dns") component_path="examples/gcp/cloud-dns" ;;
                "database") component_path="examples/gcp/cloud-sql" ;;
                "valkey") component_path="examples/gcp/valkey" ;;
                "kubernetes") component_path="examples/gcp/gke" ;;
            esac
            ;;
    esac

    if [ -d "$component_path" ]; then
        print_message "$YELLOW" "\nDestroying $component in $provider..."
        cd "$component_path"

        start_time=$(date +%s)

        terraform init -input=false -no-color > /dev/null
        terraform destroy -var-file="midaz.tfvars" -auto-approve -input=false -no-color > /dev/null

        end_time=$(date +%s)
        duration=$((end_time - start_time))s

        cd - > /dev/null
        print_table_row "$component" "Destroy" "Success" "$RED" "$duration"
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

print_message "$YELLOW" "\nWhat do you want to do?"
print_message "$GREEN" "1) Deploy"
print_message "$RED" "2) Destroy (BE CAREFUL)"

read -p "Select an action (1-2): " action_choice

# Check for placeholders
print_message "$YELLOW" "\nChecking for placeholders in backend configurations..."
check_placeholders "$provider"

print_table_header

case $action_choice in
    1)
        components=("network" "dns" "database" "valkey" "kubernetes")
        if [ "$provider" = "aws" ]; then
            components=("network" "dns" "database" "valkey" "rabbitmq" "mongodb" "kubernetes")
        elif [ "$provider" = "azure" ]; then
            components=("network" "dns" "database" "valkey" "mongodb" "kubernetes" )
        fi
        for component in "${components[@]}"; do
            deploy_component "$provider" "$component"
        done
        ;;
    2)
        components=("kubernetes" "valkey" "database" "dns" "network")
        if [ "$provider" = "aws" ]; then
            components=("kubernetes" "mongodb" "rabbitmq" "valkey" "database" "dns" "network")
        elif [ "$provider" = "azure" ]; then
            components=("kubernetes" "mongodb" "valkey" "database" "dns" "network")
        fi
        for component in "${components[@]}"; do
            destroy_component "$provider" "$component"
        done
        ;;
    *)
        print_message "$RED" "Invalid action!"
        exit 1
        ;;
esac

print_message "$GREEN" "\nAll operations completed successfully!"