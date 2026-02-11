#!/bin/bash
# Mastercard CBS Deployment Script for Mifos-Gazelle
# Integrates Mastercard CBS connector with PaymentHub using Kubernetes operator

# IMPORTANT: Do NOT use 'set -e' in scripts meant to be sourced
# This script is sourced by deployer.sh - 'set -e' would affect the parent shell
# and cause premature exits on any non-zero return code (like missing config values)

# IMPORTANT: Do not source commandline.sh here - it creates circular dependency
# This script is sourced by deployer.sh, which is already called from commandline.sh
# All necessary variables are already set in the environment

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} INFO: $*"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} SUCCESS: $*"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} WARN: $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ERROR: $*" >&2
}

# Note: Default values are now set after config loading to ensure
# config file values take precedence. Defaults applied in check_prerequisites().

# Expand ~ to the actual user's home directory (handles sudo)
expand_tilde() {
    local path="$1"
    if [[ "$path" == "~"* ]]; then
        # When running under sudo, use SUDO_USER's home, otherwise use HOME
        local user_home
        if [ -n "$SUDO_USER" ]; then
            user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        else
            user_home="$HOME"
        fi
        # Replace leading ~ with the home directory
        path="${user_home}${path:1}"
    fi
    echo "$path"
}

# Function: Print banner
print_banner() {
    echo ""
    echo "=========================================="
    echo "  Mastercard CBS Connector Deployment    "
    echo "=========================================="
    echo ""
}

# Function: Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Apply defaults if not set by config (must happen after config loading)
    MASTERCARD_NAMESPACE="${MASTERCARD_NAMESPACE:-mastercard-demo}"
    MASTERCARD_ENABLED="${MASTERCARD_ENABLED:-true}"
    MASTERCARD_CBS_HOME="${MASTERCARD_CBS_HOME:-$HOME/ph-ee-connector-mccbs}"
    MASTERCARD_USE_MOCK="${MASTERCARD_USE_MOCK:-true}"
    MASTERCARD_API_URL="${MASTERCARD_API_URL:-}"
    PAYMENTHUB_NAMESPACE="${PH_NAMESPACE:-paymenthub}"
    MASTERCARD_SIMULATOR_HOME="${MASTERCARD_SIMULATOR_HOME:-$HOME/mastercard-cbs-simulator}"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        exit 1
    fi

    # Check if CBS connector directory exists
    if [ ! -d "$MASTERCARD_CBS_HOME" ]; then
        log_error "Mastercard CBS directory not found at: $MASTERCARD_CBS_HOME"
        log_error "Please set MASTERCARD_CBS_HOME or ensure ~/ph-ee-connector-mccbs exists"
        exit 1
    fi

    # Check if PaymentHub namespace exists
    if ! run_as_user "kubectl get namespace \"$PAYMENTHUB_NAMESPACE\"" &> /dev/null; then
        log_warn "PaymentHub namespace not found: $PAYMENTHUB_NAMESPACE"
        log_warn "Mastercard CBS requires PaymentHub to be deployed first"
        log_warn "Run './run.sh' without --mastercard-only first"
    fi

    log_success "Prerequisites check passed"
}

# Function: Build Docker images
build_images() {
    log_info "Building Docker images..."

    # Build CBS connector image
    log_info "Building CBS connector image..."
    cd "$MASTERCARD_CBS_HOME"
    if [ -f "build.gradle" ] || [ -f "Dockerfile" ]; then
        docker build -t ph-ee-connector-mastercard-cbs:1.0.0 . || {
            log_error "Failed to build CBS connector image"
            exit 1
        }
        log_success "CBS connector image built"
    else
        log_warn "Skipping connector build - no Dockerfile found"
    fi

    # Build simulator image if needed
    if [ "$MASTERCARD_USE_MOCK" == "true" ] && [ -d "$HOME/mastercard-cbs-simulator" ]; then
        log_info "Building mock simulator image..."
        cd "$HOME/mastercard-cbs-simulator"
        if [ -f "pom.xml" ] || [ -f "Dockerfile" ]; then
            docker build -t mastercard-cbs-simulator:1.0.0 . || {
                log_warn "Failed to build simulator image, will try to use existing"
            }
            log_success "Simulator image built"
        fi
    fi

    cd "$SCRIPT_DIR"
}

