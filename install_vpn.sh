

# Configurable variables
VPN_IP=""
MAX_SSH_USERS=5
SSH_USERS_FILE="/etc/ssh/ssh_users_list.txt"

SSL_CERT_PATH="/etc/ssl/certs/mycert.pem"
SSL_KEY_PATH="/etc/ssl/private/mykey.pem"

WS_PORT_SSL=443
WS_PORT_WS=8080

# Paths for VPN certs (can be customized)
CA_FILE="ca.crt"
CERT_FILE="client.crt"
KEY_FILE="client.key"
TA_FILE="ta.key"  # Optional

# Ensure SSH users list file exists
touch "$SSH_USERS_FILE"

# --- Functions ---

# Check if dependencies are installed
check_dependencies() {
    command -v openvpn &> /dev/null || { echo "OpenVPN not installed!"; exit 1; }
    command -v stunnel4 &> /dev/null || { echo "stunnel4 not installed!"; exit 1; }
    command -v websocat &> /dev/null || { echo "websocat not installed!"; exit 1; }
    command -v openssl &> /dev/null || { echo "OpenSSL not installed!"; exit 1; }
    echo "All dependencies are installed."
}

# Generate self-signed SSL certs
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

# Setup stunnel for SSL tunneling
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
    echo "stunnel configured and running."
}

# Setup websocat server
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

# Generate VPN configuration with embedded self-signed certs
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

# Generate WebSocket SSH client config JSON
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
    echo "WebSocket SSH client config saved as ssh_ws_client_config.json"
}

# Add SSH user with expiry
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

# Remove expired SSH users
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

# Check server status (CPU, RAM, Disk)
check_server_status() {
    echo "=== Server Status ==="
    echo "CPU Load:"
    uptime
    echo "Memory Usage:"
    free -h
    echo "Disk Usage:"
    df -h /
    echo "====================="
    read -p "Press Enter to return to menu..."
}

# Check service status
check_services() {
    echo "=== Service Status ==="
    systemctl status openvpn | grep Active
    systemctl status stunnel4 | grep Active
    systemctl status websocat | grep Active
    echo "======================="
    read -p "Press Enter to return to menu..."
}

# Reboot server
reboot_server() {
    read -p "Are you sure you want to reboot? (yes/no): " confirm
    if [ "$confirm" == "yes" ]; then
        echo "Rebooting..."
        sudo reboot
    fi
}

# Main menu
menu() {
    clear
    echo "=============================="
    echo "    VPN + SSH Management      "
    echo "        Custom Version        "
    echo "=============================="
    echo "1) Generate VPN .ovpn certs"
    echo "2) Generate WebSocket SSH client config"
    echo "3) Add SSH user with expiry"
    echo "4) Delete SSH user"
    echo "5) Set max SSH users"
    echo "6) Check server status"
    echo "7) Check services status"
    echo "8) Reboot server"
    echo "9) Exit"
    echo "Current VPN IP: ${VPN_IP:-Not set}"
    echo "Max SSH Users: $MAX_SSH_USERS"
    echo "=============================="
    read -p "Choose [1-9]: " choice
    case "$choice" in
        1) generate_vpn_config; menu ;;
        2) generate_ws_client_config; menu ;;
        3) add_ssh_user; menu ;;
        4) delete_ssh_user; menu ;;
        5) set_max_users; menu ;;
        6) check_server_status; menu ;;
        7) check_services; menu ;;
        8) reboot_server ;;
        9) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid input"; sleep 2; menu ;;
    esac
}

# Delete SSH user
delete_ssh_user() {
    read -p "Enter username to delete: " user
    if id "$user" &>/dev/null; then
        sudo userdel -r "$user"
        sed -i "/^#User: $user/d" "$SSH_USERS_FILE"
        echo "User $user deleted."
    else
        echo "User does not exist."
    fi
    sleep 2
}

# Set max users
set_max_users() {
    read -p "Enter max SSH users allowed: " new_max
    if [[ "$new_max" =~ ^[0-9]+$ ]]; then
        MAX_SSH_USERS="$new_max"
        echo "Max SSH users set to $MAX_SSH_USERS"
    else
        echo "Invalid number."
    fi
    sleep 2
}

# Run menu
check_dependencies
menu
