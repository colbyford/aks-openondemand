#!/bin/bash
set -euo pipefail
umask 077

# Each release has exactly one authenticated Unix user and a dedicated NFS share.
if [[ ! -s /etc/ood/auth/htpasswd ]] \
   || [[ $(grep -c '^ondemand:' /etc/ood/auth/htpasswd) -ne 1 ]] \
   || grep -qv '^ondemand:' /etc/ood/auth/htpasswd; then
  echo "The authentication Secret must contain exactly one htpasswd entry for ondemand." >&2
  exit 1
fi

chown 1000:1000 /home/ondemand
chmod 0700 /home/ondemand

# Slurm support: munge credentials and an SSH identity for the web shell.
if [[ -s /etc/ood/munge.key ]]; then
  install -o munge -g munge -m 0400 /etc/ood/munge.key /etc/munge/munge.key
  install -d -o munge -g munge -m 0755 /run/munge
  runuser -u munge -- /usr/sbin/munged
fi
if [[ "${OOD_SHELL_ENABLED:-false}" == "true" ]]; then
  if [[ ! -s /home/ondemand/.ssh/id_ed25519 ]]; then
    install -d -m 0700 -o 1000 -g 1000 /home/ondemand/.ssh
    runuser -u ondemand -- ssh-keygen -q -t ed25519 -N '' -f /home/ondemand/.ssh/id_ed25519
  fi
  install -m 0600 -o 1000 -g 1000 /home/ondemand/.ssh/id_ed25519.pub \
    /home/ondemand/.ssh/authorized_keys
  if [[ -n "${OOD_LOGIN_HOST:-}" ]]; then
    # The login pod's host keys are ephemeral; trust is scoped to this one host.
    printf 'Host %s\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' \
      "$OOD_LOGIN_HOST" >/etc/ssh/ssh_config.d/40-ood.conf
    chmod 0644 /etc/ssh/ssh_config.d/40-ood.conf
  fi
else
  rm -rf /var/www/ood/apps/sys/shell
fi

# The dashboard updates kubeconfig on boot; keep its writable copy off NFS.
install -d -o 1000 -g 1000 -m 0700 /run/ood-kube
install -o 1000 -g 1000 -m 0600 /etc/ood/kubeconfig.template /run/ood-kube/config

/opt/ood/ood-portal-generator/sbin/update_ood_portal
httpd -t
exec /usr/sbin/httpd -DFOREGROUND
