# Copyright 2025 Zhone Inc
# atmoz/sftp with ssh-rsa algorithm support re-enabled for legacy client compatibility
FROM rt.cloud.dzsi.local/docker-hub/atmoz/sftp:debian

COPY sshd_config.d/rsa-compat.conf /etc/ssh/sshd_config.d/rsa-compat.conf
RUN echo 'Include /etc/ssh/sshd_config.d/*.conf' >>/etc/ssh/sshd_config
