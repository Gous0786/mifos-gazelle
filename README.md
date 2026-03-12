# Mifos Gazelle
[![Mifos](https://img.shields.io/badge/Mifos-Gazelle-blue)](https://github.com/openMF/mifos-gazelle)

> Mifos Gazelle is a Mifos Digital Public Infrastructure as a Solution (DaaS) deployment tool v1.1.0 — July 2025.
> Deploys MifosX (core banking), Payment Hub EE (payment orchestration), and Mojaloop vNext Beta1 (payment switch) on Kubernetes with a single command.

## Quick Start

```bash
git clone --branch master https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle
sudo ./run.sh -u $USER -m deploy -a all
```

See [Deployment Guide](docs/MIFOS-GAZELLE-README.md) for prerequisites and full instructions.

## Documentation

| Guide | Contents |
|-------|----------|
| [Deployment Guide](docs/MIFOS-GAZELLE-README.md) | Install, configure, test end-to-end payments, FAQ |
| [Config File](docs/CONFIG-FILE-SUPPORT.md) | `config.ini` schema, `startup_timeout`, DockerHub auth |
| [Bulk Payment Tools](docs/BULK.md) | Submit/verify G2P batch payments, GovStack mode |
| [GovStack Architecture](docs/GOVSTACK.md) | G2P bulk disbursement design and troubleshooting |
| [Local Development](docs/LOCALDEV.md) | hostPath mounts for iterating on Payment Hub EE code |
| [vNext Standalone](docs/VNEXT-README.md) | Deploy Mojaloop vNext on its own |
| [Raspberry Pi](docs/RASPBERRY-PI-README.md) | Ubuntu setup on Raspberry Pi 5 |
| [Release Notes](docs/RELEASE-NOTES.md) | v1.1.0 changes and component versions |
| [Mastercard CBS](docs/mastercard/MASTERCARD.md) | Cross-border payment connector for Payment Hub EE — overview, integration, and quick start |
| [Mastercard CBS — Operator Guide](docs/mastercard/OPERATOR_DEPLOYMENT_GUIDE.md) | Full config reference, CR spec, operator lifecycle, and troubleshooting |

## Companion Tools

- **[Demo Creator](https://github.com/openMF/mifos-gazelle-demo-creator)** — TUI to author, manage, and deploy Gazelle demos
- **[Demo Runtime](https://github.com/openMF/mifos-gazelle-demo-runtime)** — Web UI to run interactive demos against a live Gazelle deployment

## Additional Resources

- [Contributing Guidelines](CONTRIBUTING.md)
- [License Information](LICENSE.md)
- [Architecture](ARCHITECTURE.md)
- [Mifos Slack](https://mifos.slack.com) — join the `#mifos-gazelle` channel
