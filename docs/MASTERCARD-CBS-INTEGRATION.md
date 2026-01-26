# Mastercard CBS Integration with Mifos-Gazelle

## Overview

The Mastercard CBS connector has been integrated into mifos-gazelle using a **Kubernetes Operator** pattern. This provides declarative configuration, automatic reconciliation, and seamless integration with the existing PaymentHub deployment.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Mifos-Gazelle run.sh                                    │
│  ├── Core Infrastructure                                 │
│  ├── MifosX                                              │
│  ├── Mojaloop vNext                                      │
│  ├── Payment Hub EE (PHEE)                               │
│  └── Mastercard CBS (NEW)                                │
│      ├── Kubernetes Operator                             │
│      ├── Custom Resource (MastercardCBSConnector)        │
│      ├── CBS Connector Pod                               │
│      ├── Mock Simulator (optional)                       │
│      └── BPMN Workflows                                  │
└──────────────────────────────────────────────────────────┘
```

**Key Components:**
- **Kubernetes Operator**: Manages CBS connector lifecycle
- **Custom Resource Definition (CRD)**: `mastercardcbsconnectors.paymenthub.mifos.io`
- **CBS Connector**: Java Spring Boot application integrating with PaymentHub
- **Mock Simulator**: Development/testing API endpoint
- **Data Loading**: Supplementary data for regulatory compliance
- **BPMN Workflows**: `bulk_connector_mastercard_cbs-DFSPID.bpmn`

## Configuration

### config.ini Settings

The Mastercard CBS connector is configured in `/home/tdaly/mifos-gazelle/config/config.ini`:

```ini
[mastercard-demo]
# Enable or disable mastercard-demo deployment
enabled = true

# Kubernetes namespace for Mastercard CBS
MASTERCARD_NAMESPACE = mastercard-demo

# Repository settings (if cloning from git)
MASTERCARD_REPO_DIR = mastercard
MASTERCARD_BRANCH = phee-351
MASTERCARD_REPO_LINK = https://github.com/openMF/ph-ee-connector-mccbs.git

# Local CBS connector directory (required)
MASTERCARD_CBS_HOME = $HOME/ph-ee-connector-mccbs

# Use mock API or real Mastercard sandbox
MASTERCARD_USE_MOCK = true

# Mastercard API URL (empty = auto-detect)
# For sandbox: https://sandbox.api.mastercard.com
MASTERCARD_API_URL =
```

### Prerequisites

Before deploying Mastercard CBS:

1. **PaymentHub EE must be deployed**:
   ```bash
   cd ~/mifos-gazelle
   sudo ./run.sh -a "infra phee"
   ```

2. **CBS connector repository must exist**:
   ```bash
   ls ~/ph-ee-connector-mccbs/operator/
   ```

3. **Docker must be available** for building images

## Deployment Methods

### Method 1: Deploy All Components (Recommended)

Deploy entire mifos-gazelle stack including Mastercard CBS:

```bash
cd ~/mifos-gazelle
sudo ./run.sh -a "infra mifosx phee vnext mastercard-demo"
```

This will:
1. Set up Kubernetes cluster (if local)
2. Deploy infrastructure (MySQL, NGINX)
3. Deploy MifosX core banking
4. Deploy Payment Hub EE
5. Deploy Mojaloop vNext switch
6. Deploy Mastercard CBS via operator

### Method 2: Deploy Mastercard CBS Only

If PaymentHub is already running:

```bash
cd ~/mifos-gazelle
sudo ./run.sh -a "mastercard-demo"
```

### Method 3: Manual Deployment via mastercard.sh

Direct deployment using the deployer script:

```bash
cd ~/mifos-gazelle
source src/deployer/mastercard.sh
deploy_mastercard
```

Or standalone:

```bash
cd ~/mifos-gazelle/src/deployer
./mastercard.sh deploy
```

## What Gets Deployed

The deployment process executes the following steps:

### 1. Build Docker Images

```bash
cd ~/ph-ee-connector-mccbs
docker build -t ph-ee-connector-mastercard-cbs:1.0.0 .
docker build -t mastercard-cbs-simulator:1.0.0 ./simulator
```

### 2. Create Namespace

```bash
kubectl create namespace mastercard-demo
```

### 3. Deploy Kubernetes Operator

```bash
cd ~/ph-ee-connector-mccbs/operator
./deploy-operator.sh deploy
```

This creates:
- Custom Resource Definition (CRD)
- Operator deployment
- Service account and RBAC
- ConfigMap with operator configuration

### 4. Deploy Connector via Custom Resource

Applies the Custom Resource which triggers operator reconciliation:

```yaml
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: mastercard-demo
spec:
  enabled: true
  replicas: 1
  mastercard:
    useMock: true
    apiUrl: "http://mastercard-simulator:8080"
  paymenthub:
    namespace: paymenthub
    zeebeGateway: "zeebe-gateway.paymenthub.svc.cluster.local:26500"
  simulator:
    enabled: true
  dataLoading:
    autoLoad: true
  workflow:
    autoDeploy: true
