#!/bin/bash

log_file="/tmp/setup_script.log"
exec > >(tee -a "$log_file") 2>&1

function log() {
    echo -e "\033[33m[INFO] $1\033[0m"
}

function error() {
    echo -e "\033[31m[ERROR] $1\033[0m" >&2
}

clear
echo "" 
echo -e "     \033[32m██╗ ██████╗ ███████╗██╗  ██╗    ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗    ██╗     ██╗      ██████╗\033[0m"
echo -e "     \033[32m██║██╔═══██╗██╔════╝██║  ██║    ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝    ██║     ██║     ██╔════╝\033[0m"
echo -e "     \033[32m██║██║   ██║███████╗███████║    ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗    ██║     ██║     ██║\033[0m"
echo -e "\033[32m██   ██║██║   ██║╚════██║██╔══██║    ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║    ██║     ██║     ██║\033[0m"
echo -e "\033[32m╚█████╔╝╚██████╔╝███████║██║  ██║    ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║    ███████╗███████╗╚██████╗\033[0m"
echo -e "\033[32m ╚════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝    ╚══════╝╚══════╝ ╚═════╝\033[0m"
echo "" 
echo -e "\033[36mWelcome to my setup script\033[0m"
echo -e "\033[36mWhat would you like to do today?\033[0m"
echo ""

# Menu options
echo "1. Update System"
echo "2. Install Watermark"
echo "3. Install SSH"
echo "4. Install WireGuard"
echo "5. Install TPM"
echo "6. Install Mailcow"
echo "7. Exit"
echo ""

# Get user choice
read -p "Please select an option [1-7]: " choice

case $choice in
    1)
        log "Updating system..."
        if sudo apt-get -qq update && sudo apt-get -qq upgrade -y; then
            log "System updated successfully."
        else
            error "System update failed. Check logs for details."
        fi
        ;;
    2)
        log "Installing watermark..."
        if bash <(curl -fsSL https://raw.githubusercontent.com/DIVISIONSolar/linux_watermarksetup/refs/heads/main/setup.sh); then
            log "Watermark installed successfully."
        else
            error "Watermark installation failed."
        fi
        ;;
    3)
        log "Installing SSH..."
        if bash <(curl -fsSL https://raw.githubusercontent.com/DIVISIONSolar/ssh-key/refs/heads/main/install.sh); then
            log "SSH installed successfully."
        else
            error "SSH installation failed."
        fi
        ;;
    4)
        log "Installing WireGuard..."
        if sudo apt-get -qq install -y wireguard && bash <(curl -fsSL https://raw.githubusercontent.com/DIVISIONSolar/wireguard.sh/refs/heads/main/wireguard.sh); then
            log "WireGuard installed successfully."
        else
            error "WireGuard installation failed."
        fi
        ;;
    5)
        log "Setting up TPM..."
        if bash <(curl -s https://raw.githubusercontent.com/DIVISIONSolar/TPM2-LUKS/refs/heads/main/tpm2-luks-unlock.sh); then
            log "TPM setup successfully."
        else
            error "TPM setup failed."
        fi
        ;;
    6) 
        log "Installing Mailcow..."
        if curl -sSL https://get.docker.com/ | CHANNEL=stable sh && \
           systemctl enable --now docker && \
           umask_val=$(umask) && \
           if [ "$umask_val" != "0022" ]; then error "umask is not 0022. Current umask: $umask_val"; exit 1; fi && \
           cd /opt && \
           git clone https://github.com/mailcow/mailcow-dockerized && \
           cd mailcow-dockerized && \
           ./generate_config.sh && \
           docker compose pull && \
           docker compose up -d; then
            log "Mailcow installed successfully."
        else
            error "Mailcow installation failed."
        fi
        ;;
    7)
        log "Exiting the script. Have a great day!"
        exit 0
        ;;
    *)
        error "Invalid option. Please select a valid option from the menu."
        ;;
esac
