
#!/bin/bash

# ================== CONFIGURATION ==================
ADMIN_USER="admin" # Change this to your admin username
ADMIN_PASS="your_secure_password" # Change this to your secure password
BANNER_FILE="/etc/motd.banner"

# ================== FUNCTIONS ==================

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root!"
  exit 1
fi

# Save info about DNS/Public Key
save_dns_info() {
  echo "DNS Public Key: $DNS_PUBLIC_KEY" > /etc/vpn/setup-info.txt
  echo "Note: Set up your DNS server with this public key."
}

# Show info
show_info() {
  echo "=== VPN DNS Tunnel Info ==="
  if [ -f /etc/vpn/setup-info.txt ]; then
    cat /etc/vpn/setup-info.txt
  else
    echo "Please run setup first."
  fi
}

# Show setup instructions
show_instructions() {
  echo ""
  echo "=== Setup Instructions ==="
  echo "DNS Public Key: $DNS_PUBLIC_KEY"
  echo "Configure your DNS server with this key."
  echo "Your DNS records should point to your server IP."
  echo "Use your DNS server with your client configs."
  echo ""
}

# Banner message
set_banner() {
  echo "Enter your banner message:"
  read -r banner_msg
  echo "$banner_msg" > "$BANNER_FILE"
  echo "Banner message saved."
  echo "Add this line to /etc/ssh/sshd_config:"
  echo "Banner $BANNER_FILE"
}

show_banner() {
  [ -f "$BANNER_FILE" ] && cat "$BANNER_FILE"
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
        proxy_pass http://127.0.0.1:8080; # Your DNS tunnel backend
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
  echo "NOTE: Set up your DNS server with the public key."
  # You need to deploy your DNS tunneling server separately
}

# --- User management and info panel ---

panel_login() {
  echo "=== VPN DNS Tunnel Panel Login ==="
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

manage_users() {
  while true; do
    echo "=== User Management ==="
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
        break
        ;;
      *)
        echo "Invalid."
        ;;
    esac
  done
}

# --- Main menu ---

show_menu() {
  echo "=== Main Menu ==="
  echo "1) Install all protocols/services"
  echo "2) Manage SSH users (panel)"
  echo "3) Show VPN info"
  echo "4) Show setup instructions"
  echo "5) Set banner message"
  echo "6) Show current banner"
  echo "7) Exit"
}

# --- Main script ---

main() {
  read -p "Enter your domain (e.g., yourdomain.com): " DOMAIN
  echo "Enter your DNS public key:"
  read -p "Public Key: " DNS_PUBLIC_KEY
  echo "SSL Cert type:"
  echo "1) Let's Encrypt"
  echo "2) Self-signed"
  read -p "Choice (1/2): " ssl_choice

  install_dependencies
  generate_ssl_cert

  # Generate shared UUID
  V2RAY_UUID=$(uuidgen)
  echo "Shared UUID: $V2RAY_UUID"

  # Save info
  save_vpn_info

  # Setup services
  setup_v2ray
  setup_nginx
  setup_dns_tunnel
  echo "Setup complete! Run again, choose option 3 to view info."
}

# --- Run the menu ---
while true; do
  show_menu
  read -p "Choose an option: " choice
  case "$choice" in
    1) main ;;
    2) panel_login; manage_users ;;
    3) show_vpn_info ;;
    4) show_setup_instructions ;;
    5) set_banner ;;
    6) show_banner ;;
    7) echo "Goodbye!"; exit 0 ;;
    *) echo "Invalid option"; sleep 2 ;;
  esac
done
