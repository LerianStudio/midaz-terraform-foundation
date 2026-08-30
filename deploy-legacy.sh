#!/usr/bin/env bash
################################################################################
# deploy-legacy.sh — GCP and Azure, pre-v2 flat layout
#
# This is the original deploy.sh flow, unchanged in behaviour, carrying only the
# two providers that still use the layout it was written for:
#
#   examples/gcp/{vpc,cloud-dns,cloud-sql,valkey,gke}
#   examples/azure/{network,dns,database,redis,cosmosdb,aks}
#
# Each of those directories is a flat Terraform root with a committed backend.tf
# holding <PLACEHOLDER> values, a single midaz.tfvars, and no notion of an
# environment. Nothing here is environment-scoped and nothing here talks to
# examples/aws/backend/ or examples/aws/environments.conf.
#
# ---------------------------------------------------------------------------
# Why AWS is not in this file
# ---------------------------------------------------------------------------
# The nine pre-v2 AWS directories this script used to drive — examples/aws/vpc,
# route53, rds, valkey, amazonmq, documentdb, documentdb-plugin-fee,
# documentdb-plugin-crm and eks — were removed in v2. Every AWS path here was
# dead: it resolved to a directory that no longer exists.
#
# AWS moved to an environment-scoped, hierarchical layout with partial backend
# configuration, per-environment state buckets and an account guard. That shares
# no mechanism with the flow below, so it lives in its own script:
#
#   ./deploy.sh --env dev --target infra-base --action plan
#   ./deploy.sh --help
#
################################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

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

# component_path <provider> <component> — echoes the directory, empty if unknown.
component_path() {
    local provider=$1
    local component=$2

    case $provider in
        azure)
            case $component in
                network)    echo "examples/azure/network" ;;
                dns)        echo "examples/azure/dns" ;;
                database)   echo "examples/azure/database" ;;
                valkey)     echo "examples/azure/redis" ;;
                mongodb)    echo "examples/azure/cosmosdb" ;;
                kubernetes) echo "examples/azure/aks" ;;
            esac
            ;;
        gcp)
            case $component in
                network)    echo "examples/gcp/vpc" ;;
                dns)        echo "examples/gcp/cloud-dns" ;;
                database)   echo "examples/gcp/cloud-sql" ;;
                valkey)     echo "examples/gcp/valkey" ;;
                kubernetes) echo "examples/gcp/gke" ;;
            esac
            ;;
    esac
}

# Placeholder check. Unlike the AWS v2 script, these providers DO keep their
# backend configuration committed in backend.tf with <PLACEHOLDER> values, so
# grepping backend.tf is the right check here — and the files really exist, so
# it really runs.
check_placeholders() {
    local provider=$1
    shift
    local components=("$@")
    local has_placeholders=false
    local component backend_file

    for component in "${components[@]}"; do
        backend_file="$(component_path "$provider" "$component")/backend.tf"

        if [ ! -f "$backend_file" ]; then
            print_message "$RED" "Expected backend file not found: $backend_file"
            print_message "$RED" "The '$component' component of $provider is not where this script expects it."
            exit 1
        fi

        if grep -q "<.*>" "$backend_file"; then
            print_message "$RED" "Found placeholders in $backend_file"
            has_placeholders=true
        fi
    done

    if [ "$has_placeholders" = true ]; then
        print_message "$RED" "Please update all placeholders in the backend files before proceeding."
        exit 1
    fi
}

run_component() {
    local provider=$1
    local component=$2
    local mode=$3   # deploy | destroy
    local component_path
    local tfvars_file="midaz.tfvars"
    local start_time end_time duration

    component_path=$(component_path "$provider" "$component")

    if [ -z "$component_path" ] || [ ! -d "$component_path" ]; then
        print_message "$RED" "Component path for '$component' ($provider) not found!"
        exit 1
    fi

    if [ ! -f "$component_path/$tfvars_file" ]; then
        print_message "$RED" "Missing $component_path/$tfvars_file"
        print_message "$RED" "Copy the template first:  cp $component_path/$tfvars_file-example $component_path/$tfvars_file"
        exit 1
    fi

    start_time=$(date +%s)

    if [ "$mode" = "deploy" ]; then
        print_message "$YELLOW" "\nDeploying $component in $provider..."
        terraform -chdir="$component_path" init -input=false -no-color > /dev/null
        terraform -chdir="$component_path" plan -var-file="$tfvars_file" -out=tfplan -input=false -no-color > /dev/null
        terraform -chdir="$component_path" apply -input=false -auto-approve -no-color tfplan > /dev/null
    else
        print_message "$YELLOW" "\nDestroying $component in $provider..."
        terraform -chdir="$component_path" init -input=false -no-color > /dev/null
        terraform -chdir="$component_path" destroy -var-file="$tfvars_file" -auto-approve -input=false -no-color > /dev/null
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))s

    if [ "$mode" = "deploy" ]; then
        print_table_row "$component" "Deploy" "Success" "$GREEN" "$duration"
    else
        print_table_row "$component" "Destroy" "Success" "$RED" "$duration"
    fi
}

################################################################################
# Main
################################################################################

print_message "$GREEN" "Infrastructure Deployment Helper — legacy providers"
print_message "$YELLOW" "\nAvailable cloud providers:"
print_message "$NC" "1) Azure"
print_message "$NC" "2) GCP"
print_message "$NC" ""
print_message "$NC" "AWS is not here: it moved to the v2 layout. Use lerian-infra --help"

read -r -p "Select a cloud provider (1-2): " provider_choice

case $provider_choice in
    1) provider="azure" ;;
    2) provider="gcp" ;;
    *)
        print_message "$RED" "Invalid choice!"
        exit 1
        ;;
esac

print_message "$YELLOW" "\nWhat do you want to do?"
print_message "$GREEN" "1) Deploy"
print_message "$RED" "2) Destroy (BE CAREFUL)"

read -r -p "Select an action (1-2): " action_choice

if [ "$provider" = "azure" ]; then
    deploy_order=("network" "dns" "database" "valkey" "mongodb" "kubernetes")
else
    deploy_order=("network" "dns" "database" "valkey" "kubernetes")
fi

# Destroy is the reverse of deploy.
destroy_order=()
idx=$(( ${#deploy_order[@]} - 1 ))
while [ "$idx" -ge 0 ]; do
    destroy_order[${#destroy_order[@]}]="${deploy_order[$idx]}"
    idx=$((idx - 1))
done

print_message "$YELLOW" "\nChecking for placeholders in backend configurations..."
check_placeholders "$provider" "${deploy_order[@]}"

print_table_header

case $action_choice in
    1)
        for component in "${deploy_order[@]}"; do
            run_component "$provider" "$component" deploy
        done
        ;;
    2)
        for component in "${destroy_order[@]}"; do
            run_component "$provider" "$component" destroy
        done
        ;;
    *)
        print_message "$RED" "Invalid action!"
        exit 1
        ;;
esac

print_message "$GREEN" "\nAll operations completed successfully!"
