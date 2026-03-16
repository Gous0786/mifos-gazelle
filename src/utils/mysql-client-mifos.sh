#!/usr/bin/env bash 
# small utility  to 
#    run mysql-client in k8s and connect to mysql inside cluster 
# 

# MySQL connection credentials
MYSQL_USER="root"
MYSQL_PASSWORD="mysqlpw"
MYSQL_HOST="mysql.infra.svc.cluster.local"
MYSQL_DATABASE="mysql"
MYSQL_IMAGE="bitnamilegacy/mysql:5.7"

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo "Connect to MySQL instance in Kubernetes cluster"
    echo ""
    echo "Options:"
    echo "  -u, --user        MySQL username (default: $MYSQL_USER)"
    echo "  -p, --password    MySQL password"
    echo "  -h, --host        MySQL host (default: $MYSQL_HOST)"
    echo "  -d, --database    MySQL database (default: $MYSQL_DATABASE)"
    echo "  --help           Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            MYSQL_USER="$2"
            shift 2
            ;;
        -p|--password)
            MYSQL_PASSWORD="$2"
            shift 2
            ;;
        -h|--host)
            MYSQL_HOST="$2"
            shift 2
            ;;
        -d|--database)
            MYSQL_DATABASE="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Construct the command
KUBECTL_CMD="kubectl run mysql-client --rm -it --image=${MYSQL_IMAGE} --restart=Never -- mysql -h ${MYSQL_HOST} -u ${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE}"

# Echo the command (with password masked)
echo "Executing command:"
echo "${KUBECTL_CMD//-p${MYSQL_PASSWORD}/-p********}"
echo "---"

# Run the kubectl command
eval "${KUBECTL_CMD}"