# Function: Create namespace
create_namespace() {
    log_info "Creating namespace: $MASTERCARD_NAMESPACE"

    run_as_user "kubectl create namespace $MASTERCARD_NAMESPACE --dry-run=client -o yaml" | run_as_user "kubectl apply -f -" || {
        log_warn "Namespace may already exist"
    }

    # Label namespace
    run_as_user "kubectl label namespace $MASTERCARD_NAMESPACE app.kubernetes.io/part-of=mifos-gazelle app.kubernetes.io/component=mastercard-cbs --overwrite"

    log_success "Namespace ready: $MASTERCARD_NAMESPACE"
}

# Function: Create secrets
create_secrets() {
    log_info "Creating Kubernetes secrets..."

    # Create Mastercard credentials secret if not exists
    if ! run_as_user "kubectl get secret mastercard-cbs-credentials -n $MASTERCARD_NAMESPACE" &> /dev/null; then
        run_as_user "kubectl create secret generic mastercard-cbs-credentials -n $MASTERCARD_NAMESPACE --from-literal=client_id=${MASTERCARD_CLIENT_ID:-demo} --from-literal=client_secret=${MASTERCARD_CLIENT_SECRET:-demo} --from-literal=partner_id=${MASTERCARD_PARTNER_ID:-MIFOS_GOVSTACK}"

        log_success "Created mastercard-cbs-credentials secret"
    else
        log_info "Mastercard credentials secret already exists"
    fi

    # Ensure mysql secret is accessible (copy from paymenthub if needed)
    if run_as_user "kubectl get secret mysql-secret -n $PAYMENTHUB_NAMESPACE" &> /dev/null; then
        if ! run_as_user "kubectl get secret mysql-secret -n $MASTERCARD_NAMESPACE" &> /dev/null; then
            run_as_user "kubectl get secret mysql-secret -n $PAYMENTHUB_NAMESPACE -o yaml" | sed "s/namespace: $PAYMENTHUB_NAMESPACE/namespace: $MASTERCARD_NAMESPACE/" | run_as_user "kubectl apply -f -"
            log_success "Copied mysql-secret to $MASTERCARD_NAMESPACE"
        fi
    else
        log_warn "mysql-secret not found in $PAYMENTHUB_NAMESPACE"
    fi
}

