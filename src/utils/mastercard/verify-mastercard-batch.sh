#!/bin/bash
#
# Mastercard CBS Batch Payment Verification Script
# ================================================
#
# This script queries the operations database to generate a comprehensive report
# of Mastercard CBS batch payment status, including:
#   - Overall batch statistics (success rate, counts)
#   - Recent batch details
#   - Individual payment details with Mastercard payment IDs
#   - Status breakdown
#   - Failed payment details (if any)
#
# USAGE:
#   ./verify-mastercard-batch.sh [options]
#
# COMMON USAGE EXAMPLES:
#
#   1. Default (uses kubectl to connect to k8s pod):
#      ./verify-mastercard-batch.sh -k
#
#   2. Remote MySQL connection:
#      ./verify-mastercard-batch.sh -h operationsmysql.paymenthub.svc.cluster.local
#
#   3. Custom credentials:
#      ./verify-mastercard-batch.sh -k -u admin -p secretpass
#
# OPTIONS:
#   -c CONFIG_FILE    Path to config.ini file (default: ~/tomconfig.ini)
#   -h MYSQL_HOST     MySQL host (default: operationsmysql.paymenthub.svc.cluster.local)
#   -P MYSQL_PORT     MySQL port (default: 3306)
#   -u MYSQL_USER     MySQL user (default: root)
#   -p MYSQL_PASS     MySQL password (default: mysql)
#   -d DATABASE       Database name (default: operations_app)
#   -k                Use kubectl exec (for k8s pod access) - RECOMMENDED
#   --help            Show this help message
#
# WHAT THE REPORT SHOWS:
#   - Batch Summary: Total batches, transfers, success rate (last 24 hours)
#   - Recent Batches: Last 10 batches with completion statistics
#   - Payment Details: Last 15 individual payments with Mastercard payment IDs
#   - Status Breakdown: Distribution of payment statuses
#   - Failed Payments: Details of any failed payments for troubleshooting
#
# TROUBLESHOOTING:
#
#   View detailed Mastercard API responses in logs:
#     kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100 | grep -A 10 'MASTERCARD CBS'
#
#   View workflow execution logs:
#     kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100 | grep 'GovStack'
#
#   Query specific payment by Mastercard Payment ID:
#     kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \
#       "SELECT * FROM transfers WHERE external_id = 'rem_XXX' \G"
#
#   Check operations DB update logs:
#     kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100 | grep 'OperationsDB'
#
# NOTES:
#   - The report shows data from the last 24 hours by default
#   - Mastercard payment IDs are stored in the 'external_id' column
#   - The 'status_detail' column contains the Mastercard status response
#   - If operations-app API is unreachable, payments still succeed but status may not be recorded
#
# LOCATION:
#   This script is located at: ~/mifos-gazelle/src/utils/mastercard/verify-mastercard-batch.sh
#

set -e

# Default values
CONFIG_FILE="${CONFIG_FILE:-$HOME/tomconfig.ini}"
MYSQL_HOST="operationsmysql.paymenthub.svc.cluster.local"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASS="mysql"
DATABASE="operations_app"
USE_KUBECTL=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h)
            MYSQL_HOST="$2"
            shift 2
            ;;
        -P)
            MYSQL_PORT="$2"
            shift 2
            ;;
        -u)
            MYSQL_USER="$2"
            shift 2
            ;;
        -p)
            MYSQL_PASS="$2"
            shift 2
            ;;
        -d)
            DATABASE="$2"
            shift 2
            ;;
        -k)
            USE_KUBECTL=true
            shift
            ;;
        --help)
            grep "^#" "$0" | grep -v "#!/bin/bash" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Mastercard CBS Batch Payment Verification${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

# SQL query for batch verification report
read -r -d '' SQL_QUERY << 'EOF' || true
-- Mastercard CBS Batch Payment Verification Report

SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT '  MASTERCARD CBS BATCH PAYMENT SUMMARY' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';

-- Overall batch statistics
SELECT
    COUNT(DISTINCT t.batch_id) AS 'Total Batches',
    COUNT(t.id) AS 'Total Transfers',
    SUM(CASE WHEN t.status = 'COMPLETED' THEN 1 ELSE 0 END) AS 'Completed',
    SUM(CASE WHEN t.status = 'FAILED' THEN 1 ELSE 0 END) AS 'Failed',
    SUM(CASE WHEN t.status NOT IN ('COMPLETED', 'FAILED') THEN 1 ELSE 0 END) AS 'Pending',
    CONCAT(ROUND(SUM(CASE WHEN t.status = 'COMPLETED' THEN 1 ELSE 0 END) * 100.0 / COUNT(t.id), 1), '%') AS 'Success Rate'
FROM transfers t
WHERE t.workflow_instance_key IS NOT NULL
  AND t.started_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR);

