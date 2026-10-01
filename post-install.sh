#!/usr/bin/env bash
# Post-install setup for the automation-stack VM (Debian 13 on Proxmox).
# Follows Part 2 of automation-money-guide-research.html, plus SSH,
# the QEMU guest agent and sudo for the login user.
#
#   sudo bash post-install.sh [username]              # username defaults to the uid-1000 user
#   sudo bash post-install.sh [username] --remove-desktop
#
# Safe to re-run.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: su -  (or sudo bash $0)" >&2
  exit 1
fi

REMOVE_DESKTOP=false
USERNAME=""
for arg in "$@"; do
  case "$arg" in
    --remove-desktop) REMOVE_DESKTOP=true ;;
    *) USERNAME="$arg" ;;
  esac
done
USERNAME="${USERNAME:-$(getent passwd 1000 | cut -d: -f1)}"

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating system"
apt-get update
apt-get upgrade -y

echo "==> Installing essentials"
apt-get install -y \
  curl wget git vim htop net-tools build-essential ca-certificates \
  openssh-server qemu-guest-agent sudo

systemctl enable --now ssh qemu-guest-agent

if [[ -n "$USERNAME" ]] && id "$USERNAME" &>/dev/null; then
  echo "==> Adding $USERNAME to sudo"
  usermod -aG sudo "$USERNAME"
else
  echo "==> No login user found; skipping sudo group"
fi

echo "==> Disabling unneeded services"
systemctl disable --now bluetooth 2>/dev/null || true
systemctl disable --now cups 2>/dev/null || true

# Debian 13 ships no /etc/sysctl.conf, so the guide's `cat >> /etc/sysctl.conf`
# + `sysctl -p` goes in a drop-in instead.
echo "==> Kernel memory tuning"
cat > /etc/sysctl.d/99-automation.conf <<'EOF'
vm.swappiness=10
vm.overcommit_memory=1
vm.vfs_cache_pressure=50
EOF
sysctl --system >/dev/null

if dpkg -l gdm3 'gnome-shell' 2>/dev/null | grep -q '^ii'; then
  if $REMOVE_DESKTOP; then
    echo "==> Removing desktop environment"
    systemctl set-default multi-user.target
    apt-get purge -y task-desktop task-gnome-desktop gdm3 'gnome*' || true
    apt-get autoremove --purge -y
  else
    echo "!!  A desktop (GNOME) is installed. Re-run with --remove-desktop to remove it."
  fi
fi

echo
echo "Done."
echo "  Default target: $(systemctl get-default)"
echo "  IP address(es): $(hostname -I)"
echo "  SSH from your laptop: ssh ${USERNAME:-<user>}@$(hostname -I | awk '{print $1}')"
[[ -n "$USERNAME" ]] && echo "  Log out and back in as $USERNAME for sudo to take effect."