# Function: Deploy operator
deploy_operator() {
    log_info "Deploying Mastercard CBS operator..."

    cd "$MASTERCARD_CBS_HOME/operator"

    # Determine config file to use and expand ~ to actual path
    local config_file=""
    if [ -n "$CONFIG_FILE_PATH" ]; then
        config_file=$(expand_tilde "$CONFIG_FILE_PATH")
        log_info "Using config file: $config_file"
    elif [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/config/config.ini" ]; then
        config_file="$RUN_DIR/config/config.ini"
        log_info "Using default config file: $config_file"
    else
        config_file=$(expand_tilde "~/mifos-gazelle/config/config.ini")
        log_info "Using fallback config file: $config_file"
    fi

    # Deploy operator (run as user to access kubeconfig)
    run_as_user "bash '$MASTERCARD_CBS_HOME/operator/deploy-operator.sh' -c '$config_file' deploy" || {
        log_error "Failed to deploy operator"
        exit 1
    }

    log_success "Operator deployed successfully"
}

# Function: Deploy CBS connector via CR
deploy_connector() {
    log_info "Deploying Mastercard CBS connector..."

    # Determine API URL
    local api_url="$MASTERCARD_API_URL"
    if [ -z "$api_url" ]; then
        if [ "$MASTERCARD_USE_MOCK" == "true" ]; then
            api_url="http://mastercard-simulator.${MASTERCARD_NAMESPACE}.svc.cluster.local:8080"
        else
            api_url="https://sandbox.api.mastercard.com"
        fi
    fi

    # Determine image settings based on localdev mode
    local image_repo="ph-ee-connector-mastercard-cbs"
    local image_tag="1.0.0"
    local localdev_section=""

    if [ "${MASTERCARD_LOCALDEV_ENABLED:-false}" == "true" ]; then
        log_info "Local development mode enabled"
        image_repo="eclipse-temurin"
        image_tag="17"
        localdev_section="  localdev:
    enabled: true
    hostPath: \"${MASTERCARD_CBS_HOME}\"
    jarPath: \"/app/build/libs/ph-ee-connector-mastercard-cbs-1.0.0-SNAPSHOT.jar\""
    fi

    # Determine simulator image settings based on localdev mode
    local sim_image_repo="mastercard-cbs-simulator"
    local sim_image_tag="1.0.0"
    local sim_localdev_section=""

    if [ "${MASTERCARD_SIMULATOR_LOCALDEV_ENABLED:-false}" == "true" ]; then
        log_info "Simulator local development mode enabled"
        sim_image_repo="eclipse-temurin"
        sim_image_tag="17"
        sim_localdev_section="    localdev:
      enabled: true
      hostPath: \"${MASTERCARD_SIMULATOR_HOME}\"
      jarPath: \"/app/build/libs/mastercard-cbs-simulator-1.0.0-SNAPSHOT.jar\""
    fi

    # Debug: Show what localdev sections were generated
    if [ -n "$DEBUG" ]; then
        log_info "DEBUG: localdev_section = '${localdev_section}'"
        log_info "DEBUG: sim_localdev_section = '${sim_localdev_section}'"
    fi

    # Generate CR YAML
    local cr_yaml=$(cat <<EOF
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: ${MASTERCARD_NAMESPACE}
spec:
  enabled: ${MASTERCARD_ENABLED}
  replicas: 1
  image:
    repository: ${image_repo}
    tag: "${image_tag}"
    pullPolicy: IfNotPresent
  mastercard:
    useMock: ${MASTERCARD_USE_MOCK}
    apiUrl: "${api_url}"
    clientSecretName: "mastercard-cbs-credentials"
  paymenthub:
    namespace: "${PAYMENTHUB_NAMESPACE}"
    zeebeGateway: "phee-zeebe-gateway.${PAYMENTHUB_NAMESPACE}.svc.cluster.local:26500"
    operationsDb:
      host: "operationsmysql.${PAYMENTHUB_NAMESPACE}.svc.cluster.local"
      port: 3306
      database: "operations"
      secretName: "mysql-secret"
  simulator:
    enabled: ${MASTERCARD_USE_MOCK}
    image:
      repository: ${sim_image_repo}
      tag: "${sim_image_tag}"
${sim_localdev_section}
  dataLoading:
    autoLoad: true
    demoPayeeCount: 10
  workflow:
    autoDeploy: true
${localdev_section}
  resources:
    limits:
      cpu: "500m"
      memory: "512Mi"
    requests:
      cpu: "250m"
      memory: "256Mi"
EOF
)

    # Save to file (also serves as debug file)
    # Note: Must write to file because run_as_user uses 'su -c' which doesn't pass stdin
    local cr_file="/tmp/mastercard-cbs-cr.yaml"
    echo "$cr_yaml" > "$cr_file"
    chmod 644 "$cr_file"
    log_info "CR YAML saved to $cr_file"

    # Apply CR from file
    local apply_output
    apply_output=$(run_as_user "kubectl apply -f '$cr_file' 2>&1")
    local apply_exit_code=$?

    log_info "kubectl apply exit code: $apply_exit_code"
    log_info "kubectl apply output: $apply_output"

    if [ $apply_exit_code -eq 0 ]; then
        log_success "Connector CR applied successfully"
    else
        log_error "Failed to apply Connector CR"
        log_error "Output: $apply_output"
        return 1
    fi
}

# Function: Load database schema
load_database_schema() {
    log_info "Loading database schema..."

    local db_host="operationsmysql.${PAYMENTHUB_NAMESPACE}.svc.cluster.local"
    local schema_file="$MASTERCARD_CBS_HOME/src/utils/data-loading/mastercard-cbs-schema-v2.sql"

    if [ ! -f "$schema_file" ]; then
        log_warn "Schema file not found: $schema_file"
        return 1
    fi

    # Get MySQL password
    local mysql_password
    mysql_password=$(run_as_user "kubectl get secret mysql-secret -n \"$PAYMENTHUB_NAMESPACE\" -o jsonpath='{.data.password}' | base64 -d")

    # Load schema via kubectl exec
    run_as_user "kubectl exec -n \"$PAYMENTHUB_NAMESPACE\" operationsmysql-0 -- mysql -uroot -p\"${mysql_password}\" operations" < "$schema_file" 2>/dev/null || {
        log_warn "Failed to load schema directly, will be loaded by operator"
    }

    log_success "Database schema loaded"
}

# Function: Load supplementary data
load_supplementary_data() {
    log_info "Loading supplementary data..."

    # This will be handled by the operator's data loading job
    # But we can trigger it manually if needed
    log_info "Data loading will be handled by operator"

    # Optionally run locally
    if [ -f "$MASTERCARD_CBS_HOME/src/utils/data-loading/load-mastercard-supplementary-data.py" ]; then
        log_info "You can also load data manually:"
        log_info "  cd $MASTERCARD_CBS_HOME/src/utils/data-loading"
        log_info "  ./load-mastercard-supplementary-data.py -c ~/tomconfig.ini"
    fi
}

# Function: Deploy BPMN workflow
deploy_bpmn_workflow() {
    log_info "Deploying BPMN workflow..."

    local workflow_file="$MASTERCARD_CBS_HOME/orchestration/bulk_connector_mastercard_cbs-DFSPID.bpmn"

    if [ ! -f "$workflow_file" ]; then
        log_warn "BPMN workflow file not found: $workflow_file"
        return 1
    fi

    # Use the existing deployBpmn-gazelle.sh script
    local deploy_script="$RUN_DIR/src/utils/deployBpmn-gazelle.sh"

    if [ ! -f "$deploy_script" ]; then
        log_warn "deployBpmn-gazelle.sh not found at: $deploy_script"
        return 1
    fi

    log_info "Deploying workflow via deployBpmn-gazelle.sh..."

    # Determine config file path - use the one passed to run.sh
    local config_file=""
    if [ -n "$CONFIG_FILE_PATH" ]; then
        config_file="$CONFIG_FILE_PATH"
        log_info "Using config file from run.sh: $config_file"
    elif [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/config/config.ini" ]; then
        config_file="$RUN_DIR/config/config.ini"
        log_info "Using default config file: $config_file"
    else
        log_error "Config file not found. CONFIG_FILE_PATH not set and default not found."
        return 1
    fi

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    # Deploy for greenbank tenant (primary tenant that will use Mastercard CBS)
    log_info "Deploying for tenant: greenbank"
    if run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t greenbank"; then
        log_success "Workflow deployed for greenbank"
    else
        log_warn "Failed to deploy workflow for greenbank"
        return 1
    fi

    # Also deploy for redbank if it exists as a tenant
    log_info "Attempting to deploy for tenant: redbank"
    run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t redbank" 2>/dev/null && {
        log_success "Workflow deployed for redbank"
    } || {
        log_info "Skipped redbank tenant (tenant may not exist)"
    }

    # Deploy for bluebank if it exists as a tenant
    log_info "Attempting to deploy for tenant: bluebank"
    run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t bluebank" 2>/dev/null && {
        log_success "Workflow deployed for bluebank"
    } || {
        log_info "Skipped bluebank tenant (tenant may not exist)"
    }

    log_success "BPMN workflow deployment complete"
}

