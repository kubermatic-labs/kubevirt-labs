#!/bin/bash
#
# cloud-init user-data for the tobi-demo-bastion VM.
#
# This file is NOT applied directly - `deploy.sh` wraps it into the Secret
# `tobi-demo-bastion-cloudinit` (key `userData`), which bastion-vm.yaml
# references via `cloudInitNoCloud.secretRef`.
#
# WHY A SECRET: KubeVirt caps *inline* `cloudInitNoCloud.userData` at 2048
# bytes. This bootstrap is ~2.4 kB, so the inline form is rejected / truncated.
# A Secret has no such limit (1 MiB), and keeping the script in its own file
# means no YAML indentation traps and `shellcheck` actually works on it.
#
# EDIT + ROLL OUT:
#   vim cloudinit/bastion-user-data.sh
#   just cloudinit        # push the Secret
#   just recreate         # cloud-init only runs on a FRESH instance (see README)
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">> [1/5] base packages + qemu-guest-agent"
apt-get update -y
apt-get install -y qemu-guest-agent

echo ">> [2/5] inject the SSH key (single source of truth: this file)"
# ROTATE HERE: replace the key below, then `just cloudinit && just recreate`.
AUTHORIZED_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCloj8OvReuuOXtECaMo1iZD8q8newJ9hWZSxIiwOG2406uOueYOxBleb85Jl231YWWjocj6fqExvZBzsQQlrad4fy6oDL5sKZyngtkCZnWcq1DsWn8Sgas9lw2+KS67EXO/P5SHhJSOrqyU6ciktX0WViPvVqb6DnK3RepFh6Xnyl0Q/0RnpSCTomyKK2PfNsv8e80AnfxA1CtnRfeexgwiKtQUPzkEdCG1ABcdZZru3m0y7y1qR0MdYYZIK+bycacngvJCJyp8gnIXHU8dDZanHL2WGOcCpd/gjwM6iryr6IhlCZXw++PRGK1aErtvKDH7oaAMLW8qFK4+bpMdeytd4Viw/g3SH3Q7ows2xl6NTaU2F0PTXD+qAY2xna1eemet1txl1oP6KQJ2Rqc5rNU3/auhdK4PaU22D8Z2XF7gOrsoQB7dqW0BBDHg/ftVNb9BgOHGkYvxSsCavcqX3joUyFjHzhv+sD1WiOPvfRqV4fQ8h47ERvD3QXuBn+5YKeKp/0sjSCypIdK02FAFa2NxN2tEoh7wdCBX9enFU3UT7jfeW5Pf98Z6ao9hiAF80J5FIM21sMG3E3dAMb2tr8Gc8jM5QdWO4rJkG9j5v2d1umLkSxm7pN4Mxw/AE02jYNEblm9i/Pbzg8wqa9gw2gubO7A8qoKVtA1xlOnDVB+0Q== tobi@loodse.com'

install_key() {
  local home="$1" owner="$2"
  install -d -m 700 -o "$owner" -g "$owner" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF "$AUTHORIZED_KEY" "$home/.ssh/authorized_keys" \
    || echo "$AUTHORIZED_KEY" >> "$home/.ssh/authorized_keys"
  chown "$owner:$owner" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
}
install_key /root root
# The golden image rejects direct root login, so `ubuntu` is the SSH target.
install_key /home/ubuntu ubuntu
echo "   ssh key propagated to root + ubuntu."

echo ">> [3/5] harden sshd (this VM is exposed on a PUBLIC LB IP)"
cat > /etc/ssh/sshd_config.d/99-bastion.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
sshd -t && (systemctl reload ssh || systemctl reload sshd || true)

# Both mesh clients are INSTALLED ONLY. `netbird up` / `tailscale up` each need an
# interactive browser/SSO login, so the operator runs them by hand on first use
# (different machine + SSO context). See the README's skip-auth section.
echo ">> [4/5] install netbird + tailscale (install ONLY - the 'up' commands are manual)"
curl -fsSL https://pkgs.netbird.io/install.sh | sh
# Installs the repo + tailscaled and starts the daemon, but leaves the node
# logged out until `tailscale up` runs.
curl -fsSL https://tailscale.com/install.sh | sh

echo ">> ... install docker (official convenience script) + group"
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable --now docker qemu-guest-agent
echo "   netbird + tailscale + docker installed."

echo ">> [5/5] prepare the data disk for /data (idempotent, UUID fstab)"
ROOT_PART=$(findmnt -no SOURCE /)
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_PART" | head -n1)"
DATA_DEV=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "^${ROOT_DISK}$" | head -n1)

if [ -n "${DATA_DEV:-}" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    echo "   formatting $DATA_DEV as ext4"
    mkfs.ext4 -F "$DATA_DEV"
  fi
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  mkdir -p /data
  grep -q "UUID=$UUID" /etc/fstab \
    || echo "UUID=$UUID  /data  ext4  defaults,nofail  0  2" >> /etc/fstab
  mount -a
  echo "   /data mounted from $DATA_DEV (UUID=$UUID)"
else
  echo "   WARNING: data disk not detected; skipping /data setup."
fi

lsblk
echo ">> cloud-init done. bastion bootstrapped."
