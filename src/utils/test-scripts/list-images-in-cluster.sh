#!/usr/bin/env bash
# Lists all pods across all namespaces with their image repo/name:tag

set -euo pipefail

# Check dependencies
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

echo "Namespace,Pod,Container,Image"

# Query all pods in all namespaces and extract relevant fields
kubectl get pods -A -o json | jq -r '
  .items[] |
  .metadata.namespace as $ns |
  .metadata.name as $pod |
  (
    .spec.containers[]?,
    .spec.initContainers[]?,
    .spec.ephemeralContainers[]?
  ) |
  [$ns, $pod, .name, .image] |
  @csv
'