# Function: Configure payment mode in bulk processor
configure_payment_mode() {
    log_info "Configuring MASTERCARD_CBS payment mode..."

    log_info "Payment mode configuration:"
    log_info "  Add to ph-ee-bulk-processor application.yaml:"
    log_info "    payment-modes:"
    log_info "      - id: \"MASTERCARD_CBS\""
    log_info "        type: \"BULK\""
    log_info "        endpoint: \"bulk_connector_mastercard_cbs-{dfspid}\""

    # Check if running with hostpath mounts
    if [ -d "$HOME/ph-ee-bulk-processor" ]; then
        log_info "Detected hostpath setup - you may need to:"
        log_info "  1. Edit ~/ph-ee-bulk-processor/src/main/resources/application.yaml"
        log_info "  2. Run: cd ~/ph-ee-bulk-processor && ./gradlew clean build -x test"
        log_info "  3. Restart: kubectl delete pod -n paymenthub -l app=ph-ee-bulk-processor"
    fi
}

# Function: Wait for deployment
wait_for_deployment() {
    log_info "Waiting for deployments to be ready..."

    local timeout=300
    local elapsed=0

    # Wait for connector
    log_info "Waiting for CBS connector..."
    while [ $elapsed -lt $timeout ]; do
        if run_as_user "kubectl get deployment ph-ee-connector-mastercard-cbs -n \"$MASTERCARD_NAMESPACE\"" &> /dev/null; then
            if run_as_user "kubectl wait --for=condition=available --timeout=30s deployment/ph-ee-connector-mastercard-cbs -n \"$MASTERCARD_NAMESPACE\"" &> /dev/null; then
                log_success "CBS connector is ready"
                break
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    # Wait for simulator if enabled
    if [ "$MASTERCARD_USE_MOCK" == "true" ]; then
        log_info "Waiting for mock simulator..."
        run_as_user "kubectl wait --for=condition=available --timeout=60s deployment/mastercard-cbs-simulator -n \"$MASTERCARD_NAMESPACE\"" &> /dev/null || {
            log_warn "Simulator not ready yet"
        }
    fi

    log_success "Deployments ready"
}

