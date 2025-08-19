
#!/bin/bash
# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Run as root!"
  exit 1
fi

# Variables
DOMAIN=""
SSL_CERT_PATH=""
SSL_KEY_PATH=""
V2RAY_UUID=""
USER_LIMIT=3

# --- Function definitions ---

install_dependencies() {
  echo "Installing dependencies..."
  apt update && apt upgrade -y
  apt install -y nginx git wget unzip curl gnupg build-essential libssl-dev libffi-dev python3-dev fail2ban certbot python3-certbot-nginx qrencode
}

generate_ssl_cert() {
  echo "Select SSL Cert type:"
  echo "1) Let's Encrypt"
  echo "2) Self-signed"
  read -p "Choice (1/2): " ssl_choice
  if [ "$ssl_choice" == "1" ]; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
    echo "Obtaining SSL certificate..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_choice" == "2" ]; then
    echo "Generating self-signed SSL..."
    mkdir -p /etc/ssl/$DOMAIN
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/CN=$DOMAIN" \
      -keyout /etc/ssl/$DOMAIN/selfsigned.key \
      -out /etc/ssl/$DOMAIN/selfsigned.crt
    SSL_CERT_PATH="/etc/ssl/$DOMAIN/selfsigned.crt"
    SSL_KEY_PATH="/etc/ssl/$DOMAIN/selfsigned.key"
  else
    echo "Invalid choice!"
    exit 1
  fi
}

setup_v2ray() {
  echo "Installing V2Ray..."
  wget -O /tmp/v2ray.zip https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip
  unzip /tmp/v2ray.zip -d /usr/local/bin/
  chmod +x /usr/local/bin/v2ray

  V2RAY_UUID=$(uuidgen)
  echo "V2Ray UUID: $V2RAY_UUID"

  cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$V2RAY_UUID", "email": "shared@$DOMAIN"}]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certFile": "$SSL_CERT_PATH",
        "keyFile": "$SSL_KEY_PATH"
      },
      "wsSettings": {
        "path": "/"
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  cat > /etc/systemd/system/v2ray.service <<EOF
[Unit]
Description=V2Ray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/v2ray -c /etc/v2ray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now v2ray
}

setup_nginx() {
  echo "Configuring Nginx..."
  cat > /etc/nginx/sites-available/proxy.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/proxy.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl restart nginx
}

setup_dns_tunnel() {
  echo "Set up your DNS server with the public key..."
  # You need to deploy your DNS server separately
}

setup_badvpn() {
  echo "Installing BadVPN..."
  wget -O /usr/local/bin/badvpn-udpgw https://github.com/ambrop72/badvpn/releases/latest/download/badvpn-udpgw
  chmod +x /usr/local/bin/badvpn-udpgw
  cat > /etc/systemd/system/badvpn.service <<EOF
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now badvpn
}

setup_hysteria() {
  echo "Installing Hysteria..."
  wget -O /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64
  chmod +x /usr/local/bin/hysteria
  cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":443",
  "cert": "$SSL_CERT_PATH",
  "key": "$SSL_KEY_PATH",
  "auth": "$VPN_PASSWORD",
  "target": "127.0.0.1:8080"
}
EOF
  cat > /etc/systemd/system/hysteria.service <<EOF
[Unit]
Description=Hysteria UDP over TLS/KCP
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria
}

setup_openvpn() {
  echo "Installing OpenVPN..."
  # Assumes certs are pre-generated or generated elsewhere
  cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF
  systemctl enable --now openvpn@server
}

# User management functions
manage_users() {
  echo "=== User Management ==="
  echo "1) Create SSH user"
  echo "2) Delete SSH user"
  echo "3) List users"
  echo "4) Check user expiration"
  echo "5) Set max users per SSH account ($USER_LIMIT)"
  echo "6) Back"
  read -p "Select: " choice
  case "$choice" in
    1)
      read -p "SSH username: " sshuser
      echo "Set SSH password:"
      passwd "$sshuser"
      chage -E "$(date -d "+30 days" +"%Y-%m-%d")" "$sshuser"
      # Link to shared VLESS UUID
      echo "$sshuser,$V2RAY_UUID,$(date -d "+30 days" +"%Y-%m-%d")" >> /etc/vpn/ssh_users.txt
      echo "User $sshuser created and linked."
      ;;
    2)
      read -p "SSH username to delete: " sshuser
      userdel -r "$sshuser"
      sed -i "/^$sshuser,/d" /etc/vpn/ssh_users.txt
      echo "User $sshuser deleted."
      ;;
    3)
      cat /etc/vpn/ssh_users.txt
      ;;
    4)
      echo "Check expiration for SSH user:"
      read -p "SSH username: " sshuser
      grep "^$sshuser," /etc/vpn/ssh_users.txt
      ;;
    5)
      read -p "Enter max users per SSH account (current: $USER_LIMIT): " new_limit
      if [ -n "$new_limit" ]; then
        USER_LIMIT=$new_limit
        echo "User limit set to $USER_LIMIT"
      fi
      ;;
    6) return ;;
    *)
      echo "Invalid."
      ;;
  esac
  manage_users
}

# Check and lock expired SSH users
check_ssh_expiry() {
  while IFS= read -r line; do
    user=$(echo "$line" | cut -d, -f1)
    expiry=$(echo "$line" | cut -d, -f3)
    today=$(date +%Y-%m-%d)
    if [[ "$today" > "$expiry" ]]; then
      echo "Locking expired user: $user"
      usermod -L "$user"
    else
      usermod -U "$user"
    fi
  done < /etc/vpn/ssh_users.txt
}

# Generate self-signed SSL cert
generate_self_signed_cert() {
  echo "Generating self-signed SSL..."
  mkdir -p /etc/ssl/$DOMAIN
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -subj "/CN=$DOMAIN" \
    -keyout /etc/ssl/$DOMAIN/selfsigned.key \
    -out /etc/ssl/$DOMAIN/selfsigned.crt
  SSL_CERT_PATH="/etc/ssl/$DOMAIN/selfsigned.crt"
  SSL_KEY_PATH="/etc/ssl/$DOMAIN/selfsigned.key"
}

# Main menu
main_menu() {
  while true; do
    echo "=== Main Menu ==="
    echo "1) Install all protocols/services"
    echo "2) Manage SSH users"
    echo "3) Check SSH user expiration"
    echo "4) Set max users per SSH account ($USER_LIMIT)"
    echo "5) Exit"
    read -p "Choice: " choice
    case "$choice" in
      1)
        install_dependencies
        generate_ssl_cert
        setup_v2ray
        setup_nginx
        setup_dns_tunnel
        setup_badvpn
        setup_hysteria
        setup_openvpn
        echo "Setup complete!"
        ;;
      2) manage_users ;;
      3) check_ssh_expiry; echo "Checked expirations." ;;
      4) set_user_limit ;;
      5) exit 0 ;;
      *) echo "Invalid"; sleep 2 ;;
    esac
  done
}

set_user_limit() {
  read -p "Enter max users per SSH account (current: $USER_LIMIT): " new_limit
  if [ -n "$new_limit" ]; then
    USER_LIMIT=$new_limit
  fi
  echo "Max users per SSH account: $USER_LIMIT"
}

# Run the menu
main_menu
