#!/usr/bin/env bash
################################################################################
# deploy.sh — Lerian Terraform Foundation, AWS v2 layout
#
# Drives the environment-scoped stacks under examples/aws/:
#
#   bootstrap  ->  infra-base/vpc  ->  infra-base/eks
#              ->  [products/shared-resources/*]  ->  products/<product>/*
#
# GCP and Azure still use the pre-v2 flat layout and are served by
# ./deploy-legacy.sh, which this script points at. See "GCP / Azure" in --help.
#
# Written for bash 3.2 so it runs on a stock macOS /bin/bash as well as on Linux:
# no associative arrays, no `wait -n`, no `mapfile`, no `${var^^}`.
################################################################################

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AWS_DIR="$REPO_ROOT/examples/aws"
PRODUCTS_DIR="$AWS_DIR/products"
BACKEND_DIR="$AWS_DIR/backend"
CONFIG_FILE="$AWS_DIR/environments.conf"
CONFIG_EXAMPLE="$AWS_DIR/environments.conf.example"
LEGACY_SCRIPT="$REPO_ROOT/deploy-legacy.sh"

# Terraform state keys are derived from the directory, never hardcoded:
#   examples/aws/products/midaz/postgres -> aws/products/midaz/postgres/terraform.tfstate
STATE_KEY_PREFIX="aws"

################################################################################
# Output helpers
################################################################################

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi

# Progress goes to fd 1 normally. Actions whose stdout is a document the operator
# redirects to a file (helm-values) flip PROGRESS_FD to 2, so
# `> values.yaml` captures the document and nothing else.
PROGRESS_FD=1

