#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration
AP_SSID="MaxLink-NETWORK"

# Initialisation du logging
init_logging "Démarrage du point d'accès WiFi MaxLink-NETWORK"

# DÉMARRAGE
section_header "DÉMARRAGE DU POINT D'ACCÈS MAXLINK"

log_info "Démarrage du point d'accès WiFi MaxLink-NETWORK"

# VÉRIFICATIONS PRÉLIMINAIRES
section_header "VÉRIFICATIONS PRÉLIMINAIRES"

log_info "Vérification des privilèges administrateur"
if [ "$EUID" -ne 0 ]; then
    log_critical "Ce script doit être exécuté avec sudo"
    show_result "ERREUR: Privilèges administrateur requis"
    exit 1
fi
show_result "Privilèges administrateur confirmés"

log_info "Vérification de l'installation de NetworkManager"
if ! systemctl list-unit-files | grep -q "NetworkManager.service"; then
    log_critical "NetworkManager non installé"
    show_result "ERREUR: NetworkManager non installé. Exécutez d'abord ap_install.sh"
    exit 1
fi
show_result "NetworkManager installé"

log_info "Vérification de la configuration du point d'accès"
if ! nmcli connection show "$AP_SSID" > /dev/null 2>&1; then
    log_critical "Configuration '$AP_SSID' non trouvée"
    show_result "ERREUR: Configuration '$AP_SSID' non trouvée. Exécutez d'abord ap_install.sh"
    exit 1
fi
show_result "Configuration '$AP_SSID' trouvée"

log_info "Vérification de l'interface WiFi"
if ! ip link show wlan0 > /dev/null 2>&1; then
    log_critical "Interface WiFi wlan0 non trouvée"
    show_result "ERREUR: Interface WiFi wlan0 non trouvée"
    exit 1
fi
show_result "Interface wlan0 détectée"

# ÉTAT ACTUEL
section_header "VÉRIFICATION DE L'ÉTAT ACTUEL"

log_info "Vérification de l'état de NetworkManager"
if ! systemctl is-active --quiet NetworkManager; then
    log_warn "NetworkManager arrêté, démarrage en cours"
    run_command "systemctl start NetworkManager" "Démarrage de NetworkManager"
    sleep 5
    if ! systemctl is-active --quiet NetworkManager; then
        log_error "Impossible de démarrer NetworkManager"
        show_result "ERREUR: NetworkManager ne démarre pas"
        exit 1
    fi
fi
show_result "NetworkManager en cours d'exécution"

log_info "Vérification de l'état actuel du point d'accès"
AP_ACTIVE=$(nmcli -g NAME connection show --active | grep "$AP_SSID" || true)
if [ -n "$AP_ACTIVE" ]; then
    AP_IP_CURRENT=$(ip addr show wlan0 | grep -o "inet [0-9.]*" | head -1 | cut -d' ' -f2 || true)
    if [ -n "$AP_IP_CURRENT" ]; then
        show_result "Point d'accès '$AP_SSID' déjà opérationnel (IP: $AP_IP_CURRENT)"
        log_info "Point d'accès déjà actif, aucune action nécessaire"
        
        section_header "POINT D'ACCÈS DÉJÀ OPÉRATIONNEL"
        echo "Le point d'accès MaxLink-NETWORK est déjà actif."
        echo "Adresse IP: $AP_IP_CURRENT"
        echo "Aucune action nécessaire."
        
        cat << "EOF"
   ____  _  __
  / __ \| |/ /
 | |  | | ' / 
 | |  | |  <  
 | |__| | . \ 
  \____/|_|\_\

EOF
        show_result "Point d'accès déjà opérationnel !"
        exit 0
    else
        log_warn "Point d'accès actif mais problème détecté, redémarrage"
        run_command "nmcli connection down '$AP_SSID'" "Arrêt du point d'accès"
        sleep 3
    fi
else
    show_result "Point d'accès '$AP_SSID' inactif"
fi

# ACTIVATION DU POINT D'ACCÈS
section_header "ACTIVATION DU POINT D'ACCÈS"

log_info "Activation du point d'accès '$AP_SSID'"
if run_command "nmcli connection up '$AP_SSID'" "Activation du point d'accès"; then
    show_result "Commande d'activation exécutée"
else
    log_error "Échec de la commande d'activation"
    show_result "ERREUR: Commande d'activation échouée"
    exit 1
fi

log_info "Attente de l'initialisation complète"
sleep 8
show_result "Initialisation terminée"

# VÉRIFICATION DU SUCCÈS
section_header "VÉRIFICATION DU DÉMARRAGE"

log_info "Vérification de l'état du point d'accès"
AP_ACTIVE=$(nmcli -g NAME connection show --active | grep "$AP_SSID" || true)
if [ -n "$AP_ACTIVE" ]; then
    show_result "✓ Point d'accès '$AP_SSID' actif"
else
    log_error "Point d'accès inactif après activation"
    show_result "✗ Point d'accès '$AP_SSID' inactif"
    exit 1
fi

AP_IP_CURRENT=$(ip addr show wlan0 | grep -o "inet [0-9.]*" | head -1 | cut -d' ' -f2 || true)
if [ -n "$AP_IP_CURRENT" ]; then
    show_result "✓ Adresse IP assignée: $AP_IP_CURRENT"
else
    log_error "Aucune adresse IP assignée"
    show_result "✗ Aucune adresse IP assignée"
    exit 1
fi

INTERFACE_MODE=$(iw wlan0 info | grep type | awk '{print $2}' 2>/dev/null || echo "unknown")
if [ "$INTERFACE_MODE" = "AP" ]; then
    show_result "✓ Interface en mode Point d'Accès"
else
    log_warn "Interface en mode inattendu: $INTERFACE_MODE"
    show_result "⚠ Interface en mode: $INTERFACE_MODE"
fi

if pgrep -f "dnsmasq.*192.168.4" > /dev/null; then
    show_result "✓ Serveur DHCP opérationnel"
else
    log_warn "Serveur DHCP non détecté"
    show_result "⚠ Serveur DHCP non détecté (peut être normal)"
fi

# FINALISATION
section_header "POINT D'ACCÈS DÉMARRÉ AVEC SUCCÈS"

log_info "Point d'accès démarré avec succès"

echo "État du point d'accès MaxLink :"
echo "• SSID: $AP_SSID"
echo "• Statut: Actif"
echo "• Adresse IP: $AP_IP_CURRENT"
echo "• Mode: Point d'Accès"
echo ""
echo "Le point d'accès est maintenant accessible aux clients WiFi."

# Art ASCII simple
cat << "EOF"
  _____ _______       _____ _______ 
 / ____|__   __|/\   |  __ \__   __|
| (___    | |  /  \  | |__) | | |   
 \___ \   | | / /\ \ |  _  /  | |   
 ____) |  | |/ ____ \| | \ \  | |   
|_____/   |_/_/    \_\_|  \_\ |_|   

EOF

show_result "Point d'accès '$AP_SSID' démarré avec succès !"

log_info "Redémarrage programmé dans 10 secondes"
echo "Le système va redémarrer dans 10 secondes pour finaliser..."
for i in {10..1}; do
    echo -ne "\rRedémarrage dans $i secondes..."
    sleep 1
done
echo ""

log_info "Redémarrage du système"
reboot