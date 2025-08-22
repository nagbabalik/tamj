

# CONFIGURATION
VPN_IP=""  # Set your VPN server IP/hostname if known
MAX_SSH_USERS=5
SSH_USERS_FILE="/etc/ssh/ssh_users_list.txt"

SSL_CERT_PATH="/etc/ssl/certs/mycert.pem"
SSL_KEY_PATH="/etc/ssl/private/mykey.pem"

WS_PORT_SSL=443
WS_PORT_WS=8080

# ==========================
# FUNCTIONS
# ==========================

install_dependencies() {
    echo "Checking and installing dependencies..."
    for cmd in openvpn stunnel4 systemctl grep awk sed certbot wget; do
        if ! command -v $cmd &> /dev/null; then
            echo "Installing $cmd..."
            sudo apt update
            sudo apt install -y $cmd
        fi
    done
    if ! command -v websocat &> /dev/null; then
        echo "Installing websocat..."
        wget -qO /usr/local/bin/websocat https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-gnu
        chmod +x /usr/local/bin/websocat
    fi
    echo "All dependencies installed."
}

generate_ssl_certs() {
    if [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
        echo "SSL certs already exist."
        return
    fi
    echo "Generating self-signed SSL certificates..."
    sudo mkdir -p /etc/ssl/certs /etc/ssl/private
    sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -subj "/CN=MySelfSignedCert" \
        -keyout "$SSL_KEY_PATH" -out "$SSL_CERT_PATH"
    echo "Certificates generated at:"
    echo "$SSL_CERT_PATH and $SSL_KEY_PATH"
}

setup_stunnel() {
    echo "Configuring stunnel..."
    sudo bash -c "cat > /etc/stunnel/stunnel.conf" <<EOF
pid = /stunnel.pid
cert = $SSL_CERT_PATH
key = $SSL_KEY_PATH

[ssh-ws]
accept = $WS_PORT_SSL
connect = 127.0.0.1:$WS_PORT_WS
EOF
    sudo systemctl enable stunnel4
    sudo systemctl restart stunnel4
    echo "stunnel configured and restarted."
}

setup_websocat() {
    echo "Setting up websocat WebSocket server..."
    sudo bash -c "cat > /etc/systemd/system/websocat.service" <<EOF
[Unit]
Description=WebSocket SSH Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/websocat -s 0.0.0.0:$WS_PORT_WS
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable websocat
    sudo systemctl start websocat
    echo "Websocat WebSocket server started."
}

generate_vpn_config() {
    read -p "Enter VPN server IP/hostname: " VPN_IP
    cat > vpn_client.ovpn <<EOF
client
dev tun
proto udp
remote $VPN_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
comp-lzo
verb 3

<ca>
$(cat "$SSL_CERT_PATH")
</ca>

<cert>
$(cat "$SSL_CERT_PATH")
</cert>

<key>
$(cat "$SSL_KEY_PATH")
</key>
EOF
    echo "VPN config saved as vpn_client.ovpn"
}

generate_ws_client_config() {
    cat > ssh_ws_client_config.json <<EOF
{
  "name": "SSH-WS-SSL",
  "type": "ssl",
  "host": "$VPN_IP",
  "port": $WS_PORT_SSL,
  "ssl_cert": "$SSL_CERT_PATH",
  "ssl_key": "$SSL_KEY_PATH"
}
EOF
    echo "WebSocket SSH client config generated: ssh_ws_client_config.json"
}

add_ssh_user() {
    current=$(grep -c "^#User" "$SSH_USERS_FILE")
    if [ "$current" -ge "$MAX_SSH_USERS" ]; then
        echo "Max SSH users ($MAX_SSH_USERS) reached."
        return
    fi
    read -p "Enter SSH username: " user
    if id "$user" &>/dev/null; then
        echo "User exists."
        return
    fi
    sudo adduser --disabled-password --gecos "" "$user"
    read -p "Expiry date (YYYY-MM-DD): " expiry
    sudo chage -E "$expiry" "$user"
    echo "#User: $user Expiry: $expiry" >> "$SSH_USERS_FILE"
    echo "User $user added with expiry $expiry."
}

delete_ssh_user() {
    read -p "Enter username to delete: " user
    if id "$user" &>/dev/null; then
        sudo userdel -r "$user"
        sed -i "/^#User: $user/d" "$SSH_USERS_FILE"
        echo "User $user deleted."
    else
        echo "User does not exist."
    fi
}

remove_expired_users() {
    echo "Removing expired users..."
    today=$(date -I)
    while IFS= read -r line; do
        if echo "$line" | grep -q "^#User"; then
            user=$(echo "$line" | awk '{print $2}')
            expiry=$(echo "$line" | awk '{print $4}')
            if [ "$today" \> "$expiry" ]; then
                sudo userdel -r "$user"
                sed -i "/^#User: $user/d" "$SSH_USERS_FILE"
                echo "Removed expired user: $user"
            fi
        fi
    done < "$SSH_USERS_FILE"
}

check_server_status() {
    echo "=== Server Status ==="
    uptime
    free -h
    df -h /
    echo "====================="
    read -p "Press Enter..."
}

check_services() {
    echo "=== Service Status ==="
    systemctl status openvpn | grep Active
    systemctl status stunnel4 | grep Active
    systemctl status websocat | grep Active
    echo "======================="
    read -p "Press Enter..."
}

reboot_server() {
    read -p "Are you sure you want to reboot? (yes/no): " confirm
    if [ "$confirm" == "yes" ]; then
        echo "Rebooting..."
        sudo reboot
    fi
}

# AUTOMATIC SSL RENEWAL FUNCTION
auto_renew_cert() {
    echo "Running automatic SSL renewal..."
    if ! command -v certbot &> /dev/null; then
        echo "Installing certbot..."
        sudo apt update
        sudo apt install -y certbot
    fi
    # Renew certs (assuming domain setup)
    sudo certbot renew --quiet --deploy-hook "systemctl restart stunnel4 && systemctl restart websocat"
    # Copy renewed certs to your paths
    echo "Updating cert paths..."
    # Replace 'yourdomain.com' with your real domain
    DOMAIN="yourdomain.com"
    sudo cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem "$SSL_CERT_PATH"
    sudo cp /etc/letsencrypt/live/$DOMAIN/privkey.pem "$SSL_KEY_PATH"
    echo "Certificates renewed and services restarted."
}

# SETUP CRON JOB FOR AUTOMATIC RENEWAL
setup_cron() {
    CRON_FILE="/etc/cron.daily/ssl_renewal"
    echo "# Auto SSL renewal script" | sudo tee "$CRON_FILE" > /dev/null
    echo "#!/bin/bash" | sudo tee -a "$CRON_FILE" > /dev/null
    echo "bash /usr/local/bin/auto_renew_cert.sh" | sudo tee -a "$CRON_FILE" > /dev/null
    sudo chmod +x "$CRON_FILE"
    echo "Auto SSL renewal scheduled daily via cron."
}

# MAIN MENU
menu() {
    while true; do
        clear
        echo "==============================="
        echo "  VPN + SSH Management"
        echo "  Auto SSL Renewal (Scheduled)"
        echo "==============================="
        echo "1) Setup dependencies & SSL certs (initial)"
        echo "2) Generate VPN .ovpn certs"
        echo "3) Generate WebSocket SSH client config"
        echo "4) Add SSH user with expiry"
        echo "5) Delete SSH user"
        echo "6) Set max SSH users"
        echo "7) Check server status"
        echo "8) Check service status"
        echo "9) Reboot server"
        echo "10) Exit"
        echo "Current VPN IP: ${VPN_IP:-Not set}"
        echo "Max SSH Users: $MAX_SSH_USERS"
        echo "==============================="
        read -p "Choose [1-10]: " choice
        case "$choice" in
            1) install_dependencies
               generate_ssl_certs
               setup_stunnel
               setup_websocat
               setup_cron
               echo "Initial setup complete. Please run menu again."
               sleep 3; menu ;;
            2) generate_vpn_config; sleep 2; menu ;;
            3) generate_ws_client_config; sleep 2; menu ;;
            4) add_ssh_user; sleep 2; menu ;;
            5) delete_ssh_user; sleep 2; menu ;;
            6) set_max_users; sleep 2; menu ;;
            7) check_server_status; sleep 2; menu ;;
            8) check_services; sleep 2; menu ;;
            9) reboot_server ;;
            10) echo "Goodbye!"; exit 0 ;;
            *) echo "Invalid choice"; sleep 2; menu ;;
        esac
    done
}

# Set max users
set_max_users() {
    read -p "Enter max SSH users allowed: " max
    if [[ "$max" =~ ^[0-9]+$ ]]; then
        MAX_SSH_USERS="$max"
        echo "Max SSH users set to $MAX_SSH_USERS"
    else
        echo "Invalid number."
    fi
    sleep 2
}

# Start
check_dependencies
# If first run, do initial setup
if [ ! -f "$SSL_CERT_PATH" ] || [ ! -f "$SSL_KEY_PATH" ]; then
    echo "Initial setup needed. Running setup..."
    generate_ssl_certs
    setup_stunnel
    setup_websocat
    setup_cron
    echo "Initial setup complete. Please run script again to access menu."
    exit 0
fi

# Run menu
menu