info()  { printf '%s\n' "$*" >&"$PROGRESS_FD"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_OFF" "$C_BOLD" "$*" "$C_OFF" >&"$PROGRESS_FD"; }
ok()    { printf '%s  ok%s  %s\n' "$C_GREEN" "$C_OFF" "$*" >&"$PROGRESS_FD"; }
warn()  { printf '%swarn%s  %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&"$PROGRESS_FD"; }

# die <line> [<line> ...] — every error says what is wrong AND what to do.
die() {
    printf '\n%serror%s %s\n' "$C_RED" "$C_OFF" "$1" >&2
    shift
    while [ "$#" -gt 0 ]; do
        printf '      %s\n' "$1" >&2
        shift
    done
    printf '\n' >&2
    exit 1
}

################################################################################
# Usage
################################################################################

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_OFF} — deploy the AWS v2 stacks of lerian-terraform-foundation

${C_BOLD}USAGE${C_OFF}
  ./${SCRIPT_NAME} --env <dev|stg|prd> [--target <target>] [--action <action>] [options]

${C_BOLD}FLAGS${C_OFF}
  --env <dev|stg|prd>     REQUIRED. Which environment to operate on. Selects the
                          account from examples/aws/environments.conf, the backend
                          file examples/aws/backend/<env>.hcl, and the variables
                          file envs/<env>.tfvars inside every stack.

  --target <target>       What to operate on. Default: infra-base.
                            bootstrap                state bucket + lock table
                            infra-base               vpc then eks
                            infra-base/vpc           just the VPC
                            infra-base/eks           just the cluster
                            shared-resources         the whole shared datastore tier
                            shared-resources/<svc>   one shared datastore
                            <product>                every service of one product
                            <product>/<service>      one service
                            all                      everything, in order
                          Products and services are DISCOVERED from
                          examples/aws/products/*/*/main.tf. A new product works
                          here the moment its directory exists — nothing to edit.
                          Run --list to see what is currently discoverable.

  --action <action>       Default: plan.
                            plan          terraform plan only. Changes nothing.
                            apply         plan, show the summary, confirm, apply.
                            destroy       the same, for -destroy plans.
                            helm-values   read terraform output -json helm_values
                                          from every service of the target and
                                          merge them into one document.
                            output        terraform output for every unit.

  --auto-approve          Skip the single confirmation prompt before apply/destroy.
                          Terraform still applies a saved plan file, so what runs
                          is exactly what was shown.

  --jobs <n>              Services inside one product run in parallel. Default 4.
                          --jobs 1 runs sequentially and streams Terraform output
                          straight to the terminal. Ordered stages (bootstrap,
                          vpc, eks) are always sequential regardless of this.

  --format <json|yaml>    Output shape for --action helm-values. Default json.

  --dry-run               Resolve and print the execution plan — units, order,
                          state keys, backend file, profile, expected account —
                          then exit. Makes NO AWS call at all.

  --list                  List discoverable targets and exit. Makes no AWS call.

  --help                  This text.

${C_BOLD}THE FLOW${C_OFF}
  1.  One-off, per environment. Declare which AWS account each environment lives
      in. This is the guard rail, not paperwork:

        cp examples/aws/environments.conf.example examples/aws/environments.conf
        \$EDITOR examples/aws/environments.conf

      Single account? Point dev, stg and prd at the same account_id and profile —
      resource names carry the environment, so nothing collides, and state is
      still segregated by bucket. Separate accounts? One account_id per section.
      Before every run the script calls sts get-caller-identity and aborts if the
      live account is not the declared one. There is no bypass flag.

  2.  Create the state backend for the environment. bootstrap runs on LOCAL state
      with one Terraform workspace per environment; the script selects (or
      creates) the right workspace for you, which is what the stack's own
      precondition demands:

        ./${SCRIPT_NAME} --env dev --target bootstrap --action apply

      This writes examples/aws/backend/dev.hcl. Every later init consumes it.

  3.  Copy the variables files for the stacks you are about to run. *.tfvars is
      gitignored; *.tfvars-example is not:

        cp examples/aws/infra-base/vpc/envs/dev.tfvars-example \\
           examples/aws/infra-base/vpc/envs/dev.tfvars

      The script refuses to run a stack whose envs/<env>.tfvars is missing, or
      that still contains a <PUT-YOUR-...> placeholder.

  4.  Foundation, in order. vpc is a hard prerequisite for everything below it —
      every datastore resolves the VPC and its Type=database subnets by tag:

        ./${SCRIPT_NAME} --env dev --target infra-base --action apply

  5.  Optional shared datastore tier. Only needed by stacks running mode="shared":

        ./${SCRIPT_NAME} --env dev --target shared-resources --action apply

  6.  Products. Services inside a product have no dependency on each other —
      separate state, separate locks — so they run in parallel:

        ./${SCRIPT_NAME} --env dev --target midaz --action plan
        ./${SCRIPT_NAME} --env dev --target midaz --action apply

  7.  Collect the Helm handoff. A product's outputs now live in N state files,
      one per service; this merges them into one document:

        ./${SCRIPT_NAME} --env dev --target midaz --action helm-values --format yaml \\
          > midaz-dev-values.yaml

${C_BOLD}ORDER${C_OFF}
  apply    bootstrap -> infra-base/vpc -> infra-base/eks
                     -> shared-resources/* -> products/*
  destroy  the exact reverse.

  bootstrap is never destroyed by this script: the bucket and the lock table
  carry prevent_destroy = true and the destroy would fail anyway. See
  examples/aws/bootstrap/README.md, "Teardown".

${C_BOLD}WHY -reconfigure IS ALWAYS PASSED${C_OFF}
  .terraform/ caches the resolved backend, including the bucket of whichever
  environment was initialised last. Without -reconfigure, switching environments
  in the same checkout keeps the stale bucket and the run dies with a 403 at
  apply time — long after the plan looked fine. Every init here passes it.

${C_BOLD}GCP / AZURE${C_OFF}
  Not handled here. Those examples are still on the pre-v2 flat layout
  (midaz.tfvars, placeholders inside backend.tf, no environments) and share no
  mechanism with this script. They kept their original interactive flow:

        ./deploy-legacy.sh

${C_BOLD}EXAMPLES${C_OFF}
  ./${SCRIPT_NAME} --list
  ./${SCRIPT_NAME} --env dev --target all --dry-run
  ./${SCRIPT_NAME} --env dev --target bootstrap --action apply
  ./${SCRIPT_NAME} --env stg --target infra-base/vpc --action plan
  ./${SCRIPT_NAME} --env prd --target midaz --action apply --jobs 4
  ./${SCRIPT_NAME} --env dev --target midaz/postgres --action destroy
  ./${SCRIPT_NAME} --env dev --target reporter --action helm-values --format yaml
EOF
}

################################################################################
# Argument parsing
################################################################################

ENVIRONMENT=""
TARGET="infra-base"
ACTION="plan"
AUTO_APPROVE=false
JOBS=4
FORMAT="json"
DRY_RUN=false
LIST_ONLY=false

need_value() {
    # need_value <flag> <count-of-remaining-args>
    [ "$2" -ge 2 ] || die "$1 requires a value." "Run ./$SCRIPT_NAME --help."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env)           need_value "$1" "$#"; ENVIRONMENT="$2"; shift 2 ;;
        --env=*)         ENVIRONMENT="${1#*=}"; shift ;;
        --target)        need_value "$1" "$#"; TARGET="$2"; shift 2 ;;
        --target=*)      TARGET="${1#*=}"; shift ;;
        --action)        need_value "$1" "$#"; ACTION="$2"; shift 2 ;;
        --action=*)      ACTION="${1#*=}"; shift ;;
        --jobs)          need_value "$1" "$#"; JOBS="$2"; shift 2 ;;
        --jobs=*)        JOBS="${1#*=}"; shift ;;
        --format)        need_value "$1" "$#"; FORMAT="$2"; shift 2 ;;
        --format=*)      FORMAT="${1#*=}"; shift ;;
        --auto-approve)  AUTO_APPROVE=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --list)          LIST_ONLY=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        aws)
            die "This script no longer takes a provider as a positional argument." \
                "It is AWS-only now, and AWS needs an environment:" \
                "  ./$SCRIPT_NAME --env dev --target infra-base --action plan"
            ;;
        azure|gcp)
            die "'$1' is not handled by this script." \
                "The GCP and Azure examples are still on the pre-v2 flat layout" \
                "(midaz.tfvars, placeholders inside backend.tf, no environments) and" \
                "kept their original interactive flow:" \
                "" \
                "  $LEGACY_SCRIPT"
            ;;
        *)
            die "Unknown argument: $1" "Run ./$SCRIPT_NAME --help for the full flag list."
            ;;
    esac
done

################################################################################
# Discovery — products and services come from the filesystem, never from a list
################################################################################

# discover_service_dirs — every examples/aws/products/<product>/<service> that is
# a Terraform root (has main.tf), one absolute path per line, sorted.
#
# Depth 3 counts the file: products/<product>/<service>/main.tf. Pinning both
# bounds is what keeps _modules, .terraform and any future nesting out.
discover_service_dirs() {
    find "$PRODUCTS_DIR" -mindepth 3 -maxdepth 3 -name main.tf -not -path '*/.terraform/*' \
        -exec dirname {} \; 2>/dev/null | LC_ALL=C sort
}

# discover_products — product directory names, one per line, sorted.
discover_products() {
    discover_service_dirs | while IFS= read -r d; do
        basename "$(dirname "$d")"
    done | LC_ALL=C sort -u
}

# services_of <product> — absolute service dirs of one product, sorted.
services_of() {
    find "$PRODUCTS_DIR/$1" -mindepth 2 -maxdepth 2 -name main.tf -not -path '*/.terraform/*' \
        -exec dirname {} \; 2>/dev/null | LC_ALL=C sort
}

# rel_path  — path relative to examples/aws, used for stack identity and state keys.
# repo_rel  — path relative to the repository root, used in operator-facing messages
#             so a copy-pasted command works from where the operator actually is.
rel_path()  { printf '%s\n' "${1#"$AWS_DIR"/}"; }
repo_rel()  { printf '%s\n' "${1#"$REPO_ROOT"/}"; }
slug()      { rel_path "$1" | tr '/' '-'; }
state_key() { printf '%s/%s/terraform.tfstate\n' "$STATE_KEY_PREFIX" "$(rel_path "$1")"; }

list_targets() {
    info "${C_BOLD}Discovered targets${C_OFF}  (from $(repo_rel "$PRODUCTS_DIR")/*/*/main.tf)"
    info ""
    info "  bootstrap"
    info "  infra-base            infra-base/vpc  infra-base/eks"
    info "  all"
    info ""
    info "${C_BOLD}Products${C_OFF}"
    discover_products | while IFS= read -r p; do
        svcs=$(services_of "$p" | while IFS= read -r s; do basename "$s"; done | tr '\n' ' ')
        printf '  %-28s %s\n' "$p" "$svcs"
    done
}

if [ "$LIST_ONLY" = true ]; then
    list_targets
    exit 0
fi

################################################################################
# Flag validation (offline)
################################################################################

case "$ENVIRONMENT" in
    dev|stg|prd) ;;
    "")
        die "--env is required." \
            "One of: dev, stg, prd." \
            "It selects the AWS account (examples/aws/environments.conf), the state" \
            "backend (examples/aws/backend/<env>.hcl) and the variables file" \
            "(envs/<env>.tfvars) inside every stack." \
            "Example: ./$SCRIPT_NAME --env dev --target infra-base --action plan"
        ;;
    *)
        die "Invalid --env: '$ENVIRONMENT'." \
            "Valid values: dev, stg, prd." \
            "These three are fixed: envs/<env>.tfvars, backend/<env>.hcl and the" \
            "bootstrap workspace all key off exactly these names, and every stack's" \
            "'environment' variable validates against the same list."
        ;;
esac

case "$ACTION" in
    plan|apply|destroy|helm-values|output) ;;
    *)
        die "Invalid --action: '$ACTION'." \
            "Valid values: plan, apply, destroy, helm-values, output." \
            "Default is plan. Nothing is applied unless you ask for it."
        ;;
esac

case "$FORMAT" in
    json|yaml) ;;
    *) die "Invalid --format: '$FORMAT'." "Valid values: json, yaml." ;;
