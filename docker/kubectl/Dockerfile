# Copyright 2026 Zhone Inc
# Minimal kubectl image: Alpine + kubectl binary only.
# Replaces alpine/k8s which bundles helm, eksctl, containerd, etc. and
# carries 178 CVEs from embedded Go dependencies we don't need.
FROM alpine:3.21

ARG KUBECTL_VERSION=1.36.2

RUN apk add --no-cache bash curl \
 && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && apk del --purge curl