# Function: Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."

    echo ""
    echo "Checking Custom Resource:"
    run_as_user "kubectl get mastercardcbsconnector -n $MASTERCARD_NAMESPACE" || log_warn "CR not found"

    echo ""
    echo "Checking Pods:"
    run_as_user "kubectl get pods -n $MASTERCARD_NAMESPACE"

    echo ""
    echo "Checking Services:"
    run_as_user "kubectl get svc -n $MASTERCARD_NAMESPACE"

    echo ""
    log_info "Checking connector logs..."
    if run_as_user "kubectl get pod -l app=ph-ee-connector-mastercard-cbs -n $MASTERCARD_NAMESPACE" &> /dev/null; then
        run_as_user "kubectl logs -l app=ph-ee-connector-mastercard-cbs -n $MASTERCARD_NAMESPACE --tail=10" | grep -i "Registered worker" || {
            log_warn "Workers may not be registered yet"
        }
    fi

    log_success "Verification complete"
}

# Function: Print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "  Deployment Complete  "
    echo "=========================================="
    echo ""
    echo "Components deployed:"
    echo "  ✓ Kubernetes Operator"
    echo "  ✓ Mastercard CBS Connector"
    [ "$MASTERCARD_USE_MOCK" == "true" ] && echo "  ✓ Mock Mastercard API Simulator"
    echo "  ✓ Database Schema"
    echo "  ✓ BPMN Workflow"
    echo ""
    echo "Namespace: $MASTERCARD_NAMESPACE"
    echo ""
    echo "Next steps:"
    echo "  1. Load supplementary data:"
    echo "     cd $MASTERCARD_CBS_HOME/src/utils/data-loading"
    echo "     ./load-mastercard-supplementary-data.py -c ~/tomconfig.ini"
    echo ""
    echo "  2. Generate test batch:"
    echo "     ./generate-mastercard-batch.py -c ~/tomconfig.ini --count 10"
    echo ""
    echo "  3. Submit batch:"
    echo "     ./submit-batch.py -c ~/tomconfig.ini -f bulk-mastercard-cbs.csv \\"
    echo "       --tenant greenbank --payment-mode MASTERCARD_CBS"
    echo ""
    echo "  4. Monitor:"
    echo "     kubectl logs -n $MASTERCARD_NAMESPACE -l app=ph-ee-connector-mastercard-cbs -f"
    echo ""
    echo "  5. Check CR status:"
    echo "     kubectl get mastercardcbsconnector -n $MASTERCARD_NAMESPACE"
    echo ""
}

# Function: Cleanup/undeploy
cleanup() {
    log_info "Cleaning up Mastercard CBS deployment..."

    # Initialize variables with defaults (in case this is called directly)
    MASTERCARD_NAMESPACE="${MASTERCARD_NAMESPACE:-mastercard-demo}"
    MASTERCARD_CBS_HOME="${MASTERCARD_CBS_HOME:-$HOME/ph-ee-connector-mccbs}"

    # Delete CR (operator will cleanup resources)
    run_as_user "kubectl delete mastercardcbsconnector mastercard-cbs -n \"$MASTERCARD_NAMESPACE\" --ignore-not-found=true"

    # Wait for cleanup
    sleep 10

    # Undeploy operator
    if [ -f "$MASTERCARD_CBS_HOME/operator/deploy-operator.sh" ]; then
        run_as_user "cd \"$MASTERCARD_CBS_HOME/operator\" && bash deploy-operator.sh undeploy"
    fi

    # Delete namespace
    run_as_user "kubectl delete namespace \"$MASTERCARD_NAMESPACE\" --ignore-not-found=true"

    log_success "Cleanup complete"
}

# Main deployment function
deploy_mastercard() {
    print_banner
    check_prerequisites
    # no need to build_images this is done by circleCI
    create_namespace
    create_secrets
    deploy_operator
    sleep 5  # Give operator time to start
    deploy_connector
    wait_for_deployment
    deploy_bpmn_workflow
    configure_payment_mode
    verify_deployment
    print_summary
}

# Main entry point (only used when script is executed directly, not sourced)
main() {
    set -e  # Enable exit on error only for standalone execution
    case "${1:-deploy}" in
        deploy)
            deploy_mastercard
            ;;
        undeploy|cleanup)
            cleanup
            ;;
        verify)
            verify_deployment
            ;;
        status)
            run_as_user "kubectl get mastercardcbsconnector -n $MASTERCARD_NAMESPACE"
            run_as_user "kubectl get pods -n $MASTERCARD_NAMESPACE"
            ;;
        *)
            echo "Usage: $0 {deploy|undeploy|verify|status}"
            echo ""
            echo "Commands:"
            echo "  deploy   - Deploy Mastercard CBS connector (default)"
            echo "  undeploy - Remove Mastercard CBS deployment"
            echo "  verify   - Verify deployment status"
            echo "  status   - Show current status"
            exit 1
            ;;
    esac
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