esac

# helm-values writes a document to stdout; keep progress out of it.
[ "$ACTION" = "helm-values" ] && PROGRESS_FD=2

case "$JOBS" in
    ''|*[!0-9]*) die "Invalid --jobs: '$JOBS'." "Must be a positive integer. Default 4; use 1 to run sequentially." ;;
esac
[ "$JOBS" -ge 1 ] || die "Invalid --jobs: '$JOBS'." "Must be at least 1."

################################################################################
# Target resolution -> ordered stages
#
# STAGE_DIRS[i] holds one stage: a space-separated list of absolute Terraform
# root directories that may run in parallel with each other.
# STAGE_NAME[i] is what that stage is called in the output.
# Stages themselves always run in order.
################################################################################

STAGE_NAME=()
STAGE_DIRS=()

add_stage() {
    # add_stage <name> <dir> [<dir> ...]
    local name="$1"; shift
    [ "$#" -gt 0 ] || return 0
    STAGE_NAME[${#STAGE_NAME[@]}]="$name"
    STAGE_DIRS[${#STAGE_DIRS[@]}]="$*"
}

add_product_stage() {
    # add_product_stage <product>
    local product="$1" dirs
    dirs=$(services_of "$product" | tr '\n' ' ')
    [ -n "${dirs// /}" ] || die "Product '$product' has no service directory with a main.tf." \
        "Looked in: $(rel_path "$PRODUCTS_DIR/$product")/*/main.tf" \
        "Run ./$SCRIPT_NAME --list to see what is discoverable."
    # shellcheck disable=SC2086 # intentional word splitting: dirs is a path list
    add_stage "$product" $dirs
}

BOOTSTRAP_DIR="$AWS_DIR/bootstrap"
VPC_DIR="$AWS_DIR/infra-base/vpc"
EKS_DIR="$AWS_DIR/infra-base/eks"

resolve_target() {
    local t="$1" product service

    case "$t" in
        all)
            add_stage "bootstrap" "$BOOTSTRAP_DIR"
            add_stage "infra-base/vpc" "$VPC_DIR"
            add_stage "infra-base/eks" "$EKS_DIR"
            if [ -d "$PRODUCTS_DIR/shared-resources" ]; then
                add_product_stage "shared-resources"
            fi
            discover_products | while IFS= read -r p; do
                [ "$p" = "shared-resources" ] || printf '%s\n' "$p"
            done > "$TMP_PRODUCT_LIST"
            while IFS= read -r p; do
                [ -n "$p" ] && add_product_stage "$p"
            done < "$TMP_PRODUCT_LIST"
            return 0
            ;;
        bootstrap)
            add_stage "bootstrap" "$BOOTSTRAP_DIR"
            return 0
            ;;
        infra-base)
            add_stage "infra-base/vpc" "$VPC_DIR"
            add_stage "infra-base/eks" "$EKS_DIR"
            return 0
            ;;
        infra-base/vpc)
            add_stage "infra-base/vpc" "$VPC_DIR"
            return 0
            ;;
        infra-base/eks)
            add_stage "infra-base/eks" "$EKS_DIR"
            return 0
            ;;
    esac

    product="${t%%/*}"
    service="${t#*/}"
    [ "$service" = "$t" ] && service=""

    if [ ! -d "$PRODUCTS_DIR/$product" ]; then
        die "Unknown --target: '$t'." \
            "'$product' is not a directory under $(repo_rel "$PRODUCTS_DIR")/." \
            "Valid non-product targets: bootstrap, infra-base, infra-base/vpc," \
            "infra-base/eks, all." \
            "Run ./$SCRIPT_NAME --list for every discoverable product and service."
    fi

    if [ -n "$service" ]; then
        if [ ! -f "$PRODUCTS_DIR/$product/$service/main.tf" ]; then
            die "Unknown --target: '$t'." \
                "'$product' exists but has no service '$service'." \
                "Available services: $(services_of "$product" | while IFS= read -r s; do basename "$s"; done | tr '\n' ' ')" \
                "Run ./$SCRIPT_NAME --list."
        fi
        add_stage "$t" "$PRODUCTS_DIR/$product/$service"
        return 0
    fi

    add_product_stage "$product"
}

################################################################################
# Run directory
#
# Saved plans can contain values from state. 0700, plan files removed on exit,
# logs kept so a failure can be read after the run.
################################################################################

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lerian-deploy.XXXXXX")
chmod 700 "$RUN_DIR"
TMP_PRODUCT_LIST="$RUN_DIR/products.list"

