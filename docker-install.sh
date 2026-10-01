#!/usr/bin/env bash
# Docker install for the automation-stack VM (Debian 13).
# Follows Part 4 of automation-money-guide-research.html: Docker CE with the
# Compose v2 plugin via get.docker.com. Adds the login user (not root, which
# needs no group) to the docker group.
#
#   sudo bash docker-install.sh [username]   # username defaults to the uid-1000 user
#
# Safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo bash $0)" >&2
  exit 1
fi

USERNAME="${1:-$(getent passwd 1000 | cut -d: -f1)}"

if command -v docker &>/dev/null; then
  echo "==> Docker already installed: $(docker --version)"
else
  echo "==> Installing Docker"
  apt-get update
  apt-get install -y curl ca-certificates
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if [[ -n "$USERNAME" ]] && id "$USERNAME" &>/dev/null; then
  echo "==> Adding $USERNAME to docker group"
  usermod -aG docker "$USERNAME"
else
  echo "==> No login user found; skipping docker group"
fi

echo "==> Test run"
docker run --rm hello-world | grep -m1 'Hello from Docker!'

echo
echo "Done."
echo "  $(docker --version)"
echo "  $(docker compose version)"
[[ -n "$USERNAME" ]] && echo "  Log out and back in as $USERNAME to run docker without root."