```

### 5. Load Database Schema

Creates `mastercard_cbs_supplementary_data` table in operations database.

### 6. Deploy BPMN Workflow

Deploys workflow to Zeebe:
- `bulk_connector_mastercard_cbs-DFSPID.bpmn`

### 7. Configure Payment Mode

Adds `MASTERCARD_CBS` payment mode to bulk processor configuration.

## Verification

### Check Deployment Status

```bash
# Check operator
kubectl get pods -n mastercard-demo -l app=mastercard-cbs-operator

# Check custom resource
kubectl get mastercardcbsconnector -n mastercard-demo

# Check connector deployment
kubectl get pods -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs

# Check logs
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=50
```

### Expected Log Output

The connector should register 8 Zeebe workers:

```
Registered worker: mastercard-cbs-validate-input
Registered worker: mastercard-cbs-authenticate
Registered worker: mastercard-cbs-match-regulatory-data
Registered worker: mastercard-cbs-initiate-payment
Registered worker: mastercard-cbs-check-status
Registered worker: mastercard-cbs-update-operations
Registered worker: mastercard-cbs-retry-handler
Registered worker: mastercard-cbs-log-error
```

### Check Database

```bash
kubectl exec -n paymenthub operationsmysql-0 -- \
  mysql -uroot -pmysql operations -e \
  "SHOW TABLES LIKE 'mastercard%'"
```

Expected:
```
+----------------------------------------------+
| Tables_in_operations (mastercard%)           |
+----------------------------------------------+
| mastercard_cbs_supplementary_data            |
+----------------------------------------------+
```

## Testing

### Generate Test Data

Load supplementary data for testing:

```bash
cd ~/mifos-gazelle/src/utils/data-loading
./load-mastercard-supplementary-data.py -c ~/tomconfig.ini
```

### Generate Batch CSV

Create test batch file:

```bash
./generate-mastercard-batch.py -c ~/tomconfig.ini --count 10
```

### Submit Batch

```bash
./submit-batch.py \
  -c ~/tomconfig.ini \
  -f bulk-mastercard-cbs.csv \
  --tenant greenbank \
  --payment-mode MASTERCARD_CBS
```

### Monitor Batch

```bash
# Watch bulk processor logs
kubectl logs -n paymenthub -l app=ph-ee-bulk-processor -f

# Watch CBS connector logs
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -f

# Check batch status
kubectl exec -n paymenthub operationsmysql-0 -- \
  mysql -uroot -pmysql operations_app -e \
  "SELECT batch_id, total, successful, failed FROM batch ORDER BY id DESC LIMIT 1"
```

## Cleanup

### Remove Mastercard CBS Only

```bash
cd ~/mifos-gazelle
sudo ./run.sh -m cleanapps -a "mastercard-demo"
```

Or using deployer directly:

```bash
cd ~/mifos-gazelle/src/deployer
./mastercard.sh undeploy
```

This will:
1. Delete Custom Resource (operator handles cleanup)
2. Undeploy operator
3. Delete namespace

### Clean All Applications

```bash
cd ~/mifos-gazelle
sudo ./run.sh -m cleanall
```

## Troubleshooting

### Issue: PaymentHub namespace not found

**Symptom**: Deployment fails with "PaymentHub namespace not found"

**Solution**: Deploy PaymentHub first:
```bash
sudo ./run.sh -a "infra phee"
```

### Issue: Operator pod not starting

**Check**:
```bash
kubectl get pods -n mastercard-demo
kubectl logs -n mastercard-demo -l app=mastercard-cbs-operator
```

**Fix**: Verify RBAC permissions and CRD installation:
```bash
kubectl get crd mastercardcbsconnectors.paymenthub.mifos.io
kubectl get clusterrole mastercard-cbs-operator-role
```

### Issue: CBS connector not registering workers

**Check**:
```bash
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs | grep -i "registered worker"
```

**Fix**: Verify Zeebe connection:
```bash
kubectl exec -n mastercard-demo deployment/ph-ee-connector-mastercard-cbs -- \
  nc -zv zeebe-gateway.paymenthub.svc.cluster.local 26500
