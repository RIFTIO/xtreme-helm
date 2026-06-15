#!/bin/bash
set -e

FTP_USER=${FTP_USER:-ftpuser}
FTP_PASS=${FTP_PASS:-ftpuser123}
PASV_ADDRESS=${PASV_ADDRESS:-}
PASV_MIN_PORT=${PASV_MIN_PORT:-21100}
PASV_MAX_PORT=${PASV_MAX_PORT:-21110}

# Create FTP user
useradd -m -s /sbin/nologin "$FTP_USER" 2>/dev/null || true
echo "$FTP_USER:$FTP_PASS" | chpasswd

# Add user to userlist
echo "$FTP_USER" > /etc/vsftpd/user_list

# Apply passive mode config
sed -i "s/^pasv_min_port=.*/pasv_min_port=$PASV_MIN_PORT/" /etc/vsftpd/vsftpd.conf
sed -i "s/^pasv_max_port=.*/pasv_max_port=$PASV_MAX_PORT/" /etc/vsftpd/vsftpd.conf

if [ -n "$PASV_ADDRESS" ]; then
    echo "pasv_address=$PASV_ADDRESS" >> /etc/vsftpd/vsftpd.conf
    echo "pasv_promiscuous=YES" >> /etc/vsftpd/vsftpd.conf
fi

exec /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf
