# Mifos Gazelle Deployment Guide

[![Mifos](https://img.shields.io/badge/Mifos-Gazelle-blue)](https://github.com/openMF/mifos-gazelle)

> Mifos Gazelle v1.1.0 — July 2025. Deploys MifosX, Payment Hub EE, and Mojaloop vNext Beta1 on Kubernetes.

## Table of Contents
- [Goal](#goal-of-mifos-gazelle)
- [Features](#mifos-gazelle-features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Options](#deployment-options)
- [What to Do Next](#what-to-do-next)
- [Test a Payment](#execute-a-transfer-from-greenbank-to-bluebank)
- [Application Deployment Modes](#application-deployment-modes)
- [Cleanup](#cleanup)
- [Accessing Deployed Applications](#accessing-deployed-applications-dpgs)
- [DockerHub Authentication](#dockerhub-authentication)
- [Kibana Dashboards](#kibana-dashboards)
- [Demo Tools](#demo-tools)
- [Adding Tenants to MifosX](#adding-tenants-to-mifosx)
- [Helm Test](#helm-test)
- [Development Status](#development-status)
- [Known Issues](#known-issues)
- [FAQ](#faq)
- [Version Information](#version-information)

---

## Goal of Mifos Gazelle

Mifos Gazelle provides a trivially simple installation and configuration mechanism for a Digital Public Goods DaaS construct — initially MifosX (core banking), Payment Hub EE (payment orchestration), and Mojaloop vNext Beta1 (payment switch). The goal is a rapidly deployable showcase and lab environment that others can build on.

> **IMPORTANT:** v1.1.0 is recommended for development, test, and demonstration only. Security hardening has not yet occurred.

---

## Mifos Gazelle Features

- Installs each or all 3 DPGs in a reliable, repeatable way
- Bash scripts designed to be readable and modifiable
- Full installation in ~15 minutes on capable hardware
- Fully functioning MifosX with multi-tenant support
- Fully functioning vNext (Beta1) with integrated test environment and pre-loaded demo data
- Deployed Payment Hub EE with Operations Web UI

---

## Prerequisites

- Ubuntu 22.04 or 24.04 LTS (x86_64 or ARM64)
- 24 GB RAM minimum (less if deploying individual components)
- 30 GB+ free space in home directory
- Non-root user with sudo privileges

---

## Quick Start

```bash
cd $HOME
git clone --branch master https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle
sudo ./run.sh -u $USER -m deploy -a all
```

The deployment takes 10–20 minutes. MifosX's Liquibase migrations are the main bottleneck on first boot. See [startup_timeout](#startup_timeout) if deployments time out on slower hardware.

---

## Deployment Options

| Flag | Description | Values |
|------|-------------|--------|
| `-h` | Help | — |
| `-u` | Non-root user | `$USER` |
| `-m` | Mode | `deploy`, `cleanapps`, `cleanall` |
| `-d` | Verbose output | `true`, `false` |
| `-a` | Components to deploy | `all`, `vnext`, `mifosx`, `phee` |
| `-f` | Config file | path to `.ini` (default: `config/config.ini`) |

---

## What to Do Next

Once `kubectl get pods -A` shows all pods running:

- Start k9s: `~/local/bin/k9s`
- Inspect MifosX DB: `~/mifos-gazelle/src/utils/mysql-client-mifos.sh`
- Inspect PaymentHub DB: `~/mifos-gazelle/src/utils/mysql-client-mifos.sh -h operationsmysql.paymenthub.svc.cluster.local -p ethieTieCh8ahv -u root -d mysql`
- Browse to deployed apps: http://mifos.mifos.gazelle.test, http://vnextadmin.mifos.gazelle.test, http://ops.mifos.gazelle.test
- DPG documentation:
  - vNext: https://github.com/mojaloop/platform-shared-tools/blob/main/packages/deployment/docker-compose-apps/README.md
  - MifosX: https://docs.mifos.org/core-banking-and-embedded-finance/core-banking
  - Payment Hub EE: https://mifos.gitbook.io/docs
- Join the `#mifos-gazelle` channel on [Mifos Slack](https://mifos.slack.com)

### startup_timeout

MifosX runs Liquibase database migrations on first boot, which can take several minutes. The `startup_timeout` setting in `config/config.ini` controls how long the deployment waits before running post-deploy data generation steps.

```ini
[general]
startup_timeout = 600   # 10 min — default for modern hardware
# startup_timeout = 1800  # 30 min — use for Raspberry Pi or slow disks
```

**To check MifosX pod status during startup:**
```bash
# Watch pod states
kubectl get pods -n mifosx -w

# Follow Fineract startup logs (Liquibase migration progress)
kubectl logs -n mifosx -l app=fineract-server --tail=100 -f

# Check for errors across the cluster
./src/utils/k8s-error-summary.py
```

If you see a timeout error during deployment, increase `startup_timeout` in `config/config.ini` and re-run.

---

## Execute a Transfer from Greenbank to Bluebank

When all 3 DPGs are deployed, demonstration data is pre-loaded so you can immediately run a payment from a Greenbank customer to a Bluebank customer via the vNext switch.

```bash
./src/utils/make-payment.sh
```

To view the resulting transaction history across all tenants:
```bash
./src/utils/view-mifos-transactions.py -c config/config.ini
```

**Observe the results:**
- **Zeebe Operate** at https://zeebe-operate.mifos.gazelle.test (login: demo/demo) → Dashboard → PayerFundTransfer-greenbank → see the BPMN execution path (blue line)
- **Payment Hub Operations Web** at https://ops.mifos.gazelle.test → paymenthub → transfers
- **vNext Admin UI** at https://vnextadmin.mifos.gazelle.test (login: admin/superMegaPass) → quotes and transfers
- **MifosX** at http://mifos.mifos.gazelle.test (login: mifos/password, tenant: greenbank or bluebank) → institution → clients → account → transactions (payer starts at $5000)

---

## Application Deployment Modes

```bash
sudo ./run.sh -u $USER -m deploy -a vnext   # Mojaloop vNext only
sudo ./run.sh -u $USER -m deploy -a mifosx  # MifosX only
sudo ./run.sh -u $USER -m deploy -a phee    # Payment Hub EE only
```

---

## Cleanup

```bash
sudo ./run.sh -u $USER -m cleanall           # Remove everything including k3s
sudo ./run.sh -u $USER -m cleanapps          # Remove all apps, keep k3s
sudo ./run.sh -u $USER -m cleanapps -a mifosx
sudo ./run.sh -u $USER -m cleanapps -a phee
sudo ./run.sh -u $USER -m cleanapps -a vnext
```

---

## Accessing Deployed Applications (DPGs)

Add the following to your **local** `/etc/hosts` (or Windows `C:\Windows\System32\drivers\etc\hosts`), where `<VM-IP>` is the server's IP address.

### MifosX

```
# Linux/macOS
<VM-IP> fineract.mifos.gazelle.test mifos.mifos.gazelle.test

# Windows (one per line)
<VM-IP> mifos.mifos.gazelle.test
<VM-IP> fineract.mifos.gazelle.test
```

Login at http://mifos.mifos.gazelle.test with user `mifos` / password `password`. Select tenant: `default`, `greenbank`, or `bluebank`.

### vNext

```
# Linux/macOS
<VM-IP> vnextadmin.mifos.gazelle.test elasticsearch.mifos.gazelle.test kibana.mifos.gazelle.test mongoexpress.mifos.gazelle.test kafkaconsole.mifos.gazelle.test fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test redpanda-console.mifos.gazelle.test

# Windows (one per line)
<VM-IP> vnextadmin.mifos.gazelle.test
<VM-IP> elasticsearch.mifos.gazelle.test
<VM-IP> kibana.mifos.gazelle.test
<VM-IP> mongoexpress.mifos.gazelle.test
<VM-IP> kafkaconsole.mifos.gazelle.test
<VM-IP> fspiop.mifos.gazelle.test
<VM-IP> bluebank.mifos.gazelle.test
<VM-IP> greenbank.mifos.gazelle.test
<VM-IP> redpanda-console.mifos.gazelle.test
```

### Payment Hub EE

```
# Linux/macOS
<VM-IP> ops.mifos.gazelle.test kibana-phee.mifos.gazelle.test zeebe-operate.mifos.gazelle.test

# Windows (one per line)
<VM-IP> ops.mifos.gazelle.test
<VM-IP> kibana-phee.mifos.gazelle.test
<VM-IP> zeebe-operate.mifos.gazelle.test
```

---

## DockerHub Authentication

Docker Hub applies rate limits to anonymous image pulls (100 pulls per 6 hours per IP). If you hit rate limit errors during deployment, authenticate with a Docker Hub account to raise the limit.

**Set credentials in `config/config.ini`:**
```ini
[dockerhub]
DOCKERHUB_USERNAME = your-dockerhub-username
DOCKERHUB_PASSWORD = your-dockerhub-password
DOCKERHUB_EMAIL    = your-email@example.com
```

Alternatively, set environment variables before running:
```bash
export DOCKERHUB_USERNAME=your-username
export DOCKERHUB_PASSWORD=your-password
export DOCKERHUB_EMAIL=your-email@example.com
sudo -E ./run.sh -u $USER -m deploy -a all
```

**How it works:** When creating each Kubernetes namespace, `src/deployer/deployer.sh` calls `src/utils/k3s-docker-login.sh`, which creates a `dockerhub-secret` Kubernetes secret and patches all service accounts in that namespace with `imagePullSecrets`. If credentials are not set, the script exits silently and anonymous pulls are used.

---

## Kibana Dashboards

Payment Hub EE ships with pre-built Kibana visualizations and dashboards for monitoring payment flows.

**Import dashboards after deployment:**
```bash
# Default URL (kibana.mifos.gazelle.localhost)
./src/utils/kibana-dashboard-setup.sh

# Custom Kibana URL
export KIBANA_URL=https://kibana-phee.mifos.gazelle.test
./src/utils/kibana-dashboard-setup.sh
```

The script imports objects from `repos/ph_template/Kibana Visualisations/` in the correct order: index patterns → searches → visualizations → lenses → dashboards. It reports a success/failure count on completion.

Access Kibana at http://kibana-phee.mifos.gazelle.test (add to `/etc/hosts` as shown in [Payment Hub EE Host Configuration](#payment-hub-ee)).

---

## Demo Tools

Two companion tools exist for creating and presenting interactive demos using a live Gazelle deployment:

### Demo Creator

[mifos-gazelle-demo-creator](https://github.com/openMF/mifos-gazelle-demo-creator) — a Python terminal UI (TUI) for authoring, managing, and syncing demos to JFrog Artifactory.

```bash
git clone https://github.com/openMF/mifos-gazelle-demo-creator.git
cd mifos-gazelle-demo-creator
bash ./scripts/install_dependencies.sh
just setup && just run
```

Features: create demo steps, upload to JFrog, trigger Gazelle deployments with live log output.

### Demo Runtime

[mifos-gazelle-demo-runtime](https://github.com/openMF/mifos-gazelle-demo-runtime) — a React web app for running interactive demos against a live Gazelle deployment.

```bash
git clone https://github.com/openMF/mifos-gazelle-demo-runtime.git
cd mifos-gazelle-demo-runtime && npm install && npm start
# Open http://localhost:3000
```

Features: split-panel interface (instructions on the left, live DPG iframe on the right), demo catalogue loaded from JFrog, product and platform demo categories.

---

## Adding Tenants to MifosX

Mifos Gazelle deploys three default tenants: `default`, `greenbank`, and `bluebank`.

1. Edit `config/mifos-tenant-config.csv` — add your tenant names
2. Apply: `src/utils/data-loading/update-mifos-tenants.sh -f ./config/mifos-tenant-config.csv`
3. Restart fineract-server in k9s (`Ctrl-k` on the pod) — Kubernetes will recreate it
4. Watch Liquibase create the new schema: in k9s, select the new pod and press `l` for logs

---

## Helm Test

Payment Hub EE includes Helm tests (currently ~90% pass rate; reconfiguration ongoing).

```bash
helm test phee
kubectl logs -n paymenthub ph-ee-integration-test-gazelle

# Copy test report to /tmp
~/mifos-gazelle/src/utils/copy-report-from-pod.sh
# Browse: /tmp/mydir.XXXXXX/tests/test/index.html
```

> Note: The test pod times out after 90 minutes. Delete it before re-running `helm test phee`.

---

## Development Status

> Limitations below are those of the Mifos Gazelle configuration, not of the underlying DPGs.

- Operations-Web UI can display transfers; bulk transfer UI work is ongoing
- Payment Hub EE v1.13.0 deployed; integration test image tag `v1.6.2-gazelle`
- ARM64 supported for all 3 DPGs; Raspberry Pi 4 has a MongoDB limitation (requires ARMv8.2A)
- Memory reduction is a high priority (target: all 3 DPGs on 16GB)
- Kubernetes operator work (openMF/mifos-operators) planned for a future release

---

## Known Issues

- On 24GB systems, occasional pod OOM events require a pod restart or re-run
- Single-node only (no technical barrier; just not yet tested multi-node)
- Operations-Web integration pending (ph-ee-operations-web PRs #98, #99)
- Postman collections not yet fully adapted to Gazelle environment
- Some issues on older Intel/Opteron hardware with nginx, MongoDB, and ElasticSearch
- **Security:** the deployment is not hardened — use for dev/test/demo only

---

## FAQ

### Deployment times out waiting for pods

Increase `startup_timeout` in `config/config.ini` (default 600 s). On Raspberry Pi or slow disks, use 1800. See [startup_timeout](#startup_timeout).

### Docker Hub rate limit errors during deployment

Set DockerHub credentials in `config/config.ini` or as environment variables. See [DockerHub Authentication](#dockerhub-authentication).

### Operations-Web shows "REJECTED" or "null" status during batch processing

This is expected. During batch processing, individual transfer records pass through intermediate states that can appear as `REJECTED`, `null`, or similar in the Operations-Web UI. **The correct final status is set when processing completes** (typically 60–90 seconds after batch submission). Refresh the page after processing finishes to see accurate results.

The database is always the authoritative source:
```bash
kubectl exec -n paymenthub operationsmysql-0 -- env MYSQL_PWD=ethieTieCh8ahv mysql -uroot operations_app \
  -e "SELECT batch_id, total_transactions, completed, status FROM batches ORDER BY id DESC LIMIT 5\G"
```

### MifosX fails to start / Liquibase migration error

Check the fineract-server logs:
```bash
kubectl logs -n mifosx -l app=fineract-server --tail=200
kubectl describe pod -n mifosx -l app=fineract-server
```

If the pod keeps restarting, check MySQL is healthy:
```bash
kubectl get pods -n infra
kubectl logs -n infra -l app=mysql --tail=50
```

### Cannot reach web UIs in browser

Ensure the `/etc/hosts` entries (or Windows hosts file) are set on the machine where your **browser** runs, pointing to the Gazelle server IP. See [Accessing Deployed Applications](#accessing-deployed-applications-dpgs).

---

## Version Information

- [Release Notes v1.1.0](./RELEASE-NOTES.md)
- Payment Hub EE: v1.13.0 (https://mifos.gitbook.io/docs/payment-hub-ee/release-notes/v1.13.0)
- Mojaloop vNext: Beta1
- MifosX (Apache Fineract): v1.11.0 (gazelle-1.2.0 branch)
