#!/bin/bash

# ================== CONFIGURATION ==================
ADMIN_USER="admin"                  # Change to your admin username
ADMIN_PASS="your_secure_password"   # Change to your secure password
BANNER_FILE="/etc/motd.banner"      # Banner message file

# ================== FUNCTIONS ==================

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root!"
  exit 1
fi

# Save current info to file
save_vpn_info() {
  echo "V2Ray UUID (shared): $V2RAY_UUID" > /etc/vpn/setup-info.txt
  echo "DNS Public Key: $DNS_PUBLIC_KEY" >> /etc/vpn/setup-info.txt
}

# Show info
show_vpn_info() {
  echo "=== VPN Setup Information ==="
  if [ -f /etc/vpn/setup-info.txt ]; then
    cat /etc/vpn/setup-info.txt
  else
    echo "Info not available. Please run setup first."
  fi
}

# Show setup instructions
show_setup_instructions() {
  echo ""
  echo "=== Configuration Instructions ==="
  echo "Shared UUID: $V2RAY_UUID"
  echo "DNS Public Key: $DNS_PUBLIC_KEY"
  echo ""
  echo "V2Ray JSON (no SSL):"
  echo "{
  \"inbounds\": [{
    \"port\": 8080,
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [{\"id\": \"$V2RAY_UUID\", \"email\": \"shared@$DOMAIN\"}]
    },
    \"streamSettings\": {
      \"network\": \"ws\"
    }
  }],
  \"outbounds\": [{\"protocol\": \"freedom\"}]
}"
  echo ""
  echo "V2Ray JSON (with SSL):"
  echo "{
  \"inbounds\": [{
    \"port\": 443,
    \"protocol\": \"vless\",
    \"settings\": {
      \"clients\": [{\"id\": \"$V2RAY_UUID\", \"email\": \"shared@$DOMAIN\"}]
    },
    \"streamSettings\": {
      \"network\": \"ws\",
      \"security\": \"tls\",
      \"tlsSettings\": {
        \"certFile\": \"$SSL_CERT_PATH\",
        \"keyFile\": \"$SSL_KEY_PATH\"
      }
    }
  }],
  \"outbounds\": [{\"protocol\": \"freedom\"}]
}"
  echo ""
  echo "Configure your DNS records to point to your server IP."
  echo "Set your DNS server with the public key."
  echo ""
}

# Set banner message
set_banner() {
  echo "Enter your banner message:"
  read -r banner_msg
  echo "$banner_msg" > "$BANNER_FILE"
  echo "Banner message saved."
  echo "To activate it, add this line to /etc/ssh/sshd_config:"
  echo "Banner $BANNER_FILE"
}

# Show current banner
show_banner() {
  if [ -f "$BANNER_FILE" ]; then
    cat "$BANNER_FILE"
  fi
}

# Panel login function
panel_login() {
  echo "=== VPN Management Panel Login ==="
  read -p "Username: " input_user
  read -s -p "Password: " input_pass
  echo ""
  if [ "$input_user" = "$ADMIN_USER" ] && [ "$input_pass" = "$ADMIN_PASS" ]; then
    echo "Access granted."
  else
    echo "Invalid credentials!"
    exit 1
  fi
}

# Manage users panel
manage_users_panel() {
  while true; do
    echo "=== User Management Panel ==="
    echo "1) Add new SSH user"
    echo "2) Delete SSH user"
    echo "3) List SSH users"
    echo "4) Set user expiration"
    echo "5) Back to main menu"
    read -p "Choose: " op

    case "$op" in
      1)
        read -p "New SSH username: " new_user
        echo "Set SSH password:"
        passwd "$new_user"
        echo "Linking to shared UUID..."
        chage -E "$(date -d "+30 days" +"%Y-%m-%d")" "$new_user"
        echo "$new_user,$V2RAY_UUID,$(date -d "+30 days" +"%Y-%m-%d")" >> /etc/vpn/ssh_users.txt
        echo "User added."
        show_setup_instructions
        ;;
      2)
        read -p "Username to delete: " del_user
        userdel -r "$del_user"
        sed -i "/^$del_user,/d" /etc/vpn/ssh_users.txt
        echo "User deleted."
        ;;
      3)
        echo "Current users:"
        cat /etc/vpn/ssh_users.txt
        ;;
      4)
        read -p "Username to set expiration: " user_exp
        read -p "Days until expiration: " days
        new_exp=$(date -d "+$days days" +"%Y-%m-%d")
        sed -i "/^$user_exp,/d" /etc/vpn/ssh_users.txt
        echo "$user_exp,$V2RAY_UUID,$new_exp" >> /etc/vpn/ssh_users.txt
        chage -E "$new_exp" "$user_exp"
        echo "Expiration updated."
        ;;
      5)
        break
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
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