```

### Issue: Database schema not loaded

**Check**:
```bash
kubectl exec -n paymenthub operationsmysql-0 -- \
  mysql -uroot -pmysql operations -e "SHOW TABLES"
```

**Fix**: Manually load schema:
```bash
cd ~/ph-ee-connector-mccbs/src/utils/data-loading
kubectl exec -i -n paymenthub operationsmysql-0 -- \
  mysql -uroot -pmysql operations < mastercard-cbs-schema-v2.sql
```

## Configuration Updates

### Switch to Real Mastercard Sandbox

1. Update config.ini:
```ini
MASTERCARD_USE_MOCK = false
MASTERCARD_API_URL = https://sandbox.api.mastercard.com
```

2. Create credentials secret:
```bash
kubectl create secret generic mastercard-cbs-credentials \
  -n mastercard-demo \
  --from-literal=client_id=YOUR_CLIENT_ID \
  --from-literal=client_secret=YOUR_CLIENT_SECRET \
  --from-literal=partner_id=YOUR_PARTNER_ID
```

3. Update Custom Resource:
```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='merge' \
  -p '{
    "spec":{
      "mastercard":{
        "useMock":false,
        "apiUrl":"https://sandbox.api.mastercard.com"
      },
      "simulator":{
        "enabled":false
      }
    }
  }'
```

### Scale Connector

```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/replicas", "value":2}]'
```

### Disable Connector (Keep CR)

```bash
kubectl patch mastercardcbsconnector mastercard-cbs -n mastercard-demo \
  --type='merge' \
  -p '{"spec":{"enabled":false}}'
```

## Integration with GovStack G2P

The Mastercard CBS connector integrates with GovStack Government-to-Person bulk disbursements:

### G2P Flow with Mastercard CBS

```
Government → PaymentHub Bulk Processor → Mastercard CBS Connector → Mastercard API → International Banks
```

### Configuration for G2P

1. **Identity Account Mapper**: Maps MSISDNs to account numbers
2. **Supplementary Data**: Regulatory information per beneficiary
3. **Batch De-bulking**: Groups by destination country/institution
4. **Cross-border Routing**: Via Mastercard CBS API

See [docs/GOVSTACK.md](GOVSTACK.md) for detailed G2P architecture.

## Directory Structure

```
mifos-gazelle/
├── config/
│   └── config.ini                          # Mastercard config added
├── src/
│   ├── commandline/
│   │   └── commandline.sh                  # Updated with mastercard-demo
│   ├── deployer/
│   │   ├── deployer.sh                     # Sources mastercard.sh
│   │   └── mastercard.sh                   # Mastercard deployer (NEW)
│   └── utils/
│       └── data-loading/
│           ├── load-mastercard-supplementary-data.py
│           └── generate-mastercard-batch.py
└── docs/
    ├── MASTERCARD-CBS-INTEGRATION.md       # This document
    └── GOVSTACK.md                         # G2P architecture

~/ph-ee-connector-mccbs/
├── operator/
│   ├── config/
│   │   ├── crd/                            # Custom Resource Definition
│   │   ├── rbac/                           # Service account, roles
│   │   └── samples/                        # Sample CRs
│   ├── controllers/
│   │   └── reconcile.sh                    # Operator controller logic
│   └── deploy-operator.sh                  # Operator deployment script
├── src/
│   ├── main/java/                          # CBS connector code
│   └── utils/data-loading/                 # Database schema, scripts
├── orchestration/                          # BPMN workflows
└── docs/
    ├── OPERATOR_DEPLOYMENT_GUIDE.md        # Operator usage guide
    ├── INTEGRATION_QUICKSTART.md           # Quick integration guide
    └── JIRA_REQUIREMENTS_ANALYSIS.md       # Requirements analysis
```

## Summary

**Key Benefits:**
- ✅ Declarative configuration via Custom Resources
- ✅ Automatic reconciliation and self-healing
- ✅ Seamless integration with mifos-gazelle run.sh
- ✅ Independent lifecycle management
- ✅ Future-ready for Go operator migration

**Deployment Command:**
```bash
cd ~/mifos-gazelle
sudo ./run.sh -a "infra mifosx phee vnext mastercard-demo"
```

**Cleanup Command:**
```bash
sudo ./run.sh -m cleanapps -a "mastercard-demo"
```

---

**Document Created**: January 25, 2026
**Integration Version**: v1alpha1 (shell-based operator)
**Status**: Ready for deployment
**Next Steps**: Test deployment and verify end-to-end payment flow
