#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration du point d'accès
AP_SSID="MaxLink-NETWORK"
AP_PASSWORD="MDPsupersecret007"
AP_IP="192.168.4.1"
AP_NETMASK="24"
DHCP_START="192.168.4.10"
DHCP_END="192.168.4.100"

# Initialisation du logging
init_logging "Installation du point d'accès WiFi MaxLink-NETWORK"

# DÉMARRAGE
section_header "INSTALLATION DU POINT D'ACCÈS MAXLINK"

log_info "Configuration à installer :"
echo "• SSID: $AP_SSID"
echo "• Adresse IP: $AP_IP/$AP_NETMASK"
echo "• Plage DHCP: $DHCP_START - $DHCP_END"
show_result "Configuration validée"

# VÉRIFICATIONS PRÉLIMINAIRES
section_header "VÉRIFICATIONS PRÉLIMINAIRES"

log_info "Vérification des privilèges administrateur"
if [ "$EUID" -ne 0 ]; then
    log_critical "Ce script doit être exécuté avec sudo"
    show_result "ERREUR: Privilèges administrateur requis"
    exit 1
fi
show_result "Privilèges administrateur confirmés"

log_info "Vérification de l'interface WiFi"
if ! ip link show wlan0 > /dev/null 2>&1; then
    log_critical "Interface WiFi wlan0 non trouvée"
    show_result "ERREUR: Interface WiFi wlan0 non trouvée"
    exit 1
fi
show_result "Interface wlan0 détectée"

# INSTALLATION DE NETWORKMANAGER
section_header "INSTALLATION DE NETWORKMANAGER"

log_info "Mise à jour des dépôts de paquets"
if run_command "apt-get update -y" "Mise à jour des dépôts"; then
    show_result "Dépôts mis à jour avec succès"
else
    log_error "Échec de la mise à jour des dépôts"
    show_result "ERREUR: Mise à jour des dépôts échouée"
    exit 1
fi

log_info "Installation de NetworkManager"
echo "Cette opération peut prendre quelques minutes..."
if run_command "DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager" "Installation de NetworkManager"; then
    show_result "NetworkManager installé avec succès"
else
    log_error "Échec de l'installation de NetworkManager"
    show_result "ERREUR: Installation de NetworkManager échouée"
    exit 1
fi

# CONFIGURATION NETWORKMANAGER
section_header "CONFIGURATION NETWORKMANAGER"

log_info "Configuration des services réseau"
run_command "systemctl enable NetworkManager" "Activation de NetworkManager au démarrage"
run_command "systemctl start NetworkManager" "Démarrage de NetworkManager"

log_info "Attente du démarrage complet de NetworkManager"
sleep 8

if ! systemctl is-active --quiet NetworkManager; then
    log_error "NetworkManager n'a pas pu démarrer"
    show_result "ERREUR: NetworkManager inactif"
    exit 1
fi
show_result "NetworkManager opérationnel"

# CRÉATION DU POINT D'ACCÈS
section_header "CRÉATION DU POINT D'ACCÈS"

log_info "Suppression des configurations hotspot existantes"
EXISTING_HOTSPOT=$(nmcli -g NAME connection show | grep "$AP_SSID" || true)
if [ -n "$EXISTING_HOTSPOT" ]; then
    run_command "nmcli connection delete '$EXISTING_HOTSPOT'" "Suppression ancienne configuration"
    show_result "Ancienne configuration supprimée"
else
    show_result "Aucune configuration existante"
fi

log_info "Création du point d'accès '$AP_SSID'"
if run_command "nmcli connection add type wifi ifname wlan0 con-name '$AP_SSID' autoconnect yes ssid '$AP_SSID'" "Création du point d'accès"; then
    show_result "Point d'accès créé"
else
    log_error "Échec de la création du point d'accès"
    show_result "ERREUR: Création du point d'accès échouée"
    exit 1
fi

log_info "Configuration des paramètres WiFi"
run_command "nmcli connection modify '$AP_SSID' 802-11-wireless.mode ap 802-11-wireless.band bg" "Configuration mode AP 2.4GHz"
show_result "Mode point d'accès configuré (2.4GHz)"

log_info "Configuration de la sécurité WPA2"
run_command "nmcli connection modify '$AP_SSID' 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk '$AP_PASSWORD'" "Configuration sécurité WPA2"
show_result "Sécurité WPA2 configurée"

