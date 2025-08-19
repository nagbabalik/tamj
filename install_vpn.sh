#!/bin/bash

# ================== CONFIGURATION ==================
ADMIN_USER="admin" # Change this
ADMIN_PASS="your_secure_password" # Change this
DOMAIN="yourdomain.com" # Your domain
BANNER_FILE="/etc/motd.banner"

# ================== FUNCTIONS ==================

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root!"
  exit 1
fi

# Save info
save_dns_info() {
  echo "Public Key: $DNS_PUBLIC_KEY" > /etc/vpn/setup-info.txt
  echo "NS Hostname: $NS_HOSTNAME" >> /etc/vpn/setup-info.txt
  echo "Configure your DNS server with this public key."
}

# Show info
show_info() {
  echo "=== DNS Tunnel Info ==="
  [ -f /etc/vpn/setup-info.txt ] && cat /etc/vpn/setup-info.txt || echo "Please run setup first."
}

# Show setup instructions
show_instructions() {
  echo ""
  echo "=== Setup Instructions ==="
  echo "Public Key: $DNS_PUBLIC_KEY"
  echo "NS Hostname: $NS_HOSTNAME"
  echo "Configure your DNS zone to include NS record and point your domain to your server IP."
  echo "Set your DNS server with the public key."
  echo ""
}

# Banner
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

# Install bind9
install_dependencies() {
  echo "Installing dependencies..."
  apt update && apt upgrade -y
  apt install -y bind9
}

# Add NS record to zone file
add_ns_record() {
  echo "Enter your NS hostname (e.g., ns1.yourdomain.com):"
  read -r NS_HOSTNAME
  # Get your server's public IP
  NS_IP=$(curl -s https://api.ipify.org)
  ZONE_FILE="/etc/bind/db.$DOMAIN"
  echo "Adding NS record to zone file..."
  cat >> "$ZONE_FILE" <<EOF

@       IN  NS  $NS_HOSTNAME.
$NS_HOSTNAME IN A $NS_IP
EOF
  echo "Reloading bind9..."
  systemctl reload bind9
  echo "NS record added: $NS_HOSTNAME with IP $NS_IP"
}

# Setup DNS tunnel (user must deploy their DNS server)
setup_dns_tunnel() {
  echo "Configure your DNS server with the public key."
  # You need to deploy your DNS server separately
}

# --- Main ---
main() {
  # Prompt for your domain
  read -p "Enter your domain (e.g., yourdomain.com): " DOMAIN
  # Your public key for DNS tunnel
  echo "Enter your DNS public key:"
  read -p "Public Key: " DNS_PUBLIC_KEY
  # NS hostname
  echo "Enter your NS hostname (e.g., ns1.yourdomain.com):"
  read -r NS_HOSTNAME

  # Install bind9 (if not installed)
  install_dependencies

  # Setup zone file if not exist
  ZONE_FILE="/etc/bind/db.$DOMAIN"
  if [ ! -f "$ZONE_FILE" ]; then
    echo "Creating zone file..."
    cat > "$ZONE_FILE" <<EOF
\$TTL 86400
@   IN  SOA $NS_HOSTNAME. admin.$DOMAIN. (
        2023010101 ; serial
        3600       ; refresh
        1800       ; retry
        604800     ; expire
        86400 )   ; minimum
@       IN  NS  $NS_HOSTNAME.
$NS_HOSTNAME IN A $(curl -s https://api.ipify.org)
EOF
  fi

  # Add NS record and reload
  add_ns_record

  # Save info for user
  save_dns_info

  # Instructions
  show_instructions

  echo "Installation complete."
}

# --- Menu ---
show_menu() {
  echo "=== Main Menu ==="
  echo "1) Run setup"
  echo "2) Manage users (not applicable here)"
  echo "3) Show DNS info"
  echo "4) Show setup instructions"
  echo "5) Set banner message"
  echo "6) Show current banner"
  echo "7) Exit"
}

# --- Main loop ---
while true; do
  show_menu
  read -p "Choose an option: " choice
  case "$choice" in
    1) main ;;
    2) echo "User management not implemented here." ;;
    3) show_info ;;
    4) show_instructions ;;
    5) set_banner ;;
    6) show_banner ;;
    7) echo "Goodbye!"; exit 0 ;;
    *) echo "Invalid option"; sleep 2 ;;
  esac
done
