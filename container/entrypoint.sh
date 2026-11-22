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

# The dashboard updates kubeconfig on boot; keep its writable copy off NFS.
install -d -o 1000 -g 1000 -m 0700 /run/ood-kube
install -o 1000 -g 1000 -m 0600 /etc/ood/kubeconfig.template /run/ood-kube/config

/opt/ood/ood-portal-generator/sbin/update_ood_portal
httpd -t
exec /usr/sbin/httpd -DFOREGROUND
