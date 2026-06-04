# Copyright 2025 Zhone Inc
# vsftpd on AlmaLinux 9 — replaces fauria/vsftpd (CentOS 7 EOL June 2024)
FROM almalinux:9

RUN dnf install -y vsftpd openssh-server \
 && dnf clean all \
 && rm -rf /var/cache/dnf

COPY vsftpd.conf /etc/vsftpd/vsftpd.conf
COPY sshd_config.d/rsa-compat.conf /etc/ssh/sshd_config.d/rsa-compat.conf
COPY run.sh /run.sh
RUN chmod +x /run.sh

EXPOSE 20 21 21100-21110

CMD ["/run.sh"]
