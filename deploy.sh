#!/bin/bash

set -e

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_table_header() {
    printf "\n%-15s %-10s %-20s %-10s\n" "Component" "Action" "Status" "Duration"
    printf "%-15s %-10s %-20s %-10s\n" "---------" "------" "------" "--------"
}

print_table_row() {
    local component=$1
    local action=$2
    local status=$3
    local color=$4
    local duration=$5
    printf "%-15s %-10s ${color}%-20s${NC} %-10s\n" "$component" "$action" "$status" "$duration"
}

check_placeholders() {
    local provider=$1
    local components=("network" "dns" "database" "valkey" "kubernetes" "mongodb" "rabbitmq")
    local has_placeholders=false

    for component in "${components[@]}"; do
        local backend_file=""
        case $component in
            "network") backend_file="examples/$provider/network/backend.tf" ;;
            "dns") backend_file="examples/$provider/dns/backend.tf" ;;
            "database") backend_file="examples/$provider/database/backend.tf" ;;
            "valkey") backend_file="examples/$provider/valkey/backend.tf" ;;
            "kubernetes") backend_file="examples/$provider/kubernetes/backend.tf" ;;
            "rabbitmq")
                [ "$provider" == "aws" ] && backend_file="examples/aws/rabbitmq/backend.tf"
                ;;
            "mongodb")
                case $provider in
                    "aws") backend_file="examples/aws/mongodb/backend.tf" ;;
                    "azure") backend_file="examples/azure/cosmosdb/backend.tf" ;;
                esac
                ;;
        esac

        if [ -n "$backend_file" ] && [ -f "$backend_file" ]; then
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

deploy_component() {
    local provider=$1
    local component=$2
    local component_path=""

    case $component in
        "network") component_path="examples/$provider/network" ;;
        "dns") component_path="examples/$provider/dns" ;;
        "database") component_path="examples/$provider/database" ;;
        "valkey") component_path="examples/$provider/valkey" ;;
        "kubernetes") component_path="examples/$provider/kubernetes" ;;
        "rabbitmq")
            [ "$provider" == "aws" ] && component_path="examples/aws/rabbitmq"
            ;;
        "mongodb")
            case $provider in
                "aws") component_path="examples/aws/mongodb" ;;
                "azure") component_path="examples/azure/cosmosdb" ;;
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

destroy_component() {
    local provider=$1
    local component=$2
    local component_path=""

    case $component in
        "network") component_path="examples/$provider/network" ;;
        "dns") component_path="examples/$provider/dns" ;;
        "database") component_path="examples/$provider/database" ;;
        "valkey") component_path="examples/$provider/valkey" ;;
        "kubernetes") component_path="examples/$provider/kubernetes" ;;
        "rabbitmq")
            [ "$provider" == "aws" ] && component_path="examples/aws/rabbitmq"
            ;;
        "mongodb")
            case $provider in
                "aws") component_path="examples/aws/mongodb" ;;
                "azure") component_path="examples/azure/cosmosdb" ;;
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

print_message "$YELLOW" "\nChecking for placeholders in backend configurations..."
check_placeholders "$provider"

print_table_header

case $action_choice in
    1)
        case $provider in
            "aws") components=("network" "dns" "database" "valkey" "kubernetes" "mongodb" "rabbitmq") ;;
            "azure") components=("network" "dns" "database" "valkey" "kubernetes" "mongodb") ;;
            "gcp") components=("network" "dns" "database" "valkey" "kubernetes") ;;
        esac

        for component in "${components[@]}"; do
            deploy_component "$provider" "$component"
        done
        ;;
    2)
        case $provider in
            "aws") components=("rabbitmq" "mongodb" "kubernetes" "valkey" "database" "dns" "network") ;;
            "azure") components=("mongodb" "kubernetes" "valkey" "database" "dns" "network") ;;
            "gcp") components=("kubernetes" "valkey" "database" "dns" "network") ;;
        esac

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