# --- Main setup functions ---

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
  if [ "$ssl_choice" = "1" ]; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
    echo "Obtaining SSL certificate..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_choice" = "2" ]; then
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

  # Generate shared UUID
  V2RAY_UUID=$(uuidgen)
  echo "V2Ray UUID: $V2RAY_UUID"

  # Save info to file
  save_vpn_info

  # Create V2Ray config (non-SSL)
  cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [{
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$V2RAY_UUID", "email": "shared@$DOMAIN"}]
    },
    "streamSettings": {
      "network": "ws"
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  # Systemd service
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
  # Configure with your SSL certs if SSL enabled
  cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":443",
  "cert": "$SSL_CERT_PATH",
  "key": "$SSL_KEY_PATH",
  "auth": "$VPN_PASSWORD",
  "target": "127.0.0.1:8080"
}
EOF
  # Systemd
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
  # Assumes certs are pre-generated
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

# --- User management ---

manage_users() {
  echo "=== User Management Panel ==="
  echo "1) Add new SSH user"
  echo "2) Delete SSH user"
  echo "3) List SSH users"
  echo "4) Set user expiration"
  echo "5) Back"
  read -p "Choose: " op

  case "$op" in
    1)
      read -p "New SSH username: " new_user
      echo "Set SSH password:"
      passwd "$new_user"
      echo "Linking to shared UUID..."
      chage -E "$(date -d "+30 days" +"%Y-%m-%d")" "$new_user"
      echo "$new_user,$V2RAY_UUID,$(date -d "+30 days" +"%Y-%m-%d")" >> /etc/vpn/ssh_users.txt
      echo "User added."
      show_setup_instructions
      ;;
    2)
      read -p "Username to delete: " del_user
      userdel -r "$del_user"
      sed -i "/^$del_user,/d" /etc/vpn/ssh_users.txt
      echo "User deleted."
      ;;
    3)
      echo "Current users:"
      cat /etc/vpn/ssh_users.txt
      ;;
    4)
      read -p "Username to set expiration: " user_exp
      read -p "Days until expiration: " days
      new_exp=$(date -d "+$days days" +"%Y-%m-%d")
      sed -i "/^$user_exp,/d" /etc/vpn/ssh_users.txt
      echo "$user_exp,$V2RAY_UUID,$new_exp" >> /etc/vpn/ssh_users.txt
      chage -E "$new_exp" "$user_exp"
      echo "Expiration updated."
      ;;
    5)
      return
      ;;
    *)
      echo "Invalid."
      ;;
  esac
  manage_users
}

# Check & lock expired users
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

# Banner setup
set_banner() {
  echo "Enter your banner message:"
  read -r banner_msg
  echo "$banner_msg" > "$BANNER_FILE"
  echo "Banner message saved."
  echo "Add this line to /etc/ssh/sshd_config:"
  echo "Banner $BANNER_FILE"
}

# Show banner
show_banner() {
  if [ -f "$BANNER_FILE" ]; then
    cat "$BANNER_FILE"
  fi
}

# --- Main setup functions ---

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
  if [ "$ssl_choice" = "1" ]; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
    echo "Obtaining SSL certificate..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_choice" = "2" ]; then
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

  # Generate shared UUID
  V2RAY_UUID=$(uuidgen)
  echo "V2Ray UUID: $V2RAY_UUID"

  # Save info
  save_vpn_info

  # Create V2Ray config (non-SSL example)
  cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [{
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$V2RAY_UUID", "email": "shared@$DOMAIN"}]
    },
    "streamSettings": {
      "network": "ws"
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  # Systemd service
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
  # Systemd
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
  # Assumes certs are pre-generated
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

# --- User management ---

manage_users() {
  echo "=== User Management Panel ==="
  echo "1) Add new user"
  echo "2) Delete user"
  echo "3) List users"
  echo "4) Set user expiration"
  echo "5) Back"
  read -p "Choose: " op

  case "$op" in
    1)
      read -p "New SSH username: " new_user
      echo "Set SSH password:"
      passwd "$new_user"
      echo "Linking to shared UUID..."
      chage -E "$(date -d "+30 days" +"%Y-%m-%d")" "$new_user"
      echo "$new_user,$V2RAY_UUID,$(date -d "+30 days" +"%Y-%m-%d")" >> /etc/vpn/ssh_users.txt
      echo "User added."
      show_setup_instructions
      ;;
    2)
      read -p "Username to delete: " del_user
      userdel -r "$del_user"
      sed -i "/^$del_user,/d" /etc/vpn/ssh_users.txt
      echo "User deleted."
      ;;
    3)
      echo "Current users:"
      cat /etc/vpn/ssh_users.txt
      ;;
    4)
      read -p "Username to set expiration: " user_exp
      read -p "Days until expiration: " days
      new_exp=$(date -d "+$days days" +"%Y-%m-%d")
      sed -i "/^$user_exp,/d" /etc/vpn/ssh_users.txt
      echo "$user_exp,$V2RAY_UUID,$new_exp" >> /etc/vpn/ssh_users.txt
      chage -E "$new_exp" "$user_exp"
      echo "Expiration updated."
      ;;
    5)
      return
      ;;
    *)
      echo "Invalid."
      ;;
  esac
  manage_users
}

