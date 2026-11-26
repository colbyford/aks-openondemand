#!/bin/bash
set -euo pipefail

if [[ ! -s /etc/ood/munge.key ]]; then
  echo "The munge key Secret must be mounted at /etc/ood/munge.key." >&2
  exit 1
fi
install -o munge -g munge -m 0400 /etc/ood/munge.key /etc/munge/munge.key
install -d -o munge -g munge -m 0755 /run/munge
runuser -u munge -- /usr/sbin/munged

# Host keys are ephemeral; the portal pins trust to this single login host.
ssh-keygen -A
install -d -m 0755 /run/sshd
/usr/sbin/sshd

install -d -o slurm -g slurm -m 0755 /var/spool/slurmctld /run/slurm
install -d -m 0755 /var/spool/slurmd
/usr/sbin/slurmctld
exec /usr/sbin/slurmd -D
