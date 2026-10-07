# DDOService

Scripts and docs for a self-hosted automation server: a Proxmox VM running n8n, a local language
model (Ollama + Mistral 7B), Qdrant and a WhatsApp gateway (WAHA).

**Start with [`docs/SYSTEM-DESIGN.md`](docs/SYSTEM-DESIGN.md)**: how it fits together, why each
piece was chosen, the memory budget, and what went wrong while building it.

| Order | File | Run on | What it does |
|---|---|---|---|
| 1 | [`post-install.sh`](post-install.sh) | A fresh Debian 13 VM, as root | Essentials, SSH, QEMU guest agent, sudo, memory tuning |
| 2 | [`docker-install.sh`](docker-install.sh) | The VM, as root | Docker Engine and the Compose plugin |
| 3 | [`stack/deploy.sh`](stack/deploy.sh) | The VM, as root | Deploys the stack to `/opt/automation`, generates its secrets, pulls the model, runs checks |
| 4 | [`backup/`](backup/) | The VM, as root | Nightly backup to Google Drive or self-hosted storage, and how to restore |

Each script can be run straight from GitHub, which avoids copy-pasting into the Proxmox console:

```
wget -qO- https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/stack/deploy.sh | bash
```

Secrets are generated on the VM into `/opt/automation/.env` and never committed. This repo is
public, so business data and workflow exports live elsewhere.