# Check and lock expired users
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

# Set banner message
set_banner() {
  echo "Enter your banner message:"
  read -r banner_msg
  echo "$banner_msg" > "$BANNER_FILE"
  echo "Banner message saved."
  echo "Add this line to /etc/ssh/sshd_config:"
  echo "Banner $BANNER_FILE"
}

# Show banner
show_banner() {
  if [ -f "$BANNER_FILE" ]; then
    cat "$BANNER_FILE"
  fi
}

# --- Main setup functions ---

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
  if [ "$ssl_choice" = "1" ]; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
    echo "Obtaining SSL certificate..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_choice" = "2" ]; then
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

  # Generate shared UUID
  V2RAY_UUID=$(uuidgen)
  echo "V2Ray UUID: $V2RAY_UUID"

  # Save info
  save_vpn_info

  # Create V2Ray config (non-SSL example)
  cat > /etc/v2ray/config.json <<EOF
{
  "inbounds": [{
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$V2RAY_UUID", "email": "shared@$DOMAIN"}]
    },
    "streamSettings": {
      "network": "ws"
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

  # Enable V2Ray
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
  # Configure with your SSL certs if SSL enabled
  cat > /etc/hysteria/config.json <<EOF
{
  "listen": ":443",
  "cert": "$SSL_CERT_PATH",
  "key": "$SSL_KEY_PATH",
  "auth": "$VPN_PASSWORD",
  "target": "127.0.0.1:8080"
}
EOF
  # Systemd
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
  # Assumes certs are pre-generated
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

# --- User management functions ---

manage_users() {
  echo "=== User Management Panel ==="
  echo "1) Add new user"
  echo "2) Delete user"
  echo "3) List users"
  echo "4) Set user expiration"
  echo "5) Back"
  read -p "Choose: " op

  case "$op" in
    1)
      read -p "New SSH username: " new_user
      echo "Set SSH password:"
      passwd "$new_user"
      echo "Linking to shared UUID..."
      chage -E "$(date -d "+30 days" +"%Y-%m-%d")" "$new_user"
      echo "$new_user,$V2RAY_UUID,$(date -d "+30 days" +"%Y-%m-%d")" >> /etc/vpn/ssh_users.txt
      echo "User added."
      show_setup_instructions
      ;;
    2)
      read -p "Username to delete: " del_user
      userdel -r "$del_user"
      sed -i "/^$del_user,/d" /etc/vpn/ssh_users.txt
      echo "User deleted."
      ;;
    3)
      echo "Current users:"
      cat /etc/vpn/ssh_users.txt
      ;;
    4)
      read -p "Username to set expiration: " user_exp
      read -p "Days until expiration: " days
      new_exp=$(date -d "+$days days" +"%Y-%m-%d")
      sed -i "/^$user_exp,/d" /etc/vpn/ssh_users.txt
      echo "$user_exp,$V2RAY_UUID,$new_exp" >> /etc/vpn/ssh_users.txt
      chage -E "$new_exp" "$user_exp"
      echo "Expiration updated."
      ;;
    5)
      return
      ;;
    *)
      echo "Invalid."
      ;;
  esac
  manage_users
}

# Check and lock expired users
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

# Set banner message
set_banner() {
  echo "Enter your banner message:"
  read -r banner_msg
  echo "$banner_msg" > "$BANNER_FILE"
  echo "Banner message saved."
  echo "Add this line to /etc/ssh/sshd_config:"
  echo "Banner $BANNER_FILE"
}

# Show banner message
show_banner() {
  if [ -f "$BANNER_FILE" ]; then
    cat "$BANNER_FILE"
  fi
}

# --- Main setup functions ---

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
  if [ "$ssl_choice" = "1" ]; then
    echo "Installing Certbot..."
    apt update && apt install -y certbot python3-certbot-nginx
    echo "Obtaining SSL certificate..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com
    SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  elif [ "$ssl_choice" = "2" ]; then
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
  unzip /tmp/v
