#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X 

#------------------------------------------------------------------------------
# Function: DeployMifosXfromYaml
# Description: Deploys MifosX (Fineract + web app) using Kubernetes manifests from a specified directory.
# Parameters:
#   $1 - Directory containing the Kubernetes manifests for MifosX deployment.
#   $2 - (Optional) Timeout in seconds to wait for the fineract-server pod to be ready. Default is 600 seconds.
#------------------------------------------------------------------------------
function DeployMifosXfromYaml() {
    manifests_dir=$1
    timeout_secs=${2:-600}  # Default timeout of 10 minutes if not specified

    if is_app_running  "$MIFOSX_NAMESPACE"; then
      if [[ "$redeploy" == "false" ]]; then
        echo "    MifosX application is already deployed. Skipping deployment."
        return
      fi
    fi 
    run_as_user "kubectl wait --for=condition=ready pod --all -n $PH_NAMESPACE --timeout=600s"
    # => should be in PHEE not here ?? wait_for_pods_ready "$PH_NAMESPACE"
    # We are deploying or redeploying => make sure things are cleaned up first
    printf "    Redeploying MifosX : Deleting existing resources in namespace %s\n" "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    echo "==> Deploying MifosX i.e. web-app and fineract via application manifests"
    createNamespace "$MIFOSX_NAMESPACE"
    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"
    
    # Update FQDNs in values file and manifests 
    echo "    Updating MifosX FQDNs manifest(s) to use domain $GAZELLE_DOMAIN"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN" 
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN" 

    # Restore the database dump before starting MifosX
    # Assumes FINERACT_LIQUIBASE_ENABLED=false in fineract deployment
    echo "    Restoring MifosX database dump "
    run_as_user "$UTILS_DIR/dump-restore-fineract-db.sh -r"  > /dev/null
    
    echo "    deploying MifosX manifests from $manifests_dir"
    applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    
    # Wait for both fineract-server and web-app pods to be ready
    echo "    Waiting for MifosX pods to be ready (timeout: ${timeout_secs}s)..."

    # # Wait for pods to exist first, then wait for them to be ready
    # local start_time=$(date +%s)
    # local elapsed=0

    # while [[ $elapsed -lt $timeout_secs ]]; do
    #     local fineract_exists=$(run_as_user "kubectl get pod -n \"$MIFOSX_NAMESPACE\" -l app=fineract-server --no-headers 2>/dev/null | wc -l")
    #     local webapp_exists=$(run_as_user "kubectl get pod -n \"$MIFOSX_NAMESPACE\" -l app=web-app --no-headers 2>/dev/null | wc -l")

    #     if [[ "$fineract_exists" -gt 0 && "$webapp_exists" -gt 0 ]]; then
    #         # Pods exist, now wait for them to be ready
    #         if run_as_user "kubectl wait --for=condition=Ready pod -l app=fineract-server \
    #             --namespace=\"$MIFOSX_NAMESPACE\" --timeout=\"${timeout_secs}s\" "  > /dev/null 2>&1 && \
    #            run_as_user "kubectl wait --for=condition=Ready pod -l app=web-app \
    #             --namespace=\"$MIFOSX_NAMESPACE\" --timeout=\"${timeout_secs}s\" "  > /dev/null 2>&1 ; then
    #             echo "    MifosX is ready (fineract-server and web-app)"
    #             break
    #         else
    #             echo -e "${RED} ERROR: MifosX pods exist but failed to become ready ${RESET}"
    #             return 1
    #         fi
    #     fi

    #     sleep 5
    #     elapsed=$(( $(date +%s) - start_time ))
    # done

    # if [[ $elapsed -ge $timeout_secs ]]; then
    #     echo -e "${RED} ERROR: MifosX pods failed to be created within ${timeout_secs} seconds ${RESET}"
    #     return 1
    # fi  
    echo -e "\n${GREEN}====================================="
    echo -e "MifosX (fineract + web app) Deployed"
    echo -e "=====================================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function : wait_for_fineract_api_ready
# Description: Polls two Fineract endpoints per tenant until both confirm the
#              tenant is fully initialised:
#                1. /clients       → HTTP 200  (schema migration complete)
#                2. /paymenttypes  → non-empty array (seed-data migration complete)
#              Checking only /clients is insufficient: it returns 200 as soon as
#              the DDL migration finishes, but Fineract's DML seed phase (payment
#              types, currencies, offices) runs afterwards.  Savings-product and
#              client creation fail with 4xx until that seed phase completes.
# Parameters: None (uses GAZELLE_DOMAIN)
# Returns:    0 if all tenants ready, 1 on timeout
#------------------------------------------------------------------------------
function wait_for_fineract_api_ready {
  local tenants=("greenbank" "bluebank" "redbank")
  local base_url="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"
  local auth="Basic bWlmb3M6cGFzc3dvcmQ="   # mifos:password
  local timeout=300
  local retry_interval=10

  echo -e "${BLUE}    Waiting for Fineract tenant APIs to be fully initialised (schema + seed data)...${RESET}"

  for tenant in "${tenants[@]}"; do
    local start_time
    start_time=$(date +%s)
    local elapsed=0
    local ready=false

    while [[ $elapsed -lt $timeout ]]; do
      # Gate 1: schema migration done (/clients returns 200)
      local clients_code
      clients_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: ${auth}" \
        -H "Fineract-Platform-TenantId: ${tenant}" \
        --max-time 10 \
        "${base_url}/clients" 2>/dev/null)

      if [[ "$clients_code" == "200" ]]; then
        # Gate 2: seed-data migration done (/paymenttypes returns non-empty array)
        local paymenttypes_body
        paymenttypes_body=$(curl -sk \
          -H "Authorization: ${auth}" \
          -H "Fineract-Platform-TenantId: ${tenant}" \
          --max-time 10 \
          "${base_url}/paymenttypes" 2>/dev/null)

        # Non-empty JSON array means seeding is complete
        if [[ "$paymenttypes_body" =~ ^\[ && "$paymenttypes_body" != "[]" ]]; then
          echo -e "${GREEN}    Fineract tenant '${tenant}' fully ready — schema + seed data (${elapsed}s elapsed)${RESET}"
          ready=true
          break
        else
          echo -e "${YELLOW}    Tenant '${tenant}' schema ready but seed data still pending, retrying in ${retry_interval}s... (${elapsed}s / ${timeout}s)${RESET}"
        fi
      else
        echo -e "${YELLOW}    Tenant '${tenant}' schema not ready (HTTP ${clients_code:-000}), retrying in ${retry_interval}s... (${elapsed}s / ${timeout}s)${RESET}"
      fi

      sleep $retry_interval
      elapsed=$(( $(date +%s) - start_time ))
    done

    if [[ "$ready" != "true" ]]; then
      echo -e "${RED}    ERROR: Fineract tenant '${tenant}' not fully initialised after ${timeout}s${RESET}"
      return 1
    fi
  done

  echo -e "${GREEN}    All Fineract tenant APIs are ready${RESET}"
  return 0
}

#------------------------------------------------------------------------------
# Function : generateMifosXandVNextData
# Description: Generates MifosX clients and accounts & registers associations with vNext Oracle.
# Parameters: None
#------------------------------------------------------------------------------
function generateMifosXandVNextData {  
  local timeout=300  # 5 minutes in seconds
  local recheck_time=30  # 30 seconds
  local start_time=$(date +%s)
  local elapsed=0
  
  while [[ $elapsed -lt $timeout ]]; do
    is_app_running "vnext"
    result_vnext=$?
    is_app_running "mifosx"
    result_mifosx=$?
    
    if [[ $result_vnext -eq 0 ]] && [[ $result_mifosx -eq 0 ]]; then
      # Pods are ready but Fineract's per-tenant Flyway migrations may still be running.
      # Poll each tenant's API endpoint until all return HTTP 200 before generating data.
      if ! wait_for_fineract_api_ready; then
        echo -e "${RED}    Fineract API not ready — aborting data generation${RESET}"
        return 1
      fi

      echo -e "${BLUE}    Generating MifosX clients and accounts & registering associations with vNext Oracle ...${RESET}"

      results=$(run_as_user "$RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c \"$CONFIG_FILE_PATH\" ") #> /dev/null 2>&1
  
      if [[ "$?" -ne 0 ]]; then
        echo -e "${RED}Error generating vNext clients and accounts ${RESET}"
        echo " run $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c $CONFIG_FILE_PATH to investigate"
        return 1 
      fi
      
      # Success - exit the function
      return 0
    else 
      elapsed=$(( $(date +%s) - start_time ))
      
      if [[ $elapsed -lt $timeout ]]; then
        echo -e "${YELLOW}vNext or MifosX is not running. Retrying in ${recheck_time} seconds... (Elapsed: ${elapsed}s / ${timeout}s)${RESET}"
        sleep $recheck_time
        elapsed=$(( $(date +%s) - start_time ))
      fi
    fi
  done
  
  # Timeout reached
  echo -e "${RED}Timeout: vNext or MifosX did not start within ${timeout} seconds => skipping MifosX and vNext data generation ${RESET}"
  return 1
}
