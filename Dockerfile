FROM rockylinux/rockylinux:9

ARG KUBECTL_VERSION
ARG TARGETARCH=amd64

RUN dnf -y install https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.el9.noarch.rpm \
    && dnf -y install dnf-utils epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf -y module enable ruby:3.3 nodejs:20 \
    && dnf -y update \
    && dnf -y install ondemand curl-minimal ca-certificates \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN test -n "${KUBECTL_VERSION}" \
    && curl --fail --location --retry 3 \
       "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
       --output /usr/local/bin/kubectl \
    && curl --fail --location --retry 3 \
       "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
       --output /tmp/kubectl.sha256 \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum --check \
    && chmod 0755 /usr/local/bin/kubectl \
    && rm /tmp/kubectl.sha256

RUN groupadd --gid 1000 ondemand \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash ondemand \
    && mkdir -p /etc/ood/auth /var/run/ondemand-nginx /var/log/ondemand-nginx \
    && rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/welcome.conf

COPY container/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