# shellcheck disable=SC2329 # invoked through the EXIT trap below
cleanup() {
    rm -f "$RUN_DIR"/*.tfplan 2>/dev/null || true
}
trap cleanup EXIT

################################################################################
# environments.conf
################################################################################

# conf_get <section> <key> — value or empty. Comments and whitespace stripped.
conf_get() {
    awk -v section="$1" -v key="$2" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ {
            s = $0
            sub(/^[[:space:]]*\[/, "", s)
            sub(/\].*$/, "", s)
            gsub(/[[:space:]]/, "", s)
            cur = s
            next
        }
        cur == section && index($0, "=") > 0 {
            k = substr($0, 1, index($0, "=") - 1)
            v = substr($0, index($0, "=") + 1)
            sub(/#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$CONFIG_FILE"
}

conf_has_section() {
    awk -v section="$1" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ {
            s = $0
            sub(/^[[:space:]]*\[/, "", s)
            sub(/\].*$/, "", s)
            gsub(/[[:space:]]/, "", s)
            if (s == section) { found = 1 }
        }
        END { exit(found ? 0 : 1) }
    ' "$CONFIG_FILE"
}

load_environment_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Missing $(repo_rel "$CONFIG_FILE")." \
            "This file maps each environment to the AWS account it is allowed to" \
            "touch. Without it the script cannot verify that '--env $ENVIRONMENT'" \
            "is pointing at the right account, so it will not run." \
            "" \
            "  cp $(repo_rel "$CONFIG_EXAMPLE") $(repo_rel "$CONFIG_FILE")" \
            "  \$EDITOR $(repo_rel "$CONFIG_FILE")" \
            "" \
            "Single AWS account for all three environments? Give dev, stg and prd" \
            "the same account_id and profile — that is a supported configuration."
    fi

    if ! conf_has_section "$ENVIRONMENT"; then
        die "No [$ENVIRONMENT] section in $(repo_rel "$CONFIG_FILE")." \
            "Add one:" \
            "" \
            "  [$ENVIRONMENT]" \
            "  account_id = 123456789012" \
            "  profile    = your-aws-profile" \
            "  region     = us-east-2" \
            "" \
            "profile may be left empty to use ambient credentials (CI, IRSA)."
    fi

    ACCOUNT_ID=$(conf_get "$ENVIRONMENT" account_id)
    AWS_REGION_CONF=$(conf_get "$ENVIRONMENT" region)
    AWS_PROFILE_CONF=$(conf_get "$ENVIRONMENT" profile)

    if [ -z "$ACCOUNT_ID" ]; then
        die "[$ENVIRONMENT] in $(repo_rel "$CONFIG_FILE") has no account_id." \
            "account_id is the whole point of this file: it is the account the" \
            "credentials MUST resolve to before anything runs." \
            "Find it with:  aws sts get-caller-identity --query Account --output text"
    fi

    case "$ACCOUNT_ID" in
        *[!0-9]*)
            die "Invalid account_id for [$ENVIRONMENT]: '$ACCOUNT_ID'." \
                "An AWS account id is exactly 12 digits, no dashes and no quotes."
            ;;
    esac

    [ "${#ACCOUNT_ID}" -eq 12 ] || die \
        "Invalid account_id for [$ENVIRONMENT]: '$ACCOUNT_ID' (${#ACCOUNT_ID} digits)." \
        "An AWS account id is exactly 12 digits."

    [ -n "$AWS_REGION_CONF" ] || die \
        "[$ENVIRONMENT] in $(repo_rel "$CONFIG_FILE") has no region." \
        "Add:  region = us-east-2" \
        "It is cross-checked against the region in backend/$ENVIRONMENT.hcl."

    if [ "$AWS_PROFILE_CONF" = "-" ]; then
        AWS_PROFILE_CONF=""
    fi
}

################################################################################
# Preflight — everything that can fail offline, fails offline
################################################################################

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1" "$2"
}

check_tools() {
    require_tool terraform "Install it: https://developer.hashicorp.com/terraform/install"
    require_tool aws "Install the AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    require_tool jq "Install jq — it parses terraform output and the plan summaries. brew install jq | apt-get install jq"
}

# backend/<env>.hcl must exist for every stack except bootstrap, which creates it.
BACKEND_FILE=""
check_backend_file() {
    BACKEND_FILE="$BACKEND_DIR/$ENVIRONMENT.hcl"

    if [ ! -f "$BACKEND_FILE" ]; then
        die "Missing $(repo_rel "$BACKEND_FILE")." \
            "Every stack except bootstrap initialises its S3 backend from this file," \
            "and it is generated by the bootstrap stack, not committed (it carries the" \
            "AWS account id)." \
            "" \
            "  ./$SCRIPT_NAME --env $ENVIRONMENT --target bootstrap --action apply" \
            "" \
            "If the bucket already exists but the file does not (fresh clone, another" \
            "operator ran the bootstrap), write it by hand — see" \
            "$(repo_rel "$BACKEND_DIR")/README.md."
    fi

    local bucket region
    bucket=$(awk -F'=' '/^[[:space:]]*bucket[[:space:]]*=/ {gsub(/[" \t]/,"",$2); print $2; exit}' "$BACKEND_FILE")
    region=$(awk -F'=' '/^[[:space:]]*region[[:space:]]*=/ {gsub(/[" \t]/,"",$2); print $2; exit}' "$BACKEND_FILE")

    [ -n "$bucket" ] || die "$(repo_rel "$BACKEND_FILE") has no 'bucket' line." \
        "It should look like:" \
        "  bucket         = \"lerian-tfstate-$ENVIRONMENT-$ACCOUNT_ID\"" \
        "  region         = \"$AWS_REGION_CONF\"" \
        "  dynamodb_table = \"lerian-tfstate-lock-$ENVIRONMENT\"" \
        "  encrypt        = true"

    # Offline account guard #1. bootstrap names the bucket
    # lerian-tfstate-<env>-<account_id>, so the backend file already carries the
    # account. A mismatch here means the file belongs to another account and the
    # init would have failed with a 403 much later.
    case "$bucket" in
        *-"$ACCOUNT_ID")
            ;;
        *)
            die "Account mismatch between $(repo_rel "$CONFIG_FILE") and $(repo_rel "$BACKEND_FILE")." \
                "  [$ENVIRONMENT] account_id declares : $ACCOUNT_ID" \
                "  the backend bucket says     : $bucket" \
                "" \
                "The bucket is named lerian-tfstate-<env>-<account_id>, so these two" \
                "disagree about which account '$ENVIRONMENT' lives in. One of them is" \
                "stale. Fix the config, or re-run bootstrap for this environment to" \
                "regenerate the backend file."
            ;;
    esac

    case "$bucket" in
        *"-$ENVIRONMENT-"*) ;;
        *)
            warn "backend bucket '$bucket' does not contain '-$ENVIRONMENT-'. Expected lerian-tfstate-$ENVIRONMENT-$ACCOUNT_ID."
            ;;
    esac

    if [ -n "$region" ] && [ "$region" != "$AWS_REGION_CONF" ]; then
        die "Region mismatch between $(repo_rel "$CONFIG_FILE") and $(repo_rel "$BACKEND_FILE")." \
            "  [$ENVIRONMENT] region declares : $AWS_REGION_CONF" \
            "  the backend file says   : $region" \
            "" \
            "State for this environment lives in '$region'. Either the config is wrong" \
            "or the environment was bootstrapped in a different region."
    fi

    BACKEND_BUCKET="$bucket"
}

# Placeholder / tfvars check, per unit. This is the check that used to be dead
# code: it was guarded by [ -f "$backend_file" ] against paths that no longer
# existed, so it always passed without inspecting anything.
PLACEHOLDER_RE='<(PUT-YOUR|YOUR|SEU|seu|CHANGE-ME|CHANGEME|REPLACE)[^>]*>|<[A-Z][A-Z0-9_-]{3,}>'

# tfvars_problem <dir> — one-line reason the stack is not runnable, empty if it is.
tfvars_problem() {
    local dir="$1" tfvars bad
    tfvars="$dir/envs/$ENVIRONMENT.tfvars"

    if [ ! -f "$tfvars" ]; then
        if [ -f "$dir/envs/$ENVIRONMENT.tfvars-example" ]; then
            printf 'missing envs/%s.tfvars (template available)\n' "$ENVIRONMENT"
        else
            printf 'missing envs/%s.tfvars and no %s.tfvars-example\n' "$ENVIRONMENT" "$ENVIRONMENT"
        fi
        return 0
    fi

    # Comment lines are stripped first: the committed templates legitimately write
    # things like "<that address>" in prose, and a real tfvars keeps those comments.
    bad=$(grep -vE '^[[:space:]]*#' "$tfvars" | grep -cE "$PLACEHOLDER_RE" || true)
    if [ "$bad" -gt 0 ]; then
        printf 'unresolved placeholder(s) on %s line(s) of envs/%s.tfvars\n' "$bad" "$ENVIRONMENT"
    fi
}

check_tfvars() {
    local dir="$1" tfvars example rel bad
    tfvars="$dir/envs/$ENVIRONMENT.tfvars"
    example="$dir/envs/$ENVIRONMENT.tfvars-example"
    rel=$(rel_path "$dir")

    if [ ! -f "$tfvars" ]; then
        if [ -f "$example" ]; then
            die "Missing $rel/envs/$ENVIRONMENT.tfvars" \
                "*.tfvars is gitignored; *.tfvars-example is the committed template." \
                "" \
                "  cp $(repo_rel "$example") \\" \
                "     $(repo_rel "$tfvars")" \
                "  \$EDITOR $(repo_rel "$tfvars")" \
                "" \
                "Run with --dry-run to list every stack of this target that is not ready" \
                "yet, instead of stopping at the first one."
        fi
        die "Missing $rel/envs/$ENVIRONMENT.tfvars" \
            "There is no $ENVIRONMENT.tfvars-example in $rel/envs/ either — this stack" \
            "may not support the '$ENVIRONMENT' environment yet." \
            "Present: $(find "$dir/envs" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
    fi

    bad=$(grep -vE '^[[:space:]]*#' "$tfvars" | grep -nE "$PLACEHOLDER_RE" || true)
    if [ -n "$bad" ]; then
        die "Unresolved placeholders in $rel/envs/$ENVIRONMENT.tfvars" \
            "$bad" \
            "" \
            "Replace every <...> token with a real value before deploying."
    fi
}

# Online account guard. The one that matters.
verify_aws_account() {
    local live_account live_arn out

    step "Verifying AWS identity for '$ENVIRONMENT'"
    dim "  profile     ${AWS_PROFILE_CONF:-<ambient credentials>}"
    dim "  region      $AWS_REGION_CONF"
    dim "  expects     $ACCOUNT_ID"

    if [ -n "$AWS_PROFILE_CONF" ]; then
        export AWS_PROFILE="$AWS_PROFILE_CONF"
    fi

    if ! out=$(aws sts get-caller-identity \
                   --region "$AWS_REGION_CONF" \
                   --query '[Account,Arn]' --output text 2>&1); then
        die "aws sts get-caller-identity failed for environment '$ENVIRONMENT'." \
            "$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | head -5)" \
            "" \
            "profile: ${AWS_PROFILE_CONF:-<ambient credentials>}" \
            "If this is an SSO profile the session has probably expired:" \
            "  aws sso login --profile ${AWS_PROFILE_CONF:-<profile>}"
    fi

    live_account=$(printf '%s' "$out" | awk '{print $1}')
    live_arn=$(printf '%s' "$out" | awk '{print $2}')

    if [ "$live_account" != "$ACCOUNT_ID" ]; then
        die "WRONG AWS ACCOUNT — refusing to touch '$ENVIRONMENT'." \
            "  environments.conf declares [$ENVIRONMENT] : $ACCOUNT_ID" \
            "  active credentials resolve to             : $live_account" \
            "  identity                                  : $live_arn" \
            "  profile                                   : ${AWS_PROFILE_CONF:-<ambient credentials>}" \
            "" \
            "Nothing has been planned, applied or destroyed." \
            "" \
            "Either the profile for [$ENVIRONMENT] is wrong in" \
            "$(repo_rel "$CONFIG_FILE"), or AWS_PROFILE / AWS_ACCESS_KEY_ID in this" \
            "shell is overriding it. There is no flag to skip this check: applying" \
            "one environment into another environment's account is the failure this" \
            "script exists to prevent."
    fi

    ok "account $live_account  ($live_arn)"
}

################################################################################
# Terraform execution
################################################################################

is_bootstrap() { [ "$1" = "$BOOTSTRAP_DIR" ]; }

# tf_init <dir>
tf_init() {
    local dir="$1"

    if is_bootstrap "$dir"; then
        # bootstrap creates the backend, so it cannot use it: LOCAL state with one
        # workspace per environment. The stack's own precondition asserts
        # terraform.workspace == var.environment, so select it before anything else.
        terraform -chdir="$dir" init -input=false -no-color
        terraform -chdir="$dir" workspace select "$ENVIRONMENT" >/dev/null 2>&1 ||
            terraform -chdir="$dir" workspace new "$ENVIRONMENT"
        printf 'workspace: %s\n' "$(terraform -chdir="$dir" workspace show)"
        return 0
    fi

    # -reconfigure, always. .terraform/ caches the bucket of whichever environment
    # was initialised here last; without this the run dies with a 403 at apply
    # time, long after the plan looked healthy.
    terraform -chdir="$dir" init -reconfigure -input=false -no-color \
        -backend-config="$BACKEND_FILE" \
        -backend-config="key=$(state_key "$dir")"
}

# tf_plan <dir> <plan-file> <destroy:true|false>
tf_plan() {
    local dir="$1" planfile="$2" destroy="$3"
    local args="-input=false -no-color -detailed-exitcode"
    local rc=0

    if [ "$destroy" = true ]; then
        # shellcheck disable=SC2086
        terraform -chdir="$dir" plan $args -destroy \
            -var-file="$dir/envs/$ENVIRONMENT.tfvars" -out="$planfile" || rc=$?
    else
        # shellcheck disable=SC2086
        terraform -chdir="$dir" plan $args \
            -var-file="$dir/envs/$ENVIRONMENT.tfvars" -out="$planfile" || rc=$?
    fi

    # -detailed-exitcode: 0 = no changes, 2 = changes present, 1 = error.
    if [ "$rc" -eq 1 ]; then
        return 1
    fi
    return 0
}

# tf_apply <dir> <plan-file>
tf_apply() {
    terraform -chdir="$1" apply -input=false -no-color "$2"
}

# plan_counts <plan-file> -> "create update delete"
plan_counts() {
    local dir="$1" planfile="$2"
    terraform -chdir="$dir" show -json "$planfile" 2>/dev/null | jq -r '
        [.resource_changes[]? | .change.actions] as $a
        | [ ($a | map(select(index("create"))) | length),
            ($a | map(select(index("update"))) | length),
            ($a | map(select(index("delete"))) | length) ]
        | @tsv
    ' 2>/dev/null || printf '?\t?\t?\n'
}

################################################################################
# Stage runner
################################################################################

RESULT_LINES=()

record() {
    RESULT_LINES[${#RESULT_LINES[@]}]="$1"
}

# run_units <phase> <dir...> — phase is "plan" or "apply".
# Runs the units with at most $JOBS in flight. Writes <slug>.log and <slug>.rc
# into RUN_DIR. Returns non-zero if any unit failed.
run_units() {
    local phase="$1"; shift
    local dirs=("$@")
    local d s log rc start elapsed running failures=0

    for d in "${dirs[@]}"; do
        s=$(slug "$d")
        log="$RUN_DIR/$s.$phase.log"

        if [ "$JOBS" -eq 1 ] || [ "${#dirs[@]}" -eq 1 ]; then
            start=$(date +%s)
            printf '\n%s--- %s [%s]%s\n' "$C_DIM" "$(rel_path "$d")" "$phase" "$C_OFF"
            set +e
            unit_work "$phase" "$d" 2>&1 | tee "$log"
            rc=${PIPESTATUS[0]}
            set -e
            elapsed=$(( $(date +%s) - start ))
            printf '%s\n' "$rc" > "$RUN_DIR/$s.$phase.rc"
            printf '%s\n' "$elapsed" > "$RUN_DIR/$s.$phase.time"
            [ "$rc" -eq 0 ] || failures=$((failures + 1))
        else
            while :; do
                running=$(jobs -pr | wc -l | tr -d ' ')
                [ "$running" -lt "$JOBS" ] && break
                sleep 1
            done
            printf '  %s…%s %s\n' "$C_DIM" "$C_OFF" "$(rel_path "$d")"
            (
                start=$(date +%s)
                set +e
                unit_work "$phase" "$d" > "$log" 2>&1
                rc=$?
                set -e
                printf '%s\n' "$rc" > "$RUN_DIR/$s.$phase.rc"
                printf '%s\n' "$(( $(date +%s) - start ))" > "$RUN_DIR/$s.$phase.time"
            ) &
        fi
    done

    wait || true

    if [ "$JOBS" -gt 1 ] && [ "${#dirs[@]}" -gt 1 ]; then
        for d in "${dirs[@]}"; do
            s=$(slug "$d")
            rc=$(cat "$RUN_DIR/$s.$phase.rc" 2>/dev/null || echo 1)
            [ "$rc" -eq 0 ] || failures=$((failures + 1))
        done
    fi

    return "$failures"
}

# unit_work <phase> <dir> — the actual Terraform calls for one root.
unit_work() {
    local phase="$1" dir="$2" s planfile
    s=$(slug "$dir")
    planfile="$RUN_DIR/$s.tfplan"

    case "$phase" in
        plan)
            tf_init "$dir"
            case "$ACTION" in
                destroy) tf_plan "$dir" "$planfile" true ;;
                *)       tf_plan "$dir" "$planfile" false ;;
            esac
            ;;
        apply)
            tf_apply "$dir" "$planfile"
            ;;
        output)
            tf_init "$dir"
            terraform -chdir="$dir" output -no-color
            ;;
        *)
            printf 'unknown phase: %s\n' "$phase" >&2
            return 1
            ;;
    esac
}

report_failures() {
    local phase="$1"; shift
    local dirs=("$@")
    local d s rc

    for d in "${dirs[@]}"; do
        s=$(slug "$d")
        rc=$(cat "$RUN_DIR/$s.$phase.rc" 2>/dev/null || echo 1)
        if [ "$rc" -ne 0 ]; then
            printf '\n%s---- %s failed (%s), last 40 lines ----%s\n' \
                "$C_RED" "$(rel_path "$d")" "$phase" "$C_OFF" >&2
            tail -40 "$RUN_DIR/$s.$phase.log" >&2 2>/dev/null || true
        fi
    done
}

print_plan_table() {
    local dirs=("$@")
    local d s rc counts c u del t

    printf '\n%-42s %8s %8s %8s %8s %8s\n' "STACK" "STATUS" "CREATE" "UPDATE" "DELETE" "TIME"
    printf '%-42s %8s %8s %8s %8s %8s\n' \
        "------------------------------------------" "--------" "--------" "--------" "--------" "--------"

    for d in "${dirs[@]}"; do
        s=$(slug "$d")
        rc=$(cat "$RUN_DIR/$s.plan.rc" 2>/dev/null || echo 1)
        t="$(cat "$RUN_DIR/$s.plan.time" 2>/dev/null || echo '?')s"
        if [ "$rc" -ne 0 ]; then
            printf '%-42s %s%8s%s %8s %8s %8s %8s\n' \
                "$(rel_path "$d")" "$C_RED" "FAILED" "$C_OFF" "-" "-" "-" "$t"
            continue
        fi
        counts=$(plan_counts "$d" "$RUN_DIR/$s.tfplan")
        c=$(printf '%s' "$counts" | cut -f1)
        u=$(printf '%s' "$counts" | cut -f2)
        del=$(printf '%s' "$counts" | cut -f3)
        printf '%-42s %s%8s%s %8s %8s %8s %8s\n' \
            "$(rel_path "$d")" "$C_GREEN" "ok" "$C_OFF" "$c" "$u" "$del" "$t"
    done
    printf '\n'
}

confirm() {
    local prompt="$1" reply
    [ "$AUTO_APPROVE" = true ] && return 0
    if [ ! -t 0 ]; then
        die "This run needs a confirmation but stdin is not a terminal." \
            "Pending: $prompt" \
            "" \
            "Re-run from a terminal, or pass --auto-approve. The plan above is what" \
            "would be applied — --auto-approve does not re-plan, it applies exactly" \
            "the saved plan files that produced that table."
    fi
    printf '%s%s%s [type yes to continue]: ' "$C_YELLOW" "$prompt" "$C_OFF"
    read -r reply
    [ "$reply" = "yes" ]
}

################################################################################
# helm-values aggregation
#
# One product's outputs now live in N state files, one per service. This reads
# `terraform output -json helm_values` (and helm_secret_values where it exists)
# from each and deep-merges them.
#
# Two shapes exist in the repository and both are handled by the same merge:
#   flat    { "DB_HOST": "...", "DB_PORT": "5432" }             most products
#   nested  { "pix": { "MONGO_URI": "..." }, "inbound": {...} } plugin-br-pix-indirect-btg
# The nested one is keyed by CHART COMPONENT and each entry merges into that
# component's configmap block. A conflicting key is a hard error, never a silent
# last-one-wins: a chart pointed at the wrong host fails in production, not here.
################################################################################

# shellcheck disable=SC2016 # jq program: $acc/$new/$path are jq variables, not shell
JQ_DEEPMERGE='
def deepmerge($a; $b; $path):
  reduce ($b | keys_unsorted[]) as $k
    ($a;
      if ($a | has($k) | not) then .[$k] = $b[$k]
      elif (($a[$k] | type) == "object" and ($b[$k] | type) == "object")
        then .[$k] = deepmerge($a[$k]; $b[$k]; $path + [$k])
      elif ($a[$k] == $b[$k]) then .
      else error("CONFLICT at " + (($path + [$k]) | join(".")) + ": " + ($a[$k] | tostring) + " vs " + ($b[$k] | tostring))
      end);
deepmerge($acc; $new; [])
'

# shellcheck disable=SC2016 # jq program: $ind is a jq variable, not shell
JQ_TO_YAML='
# Keys that are plain identifiers stay bare; anything else is quoted. Values are
# ALWAYS double-quoted: every leaf here is a string destined for a ConfigMap, and
# an unquoted "5432" or "true" would reach Helm as an int or a bool.
def k: if test("^[A-Za-z_][A-Za-z0-9_.-]*$") then . else @json end;
def emit($ind):
  to_entries[]
  | if (.value | type) == "object"
    then ($ind + (.key | k) + ":"), (.value | emit($ind + "  "))
    else ($ind + (.key | k) + ": " + (.value | tostring | @json))
    end;
to_entries[]
| (.key | k) + ":", (.value | emit("  "))
'

collect_helm_values() {
    local dirs=("$@")
    local d s out acc_values acc_secrets which merged

    acc_values='{}'
    acc_secrets='{}'

    for d in "${dirs[@]}"; do
        s=$(slug "$d")
        printf '  reading %s\n' "$(rel_path "$d")" >&2
        if ! tf_init "$d" > "$RUN_DIR/$s.output.log" 2>&1; then
            die "terraform init failed for $(rel_path "$d")." \
                "Log: $RUN_DIR/$s.output.log"
        fi

        for which in helm_values helm_secret_values; do
            if ! out=$(terraform -chdir="$d" output -json "$which" 2>/dev/null); then
                [ "$which" = "helm_values" ] &&
                    warn "$(rel_path "$d") exposes no '$which' output — skipped."
                continue
            fi
            [ -n "$out" ] && [ "$out" != "null" ] || continue

            if [ "$which" = "helm_values" ]; then
                if ! merged=$(jq -n --argjson acc "$acc_values" --argjson new "$out" "$JQ_DEEPMERGE" 2>&1); then
                    merged=$(printf '%s' "$merged" | sed 's/^jq: error ([^)]*): //')
                    die "helm_values from $(rel_path "$d") conflicts with a sibling service." \
                        "$merged" \
                        "" \
                        "Two services of this product emit the same chart key with different" \
                        "values. Merging them silently would point the release at one of the" \
                        "two at random. Fix the outputs, or aggregate the services separately."
                fi
                acc_values="$merged"
            else
                if ! merged=$(jq -n --argjson acc "$acc_secrets" --argjson new "$out" "$JQ_DEEPMERGE" 2>&1); then
                    merged=$(printf '%s' "$merged" | sed 's/^jq: error ([^)]*): //')
                    die "helm_secret_values from $(rel_path "$d") conflicts with a sibling service." \
                        "$merged"
                fi
                acc_secrets="$merged"
            fi
        done
    done

    merged=$(jq -n --argjson v "$acc_values" --argjson s "$acc_secrets" '
        if ($s | length) > 0
        then { helm_values: $v, helm_secret_values: $s }
        else { helm_values: $v }
        end')

    if [ "$FORMAT" = "yaml" ]; then
        printf '%s\n' "$merged" | jq -r "$JQ_TO_YAML"
    else
        printf '%s\n' "$merged" | jq .
    fi
}

################################################################################
# Main
################################################################################

check_tools

# Target resolution is pure filesystem work and reports the most common typo, so
# it runs before the config is even opened: "unknown product 'ledger'" is a more
# useful first error than "environments.conf is missing".
resolve_target "$TARGET"
load_environment_config

[ "${#STAGE_DIRS[@]}" -gt 0 ] || die "Target '$TARGET' resolved to no Terraform root." \
    "Run ./$SCRIPT_NAME --list."

# Collect every unit, in order, for the preflight and the dry-run print.
ALL_DIRS=()
STAGE_HAS_BOOTSTRAP=false
STAGE_HAS_NON_BOOTSTRAP=false
i=0
while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
    for d in ${STAGE_DIRS[$i]}; do
        ALL_DIRS[${#ALL_DIRS[@]}]="$d"
        if is_bootstrap "$d"; then
            STAGE_HAS_BOOTSTRAP=true
        else
            STAGE_HAS_NON_BOOTSTRAP=true
        fi
    done
    i=$((i + 1))
done

# destroy + bootstrap: refuse rather than run a doomed terraform destroy.
if [ "$ACTION" = "destroy" ] && [ "$STAGE_HAS_BOOTSTRAP" = true ]; then
    if [ "$TARGET" = "bootstrap" ]; then
        die "bootstrap cannot be destroyed by this script." \
            "aws_s3_bucket.tfstate and aws_dynamodb_table.tfstate_lock carry" \
            "prevent_destroy = true, so 'terraform destroy' fails by design — losing" \
            "state means Terraform no longer knows what it owns." \
            "" \
            "To tear down a validation environment on purpose, follow" \
            "$(repo_rel "$BOOTSTRAP_DIR")/README.md, section \"Teardown\", Option A:" \
            "detach the two resources with 'terraform state rm', then delete the" \
            "bucket and the table with the AWS CLI."
    fi
    warn "skipping bootstrap in the destroy plan (prevent_destroy; see examples/aws/bootstrap/README.md)."
    NEW_NAME=(); NEW_DIRS=()
    i=0
    while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
        if [ "${STAGE_DIRS[$i]}" != "$BOOTSTRAP_DIR" ]; then
            NEW_NAME[${#NEW_NAME[@]}]="${STAGE_NAME[$i]}"
            NEW_DIRS[${#NEW_DIRS[@]}]="${STAGE_DIRS[$i]}"
        fi
        i=$((i + 1))
    done
    STAGE_NAME=(${NEW_NAME[@]+"${NEW_NAME[@]}"})
    STAGE_DIRS=(${NEW_DIRS[@]+"${NEW_DIRS[@]}"})
    ALL_DIRS=()
    i=0
    while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
        for d in ${STAGE_DIRS[$i]}; do ALL_DIRS[${#ALL_DIRS[@]}]="$d"; done
        i=$((i + 1))
    done
    STAGE_HAS_BOOTSTRAP=false
fi

# Destroy walks the dependency graph backwards.
if [ "$ACTION" = "destroy" ]; then
    REV_NAME=(); REV_DIRS=()
    i=$(( ${#STAGE_DIRS[@]} - 1 ))
    while [ "$i" -ge 0 ]; do
        REV_NAME[${#REV_NAME[@]}]="${STAGE_NAME[$i]}"
        REV_DIRS[${#REV_DIRS[@]}]="${STAGE_DIRS[$i]}"
        i=$((i - 1))
    done
    STAGE_NAME=(${REV_NAME[@]+"${REV_NAME[@]}"})
    STAGE_DIRS=(${REV_DIRS[@]+"${REV_DIRS[@]}"})
fi

# Backend file is required by everything except a bootstrap-only run. --dry-run
# reports its absence instead of stopping: the point of a dry run is to see the
# whole picture, including what is not ready yet.
BACKEND_BUCKET="(not needed — bootstrap creates it)"
if [ "$STAGE_HAS_NON_BOOTSTRAP" = true ]; then
    if [ "$DRY_RUN" = true ] && [ ! -f "$BACKEND_DIR/$ENVIRONMENT.hcl" ]; then
        BACKEND_FILE="$BACKEND_DIR/$ENVIRONMENT.hcl"
        BACKEND_BUCKET="MISSING — run --target bootstrap --action apply first"
    else
        check_backend_file
    fi
fi

step "Preflight"
dim "  environment $ENVIRONMENT"
dim "  account     $ACCOUNT_ID  (declared in $(repo_rel "$CONFIG_FILE"))"
dim "  profile     ${AWS_PROFILE_CONF:-<ambient credentials>}"
dim "  region      $AWS_REGION_CONF"
dim "  backend     $BACKEND_BUCKET"
dim "  target      $TARGET"
dim "  action      $ACTION"
dim "  run dir     $RUN_DIR"

NOT_READY=0
if [ "$ACTION" = "helm-values" ] || [ "$ACTION" = "output" ]; then
    # Read-only actions. They never pass -var-file, so envs/<env>.tfvars is
    # irrelevant to them and demanding it would block reading the outputs of a
    # stack somebody else applied.
    dim "  tfvars      not required for --action $ACTION"
elif [ "$DRY_RUN" = true ]; then
    : > "$RUN_DIR/readiness"
    for d in ${ALL_DIRS[@]+"${ALL_DIRS[@]}"}; do
        reason=$(tfvars_problem "$d")
        if [ -n "$reason" ]; then
            NOT_READY=$((NOT_READY + 1))
            printf '%s\t%s\n' "$d" "$reason" >> "$RUN_DIR/readiness"
        fi
    done
else
    for d in ${ALL_DIRS[@]+"${ALL_DIRS[@]}"}; do
        check_tfvars "$d"
    done
    ok "envs/$ENVIRONMENT.tfvars present and placeholder-free in ${#ALL_DIRS[@]} stack(s)"
fi

if [ "$DRY_RUN" = true ]; then
    step "Execution plan (dry run — no AWS call was made)"
    i=0
    while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
        printf '\n  stage %d: %s%s%s\n' "$((i + 1))" "$C_BOLD" "${STAGE_NAME[$i]}" "$C_OFF"
        n=0
        for d in ${STAGE_DIRS[$i]}; do n=$((n + 1)); done
        if [ "$n" -gt 1 ] && [ "$JOBS" -gt 1 ]; then
            printf '    (%d units, up to %d in parallel)\n' "$n" "$JOBS"
        fi
        for d in ${STAGE_DIRS[$i]}; do
            reason=$(grep -F "$d	" "$RUN_DIR/readiness" 2>/dev/null | cut -f2- || true)
            if is_bootstrap "$d"; then
                printf '      %-40s  local state, workspace=%s\n' "$(rel_path "$d")" "$ENVIRONMENT"
            else
                printf '      %-40s  %s\n' "$(rel_path "$d")" "$(state_key "$d")"
            fi
            [ -n "$reason" ] && printf '        %sNOT READY: %s%s\n' "$C_YELLOW" "$reason" "$C_OFF"
        done
        i=$((i + 1))
    done
    printf '\n'
    dim "  backend-config  ${BACKEND_FILE:-<none: bootstrap only>}"
    dim "  var-file        <stack>/envs/$ENVIRONMENT.tfvars"
    dim "  init flags      -reconfigure -input=false  (bootstrap: workspace select/new)"
    printf '\n'

    if [ "$NOT_READY" -gt 0 ]; then
        printf '  %s%d of %d stack(s) are NOT READY%s — see the NOT READY lines above.\n' \
            "$C_YELLOW" "$NOT_READY" "${#ALL_DIRS[@]}" "$C_OFF"
        printf '  A missing envs/%s.tfvars is copied from the *.tfvars-example next to it;\n' "$ENVIRONMENT"
        printf '  a placeholder is a <...> token that still needs a real value.\n\n'
        exit 1
    fi
    ok "all ${#ALL_DIRS[@]} stack(s) ready"
    printf '\n'
    exit 0
fi

verify_aws_account

case "$ACTION" in
    helm-values)
        case "$TARGET" in
            bootstrap|infra-base|infra-base/*|all)
                die "--action helm-values needs a product target." \
                    "'$TARGET' has no helm_values output; the Helm handoff lives in" \
                    "products/<product>/<service>." \
                    "Example: ./$SCRIPT_NAME --env $ENVIRONMENT --target midaz --action helm-values"
                ;;
        esac
        step "Aggregating helm_values for '$TARGET' ($ENVIRONMENT)"
        collect_helm_values ${ALL_DIRS[@]+"${ALL_DIRS[@]}"}
        exit 0
        ;;
    output)
        i=0
        while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
            for d in ${STAGE_DIRS[$i]}; do
                step "$(rel_path "$d")"
                tf_init "$d" >/dev/null
                terraform -chdir="$d" output -no-color || true
            done
            i=$((i + 1))
        done
        exit 0
        ;;
esac

################################################################################
# plan / apply / destroy
################################################################################

TOTAL_START=$(date +%s)

i=0
while [ "$i" -lt "${#STAGE_DIRS[@]}" ]; do
    stage_name="${STAGE_NAME[$i]}"
    stage_dirs=()
    for d in ${STAGE_DIRS[$i]}; do stage_dirs[${#stage_dirs[@]}]="$d"; done

    if [ "$ACTION" = "destroy" ]; then
        step "Stage $((i + 1))/${#STAGE_DIRS[@]}: $stage_name — planning DESTROY"
    else
        step "Stage $((i + 1))/${#STAGE_DIRS[@]}: $stage_name — planning"
    fi

    if ! run_units plan "${stage_dirs[@]}"; then
        report_failures plan "${stage_dirs[@]}"
        print_plan_table "${stage_dirs[@]}"
        die "Plan failed in stage '$stage_name'." \
            "Nothing was applied. Full logs: $RUN_DIR" \
            "Later stages were not started."
    fi

    print_plan_table "${stage_dirs[@]}"

    if [ "$ACTION" = "plan" ]; then
        record "$stage_name|plan|ok"
        i=$((i + 1))
        continue
    fi

    verb="apply"
    [ "$ACTION" = "destroy" ] && verb="DESTROY"

    if ! confirm "$verb ${#stage_dirs[@]} stack(s) of '$stage_name' in $ENVIRONMENT (account $ACCOUNT_ID)?"; then
        die "Aborted by operator at stage '$stage_name'." \
            "Nothing was applied in this stage. Earlier stages, if any, already ran."
    fi

    step "Stage $((i + 1))/${#STAGE_DIRS[@]}: $stage_name — ${verb}ing saved plans"
    if ! run_units apply "${stage_dirs[@]}"; then
        report_failures apply "${stage_dirs[@]}"
        die "$verb failed in stage '$stage_name'." \
            "Full logs: $RUN_DIR" \
            "Later stages were not started. Re-run the same command once the cause is" \
            "fixed — Terraform is idempotent and will pick up where it stopped."
    fi

    for d in "${stage_dirs[@]}"; do
        s=$(slug "$d")
        t=$(cat "$RUN_DIR/$s.apply.time" 2>/dev/null || echo '?')
        ok "$(rel_path "$d")  (${t}s)"
    done
    record "$stage_name|$ACTION|ok"
    i=$((i + 1))
done

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))

step "Done"
for line in ${RESULT_LINES[@]+"${RESULT_LINES[@]}"}; do
    printf '  %s%s%s  %s\n' "$C_GREEN" "ok" "$C_OFF" "$(printf '%s' "$line" | tr '|' ' ')"
done
printf '\n  environment %s   account %s   elapsed %ss\n' "$ENVIRONMENT" "$ACCOUNT_ID" "$TOTAL_ELAPSED"
printf '  logs %s\n\n' "$RUN_DIR"

if [ "$ACTION" = "plan" ]; then
    dim "  Nothing was changed. Re-run with --action apply to execute this plan."
fi

exit 0