log_info "Configuration du réseau IP"
run_command "nmcli connection modify '$AP_SSID' ipv4.method shared ipv4.addresses '$AP_IP/$AP_NETMASK'" "Configuration adresse IP"
show_result "Adresse IP configurée: $AP_IP/$AP_NETMASK"

log_info "Configuration DHCP personnalisée"
mkdir -p /etc/NetworkManager/dnsmasq-shared.d/
if [ -f /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf ]; then
    mv /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf.backup
fi

cat > /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf << EOL
dhcp-range=$DHCP_START,$DHCP_END,12h
EOL
show_result "Plage DHCP configurée: $DHCP_START - $DHCP_END"

# ACTIVATION DU POINT D'ACCÈS
section_header "ACTIVATION DU POINT D'ACCÈS"

log_info "Redémarrage de NetworkManager"
run_command "systemctl restart NetworkManager" "Redémarrage NetworkManager"
sleep 8

log_info "Activation du point d'accès '$AP_SSID'"
if run_command "nmcli connection up '$AP_SSID'" "Activation du point d'accès"; then
    show_result "Point d'accès activé avec succès"
else
    log_error "Échec de l'activation du point d'accès"
    show_result "ERREUR: Activation du point d'accès échouée"
    exit 1
fi

# TESTS DE VALIDATION
section_header "TESTS DE VALIDATION"

log_info "Vérification de l'état du point d'accès"
sleep 5

AP_ACTIVE=$(nmcli -g NAME connection show --active | grep "$AP_SSID" || true)
if [ -n "$AP_ACTIVE" ]; then
    show_result "✓ Point d'accès '$AP_SSID' actif"
else
    log_error "Point d'accès inactif après activation"
    show_result "✗ Point d'accès '$AP_SSID' inactif"
fi

AP_IP_CURRENT=$(ip addr show wlan0 | grep -o "inet [0-9.]*" | head -1 | cut -d' ' -f2 || true)
if [ "$AP_IP_CURRENT" = "$AP_IP" ]; then
    show_result "✓ Adresse IP correcte: $AP_IP_CURRENT"
else
    log_warn "Adresse IP inattendue: $AP_IP_CURRENT (attendue: $AP_IP)"
    show_result "⚠ Adresse IP: $AP_IP_CURRENT"
fi

INTERFACE_MODE=$(iw wlan0 info | grep type | awk '{print $2}' 2>/dev/null || echo "unknown")
if [ "$INTERFACE_MODE" = "AP" ]; then
    show_result "✓ Interface en mode Point d'Accès"
else
    log_warn "Interface en mode inattendu: $INTERFACE_MODE"
    show_result "⚠ Interface en mode: $INTERFACE_MODE"
fi

# FINALISATION
section_header "INSTALLATION TERMINÉE AVEC SUCCÈS"

log_info "Installation du point d'accès terminée avec succès"

echo "Configuration du point d'accès MaxLink :"
echo "• SSID: $AP_SSID"
echo "• Mot de passe: $AP_PASSWORD"
echo "• Adresse IP: $AP_IP/$AP_NETMASK"
echo "• Plage DHCP: $DHCP_START - $DHCP_END"
echo "• Démarrage automatique: Activé"
echo ""
echo "Le point d'accès est maintenant opérationnel et se lancera"
echo "automatiquement à chaque démarrage du Raspberry Pi."

# Art ASCII simple
cat << "EOF"
  _____ _   _  _____ _______       _      _      
 |_   _| \ | |/ ____|__   __|/\   | |    | |     
   | | |  \| | (___    | |  /  \  | |    | |     
   | | | . ` |\___ \   | | / /\ \ | |    | |     
  _| |_| |\  |____) |  | |/ ____ \| |____| |____ 
 |_____|_| \_|_____/   |_/_/    \_\______|______|

EOF

show_result "Point d'accès '$AP_SSID' installé et prêt !"

log_info "Redémarrage programmé dans 10 secondes"
echo "Le système va redémarrer dans 10 secondes pour finaliser l'installation..."
for i in {10..1}; do
    echo -ne "\rRedémarrage dans $i secondes..."
    sleep 1
done
echo ""

log_info "Redémarrage du système"
reboot