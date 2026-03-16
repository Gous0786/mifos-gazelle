#!/usr/bin/env bash
# pull-images-with-timing.sh
# Pulls and imports container images (grouped by namespace) into K3s containerd,
# logging timing per image, per namespace, and overall.

set -euo pipefail

INPUT_FILE=${1:-images-by-namespace.csv}
LOG_FILE=pull-import-report.log
TMP_DIR=$(mktemp -d)

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "❌ Input file '$INPUT_FILE' not found!"
  exit 1
fi

echo "Docker Hub login (for higher rate limits)..."
docker login

declare -A namespace_totals
declare -A namespace_counts

echo "Starting pull + import process..."
overall_start=$(date +%s)

# Extract all namespaces
namespaces=$(cut -d',' -f1 "$INPUT_FILE" | sort -u)

for ns in $namespaces; do
  echo -e "\n===== Namespace: $ns =====" | tee -a "$LOG_FILE"
  ns_start=$(date +%s)
  ns_total_time=0
  ns_count=0

  # Extract images for this namespace
  grep "^\"*$ns\"*," "$INPUT_FILE" | cut -d',' -f2- | tr -d '"' | while read -r image; do
    [[ -z "$image" ]] && continue
    echo "→ Pulling $image..."
    img_start=$(date +%s)

    if docker pull "$image" >/dev/null 2>&1; then
      pull_time=$(( $(date +%s) - img_start ))
      echo "   Pulled in ${pull_time}s — importing to K3s..."
      imp_start=$(date +%s)
      if docker save "$image" | sudo k3s ctr images import - >/dev/null 2>&1; then
        import_time=$(( $(date +%s) - imp_start ))
        total_time=$((pull_time + import_time))
        echo "   ✅ Imported in ${import_time}s (Total: ${total_time}s)"
        echo "$ns,$image,$pull_time,$import_time,$total_time" >> "$TMP_DIR/timing.csv"
      else
        echo "   ⚠️ Import failed for $image" | tee -a "$LOG_FILE"
      fi
    else
      echo "   ⚠️ Pull failed for $image" | tee -a "$LOG_FILE"
    fi
  done

  ns_end=$(date +%s)
  ns_elapsed=$((ns_end - ns_start))
  echo "Namespace $ns completed in ${ns_elapsed}s" | tee -a "$LOG_FILE"
done

overall_end=$(date +%s)
overall_elapsed=$((overall_end - overall_start))

echo -e "\n===== TOTAL SUMMARY ====="
echo "Overall time: ${overall_elapsed}s"

# Generate summary per namespace if we have timing data
if [[ -f "$TMP_DIR/timing.csv" ]]; then
  echo -e "\nPer-namespace summary:" | tee -a "$LOG_FILE"
  awk -F',' '
  {
    ns=$1; total[ns]+=$5; count[ns]++
  }
  END {
    for (n in total)
      printf "%-20s %4d images, %6ds total\n", n, count[n], total[n]
  }' "$TMP_DIR/timing.csv" | tee -a "$LOG_FILE"
fi

echo -e "\nFull timing log written to: $LOG_FILE"
