# Config.ini Support in Mifos Gazelle

This document explains how Mifos Gazelle uses a centralized `config.ini` for non-path configuration, how it integrates with command-line flags, what must remain in code (paths/topology), and what happens if `config.ini` is missing. It also provides a schema, examples, and troubleshooting guidance.


## Table of Contents

- [Overview](#overview)
- [What moved vs. stayed](#what-moved-vs-stayed)
- [File locations](#file-locations)
- [Dependencies](#dependencies)
- [Loading and precedence](#loading-and-precedence)
- [Flow: config.ini to deployer](#flow-configini-to-deployer)
- [INI schema](#ini-schema)
- [Example](#example)
- [Operational notes](#operational-notes)
- [Validation and troubleshooting](#validation-and-troubleshooting)
- [FAQ](#faq)


## Overview

Mifos Gazelle now reads most non-path runtime settings from a **config.ini** file using `crudini`, making deployments easier to customize without editing scripts. Command-line flags still control operational mode and a few runtime toggles. Path and repository layout variables remain in code.

## Usage:

**Default run (uses `config/config.ini`):**
```
sudo ./run.sh       
```

**Run with a custom config file:**
```
sudo ./run.sh -f ./path/to/config/file
```

## What moved vs. stayed

- **Moved to config.ini:** non-path values such as namespaces, release names, domains, repo links and branches, and app enablement flags. This reduces script edits across environments.
- **Stayed in code (`config.sh`):** filesystem topology like `BASE_DIR`, repos directory, chart directories, and manifest locations, which are stable and path-based.


## File locations

- **Default file:** `config/config.ini` in the repository.  
  Pass a custom file with `-f /path/to/custom.ini` when invoking `run.sh`. This supports per-environment variants checked into docs or ops repos.
- **Suggested layout:** maintain `config.dev.ini`, `config.staging.ini`, `config.prod.ini`, and supply the desired file at runtime with `-f`.


## Dependencies

- **crudini** is required to read INI sections and keys. The launcher attempts to install via `apt/dnf/yum` if missing; otherwise installation must be completed manually on the host.
- **jq** is required for some template and data replacement flows referenced by helper functions; ensure it is available on the host running the scripts.


## Loading and precedence

- **Load order:**
  1. Read `config.ini` using crudini, populating global variables and exporting them for downstream functions and Helm/kubectl calls.  
  2. Apply CLI overrides for a limited set of flags: mode, k8s user, apps, debug, redeploy, k8s distro, and k8s user version. CLI takes precedence for these flags only.

- **Important behavior:**
  - If `config.ini` is absent or missing required keys, the run will fail later even if CLI flags are provided, because many operational variables (namespaces, release names, repo URLs/branches, DB/service settings) are sourced only from `config.ini`. Always provide a complete file.
  - **App selection:** INI can enable apps via `enabled=true` in per-app sections; CLI `-a` overrides and accepts comma- or space-separated lists, with special handling for `all`.


## Flow: config.ini to deployer

- **Entry:** `run.sh` sources logger and commandline; commandline.sh sources configuration, environment setup, and deployer modules to prepare functions and defaults. This ensures a single entrypoint and predictable initialization.
- **Resolve config file:** uses `config/config.ini` by default, `-f` overrides the path. The chosen path is logged for visibility.
- **Load config.ini:** reads sections/keys and exports non-path variables (namespaces, release names, repo links/branches, domain/version), and builds the apps list from per-app enabled flags when `-a` is not provided. This centralizes environment parameters in one file.
- **Apply CLI overrides (limited):** CLI can override only `mode, k8s_user, apps, debug, redeploy, k8s_distro, k8s_user_version`. CLI takes precedence for these flags only.
- **Validate effective inputs:** enforces valid `mode (deploy|cleanapps|cleanall)`, acceptable apps (`vnext, phee, mifosx, infra, or all` without mixing), and booleans for debug/redeploy.
- **Dispatch to deployer:**
  - `deploy → envSetupMain → deployApps(apps, redeploy)`
  - `cleanapps → deleteApps(apps)`
  - `cleanall → deleteApps(all) → envSetupMain(cleanup)`

> ⚠️ **Important:** `config.ini` is required. Many operational variables are not CLI-overridable. Without a complete file, runs fail later even if `mode/user/apps` are supplied via CLI. Always pass a valid `config.ini` (or use `-f` to point to one).


## INI schema

The INI is organized by sections. Keys below are representative; align with the project’s override map and app modules.

- [general]
    - GAZELLE_DOMAIN: base domain.
    - GAZELLE_VERSION: documentation/version banner.
    - logging: write full deployment log to `/tmp/gazelle-YYYYMMDD-HHMM.log` (`true`/`false`).
    - **startup_timeout**: maximum seconds to wait for pods to be Running and services fully initialised before running post-deploy data generation steps. The main bottleneck is Fineract’s Liquibase migrations on first boot. Default: `600` (10 min). Slow hardware / Raspberry Pi: `1800`. Managed cold-start: `900`.
- [dockerhub] (optional)
    - DOCKERHUB_USERNAME, DOCKERHUB_PASSWORD, DOCKERHUB_EMAIL: Docker Hub credentials for authenticated image pulls. Raises anonymous rate limit (100 pulls/6 h) to authenticated limit. Leave commented out to use anonymous pulls. When set, `src/deployer/deployer.sh` creates a `dockerhub-secret` K8s secret in each namespace via `src/utils/k3s-docker-login.sh`.
- [environment]
    - user: execution username; supports literal $USER which expands at runtime.
- [infra]
    - INFRA_NAMESPACE: namespace for infra components.
    - INFRA_RELEASE_NAME: Helm release for infra chart.
- [vnext]
    - VNEXT_NAMESPACE, VNEXT_REPO_LINK, VNEXTBRANCH, VNEXTREPO_DIR, and enabled flag.
- [phee]
    - PH_NAMESPACE, PH_RELEASE_NAME, PH_REPO_LINK, PHBRANCH, PHREPO_DIR, PH_EE_ENV_TEMPLATE_REPO_LINK, PH_EE_ENV_TEMPLATE_REPO_BRANCH, PH_EE_ENV_TEMPLATE_REPO_DIR, and enabled.
- [mifosx]
    - MIFOSX_NAMESPACE, MIFOSX_REPO_LINK, MIFOSX_BRANCH, MIFOSX_REPO_DIR, and enabled.
- [mysql] (as applicable)
    - MYSQL_SERVICE_NAME, MYSQL_SERVICE_PORT, LOCAL_PORT, MAX_WAIT_SECONDS, MYSQL_HOST for dependent flows.

## Example

Example minimal config.ini:
```
[general]
mode = deploy
GAZELLE_DOMAIN = mifos.gazelle.test
GAZELLE_VERSION= 1.1.0

[environment]
user = $USER

[mysql]
MYSQL_SERVICE_NAME = mysql
MYSQL_SERVICE_PORT = 3306
LOCAL_PORT = 3307
MAX_WAIT_SECONDS = 60
MYSQL_HOST = 127.0.0.1

[infra]
enabled = false
INFRA_NAMESPACE = infra
INFRA_RELEASE_NAME = infra

[mifosx]
enabled = true
MIFOSX_NAMESPACE = mifosx
MIFOSX_REPO_DIR= mifosx
MIFOSX_BRANCH = gazelle-1.1.0
MIFOSX_REPO_LINK = https://github.com/openMF/mifosx-docker.git

[vnext]
enabled = false
VNEXTBRANCH = beta1
VNEXTREPO_DIR= vnext
VNEXT_NAMESPACE = vnext
VNEXT_REPO_LINK = https://github.com/mojaloop/platform-shared-tools.git

[phee]
enabled = true
PHBRANCH = master
PHREPO_DIR= phlabs
PH_NAMESPACE = paymenthub
PH_RELEASE_NAME = phee
PH_REPO_LINK = https://github.com/openMF/ph-ee-env-labs.git
PH_EE_ENV_TEMPLATE_REPO_LINK = https://github.com/openMF/ph-ee-env-template.git
PH_EE_ENV_TEMPLATE_REPO_BRANCH = v1.13.0-gazelle-1.1.0
PH_EE_ENV_TEMPLATE_REPO_DIR= ph_template
```

## Operational notes

- Always ensure `config.ini` exists and is complete for the target environment. Without it, non-path variables will not be available via CLI and workflows will fail in deploy or cleanup phases.
- Keep secrets out of INI; use Kubernetes Secrets and environment scoping. Treat `config.ini` as environment metadata (namespaces, domains, repos) rather than a secrets store.
- Maintain separate INIs per environment and version-control them where appropriate. Use `-f` to target the right file.


## Validation and troubleshooting

- **Validation rules:**
  - `mode` requires `deploy|cleanapps|cleanall`.
  - `apps` must be one of `vnext, phee, mifosx, infra` or `all`.  
    `all` cannot be combined with specific app names.

- **Common issues:**
  - Missing required keys in `config.ini`: add sections/keys as per schema.
  - `crudini` not installed: install via system package manager.
  - Boolean flags: use `true/false` consistently for enabled and debug/redeploy toggles.

- **Debugging:**
  - Use debug mode to increase verbosity and verify effective values at runtime.
  - Confirm `KUBECONFIG` and cluster access if `helm/kubectl` steps appear to hang. 
  - If `$USER` is used as the user in `config.ini`, the script might interpret it as `root` since it is initiated with `sudo`. As a solution, use the specific username of the device instead (though a logic to handle this is already in place).

## FAQ

- **Why don’t all variables support CLI overrides?**  
  To keep CLI focused on operational flow while environment/stateful parameters live in a single source of truth (`config.ini`). This reduces command complexity and accidental drift.

- **Can multiple INI files be layered?**  
  Use a single file per run. For layering, pre-merge files with `crudini --merge` or generate a composed INI before invoking `run.sh -f`.

