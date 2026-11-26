FROM rockylinux/rockylinux:9

# Single-node demo Slurm cluster and SSH login host for the Open OnDemand
# portal: slurmctld + slurmd + munge + sshd, sharing the portal's NFS home.
RUN dnf -y install epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf -y update \
    && dnf -y install slurm slurm-slurmctld slurm-slurmd munge \
       openssh-server openssh-clients python3 \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN groupadd --gid 1000 ondemand \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash ondemand \
    && groupadd --system slurm \
    && useradd --system --gid slurm --home-dir /var/spool/slurm \
       --shell /sbin/nologin slurm

COPY container/slurm-entrypoint.sh /usr/local/bin/slurm-entrypoint.sh
RUN chmod 0755 /usr/local/bin/slurm-entrypoint.sh

EXPOSE 22 6817 6818
ENTRYPOINT ["/usr/local/bin/slurm-entrypoint.sh"]