SELECT '' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT '  RECENT BATCHES (Last 10)' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';

-- Recent batch details
SELECT
    b.id AS 'ID',
    LEFT(b.batch_id, 25) AS 'Batch UUID',
    b.total AS 'Total',
    b.successful AS 'Success',
    b.failed AS 'Failed',
    b.ongoing AS 'Ongoing',
    CONCAT(ROUND(b.successful * 100.0 / NULLIF(b.total, 0), 1), '%') AS 'Rate',
    DATE_FORMAT(b.started_at, '%Y-%m-%d %H:%i:%s') AS 'Started At'
FROM batch b
ORDER BY b.id DESC
LIMIT 10;

SELECT '' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT '  MASTERCARD CBS PAYMENT DETAILS (Last 15)' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';

-- Individual transfer details with Mastercard payment IDs
SELECT
    t.id AS 'ID',
    LEFT(t.transaction_id, 20) AS 'Transaction ID',
    t.payee_identifier AS 'Payee',
    CONCAT(t.amount, ' ', t.currency) AS 'Amount',
    t.status AS 'Status',
    LEFT(COALESCE(t.external_id, 'N/A'), 35) AS 'Mastercard Payment ID',
    DATE_FORMAT(t.started_at, '%H:%i:%s') AS 'Time'
FROM transfers t
WHERE t.workflow_instance_key IS NOT NULL
ORDER BY t.id DESC
LIMIT 15;

SELECT '' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT '  PAYMENT STATUS BREAKDOWN' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';

-- Status distribution
SELECT
    t.status AS 'Status',
    COUNT(*) AS 'Count',
    CONCAT(ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM transfers WHERE workflow_instance_key IS NOT NULL AND started_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)), 1), '%') AS 'Percentage',
    MIN(DATE_FORMAT(t.started_at, '%H:%i:%s')) AS 'First',
    MAX(DATE_FORMAT(t.started_at, '%H:%i:%s')) AS 'Last'
FROM transfers t
WHERE t.workflow_instance_key IS NOT NULL
  AND t.started_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY t.status
ORDER BY COUNT(*) DESC;

SELECT '' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT '  FAILED PAYMENTS (If Any)' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';

-- Failed transfer details
SELECT
    t.id AS 'ID',
    LEFT(t.transaction_id, 20) AS 'Transaction ID',
    t.payee_identifier AS 'Payee',
    CONCAT(t.amount, ' ', t.currency) AS 'Amount',
    LEFT(COALESCE(t.error_information, 'No error info'), 50) AS 'Error',
    LEFT(COALESCE(t.status_detail, 'N/A'), 40) AS 'Status Detail',
    DATE_FORMAT(t.started_at, '%H:%i:%s') AS 'Time'
FROM transfers t
WHERE t.status = 'FAILED'
  AND t.workflow_instance_key IS NOT NULL
  AND t.started_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
ORDER BY t.id DESC
LIMIT 10;

SELECT '' AS '';
SELECT '════════════════════════════════════════════════════════════════' AS '';
SELECT 'Report generated:', NOW() AS '' FROM dual;
SELECT '════════════════════════════════════════════════════════════════' AS '';
EOF

# Execute query
if [ "$USE_KUBECTL" = true ]; then
    echo -e "${YELLOW}Connecting via kubectl...${NC}"
    echo "  Namespace: paymenthub"
    echo "  Pod: operationsmysql-0"
    echo "  Database: $DATABASE"
    echo ""

    echo "$SQL_QUERY" | kubectl exec -i -n paymenthub operationsmysql-0 -- \
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DATABASE"
else
    echo -e "${YELLOW}Connecting to MySQL...${NC}"
    echo "  Host: $MYSQL_HOST"
    echo "  Port: $MYSQL_PORT"
    echo "  User: $MYSQL_USER"
    echo "  Database: $DATABASE"
    echo ""

    echo "$SQL_QUERY" | mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DATABASE"
fi

echo ""
echo -e "${GREEN}✓ Report complete${NC}"
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Quick Commands${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "View Mastercard connector logs:"
echo "  kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100 | grep -A 10 'MASTERCARD CBS'"
echo ""
echo "View GovStack workflow logs:"
echo "  kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs --tail=100 | grep 'GovStack'"
echo ""
echo "View operations-app logs (if deployed):"
echo "  kubectl logs -n paymenthub -l app=ph-ee-operations-app --tail=100"
echo ""
echo "Check pod status:"
echo "  kubectl get pods -n mastercard-demo"
echo ""
echo "Query specific payment by Mastercard Payment ID:"
echo "  kubectl exec -n paymenthub operationsmysql-0 -- mysql -uroot -pmysql operations_app -e \\"
echo "    \"SELECT * FROM transfers WHERE external_id = 'rem_XXX' \\\\G\""
echo ""
