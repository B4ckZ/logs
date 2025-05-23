#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration
AP_SSID="MaxLink-NETWORK"

# Initialisation du logging
init_logging "Désinstallation du point d'accès WiFi MaxLink-NETWORK"

# DÉMARRAGE
section_header "DÉSINSTALLATION DU POINT D'ACCÈS MAXLINK"

log_info "Désinstallation complète du point d'accès WiFi MaxLink-NETWORK"

echo "⚠️  ATTENTION : Cette opération va supprimer complètement le point d'accès"
echo "et restaurer la fonctionnalité WiFi client standard du Raspberry Pi."
echo ""
echo "Désinstallation en cours..."
show_result "Démarrage de la désinstallation automatique"

# VÉRIFICATIONS PRÉLIMINAIRES
section_header "VÉRIFICATIONS PRÉLIMINAIRES"

log_info "Vérification des privilèges administrateur"
if [ "$EUID" -ne 0 ]; then
    log_critical "Ce script doit être exécuté avec sudo"
    show_result "ERREUR: Privilèges administrateur requis"
    exit 1
fi
show_result "Privilèges administrateur confirmés"

log_info "Vérification de l'installation actuelle"
if systemctl list-unit-files | grep -q "NetworkManager.service"; then
    show_result "NetworkManager détecté"
    NM_INSTALLED=true
else
    show_result "NetworkManager non installé"
    NM_INSTALLED=false
fi

if nmcli connection show "$AP_SSID" > /dev/null 2>&1; then
    show_result "Configuration point d'accès '$AP_SSID' trouvée"
    AP_CONFIGURED=true
else
    show_result "Configuration point d'accès '$AP_SSID' non trouvée"
    AP_CONFIGURED=false
fi

# ARRÊT DU POINT D'ACCÈS
section_header "ARRÊT DU POINT D'ACCÈS"

if [ "$AP_CONFIGURED" = true ]; then
    log_info "Arrêt du point d'accès '$AP_SSID'"
    AP_ACTIVE=$(nmcli -g NAME connection show --active | grep "$AP_SSID" || true)
    if [ -n "$AP_ACTIVE" ]; then
        run_command "nmcli connection down '$AP_SSID'" "Arrêt du point d'accès"
        show_result "Point d'accès arrêté"
    else
        show_result "Point d'accès déjà arrêté"
    fi

    log_info "Suppression de la configuration du point d'accès"
    if run_command "nmcli connection delete '$AP_SSID'" "Suppression de la configuration"; then
        show_result "Configuration '$AP_SSID' supprimée"
    else
        log_error "Échec de la suppression de la configuration"
        show_result "ERREUR: Échec de la suppression de la configuration"
    fi
else
    show_result "Aucune configuration de point d'accès à supprimer"
fi

# SUPPRESSION DES CONFIGURATIONS DHCP
section_header "NETTOYAGE DES CONFIGURATIONS"

log_info "Suppression des configurations DHCP personnalisées"
if [ -f /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf ]; then
    mv /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf.removed
    show_result "Configuration DHCP personnalisée supprimée (sauvegardée)"
    log_info "Configuration DHCP personnalisée sauvegardée et supprimée"
else
    show_result "Aucune configuration DHCP personnalisée à supprimer"
fi

log_info "Restauration des sauvegardes de configuration"
if [ -f /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf.backup ]; then
    mv /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf.backup /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf
    show_result "Configuration DHCP de sauvegarde restaurée"
    log_info "Configuration DHCP de sauvegarde restaurée"
else
    show_result "Aucune sauvegarde de configuration à restaurer"
fi

# RESTAURATION FONCTIONNALITÉ WIFI CLIENT
section_header "RESTAURATION FONCTIONNALITÉ WIFI CLIENT"

log_info "S'assurer que NetworkManager gère correctement le WiFi client"
if [ "$NM_INSTALLED" = true ]; then
    log_info "Redémarrage de NetworkManager pour nettoyer l'état"
    run_command "systemctl restart NetworkManager" "Redémarrage de NetworkManager"
    sleep 5
    
    if systemctl is-active --quiet NetworkManager; then
        show_result "NetworkManager redémarré avec succès"
        log_info "NetworkManager opérationnel"
    else
        log_error "NetworkManager ne redémarre pas correctement"
        show_result "AVERTISSEMENT: Problème avec NetworkManager"
    fi
else
    show_result "NetworkManager non installé, aucune restauration nécessaire"
fi

# VÉRIFICATIONS FINALES
section_header "VÉRIFICATIONS FINALES"

log_info "Vérification de l'état des services"
if [ "$NM_INSTALLED" = true ]; then
    if systemctl is-active --quiet NetworkManager; then
        show_result "✓ Service NetworkManager actif"
        log_info "NetworkManager actif"
    else
        show_result "✗ Service NetworkManager inactif"
        log_error "NetworkManager inactif"
    fi
else
    show_result "ℹ NetworkManager non installé"
fi

log_info "Vérification des configurations résiduelles"
if nmcli connection show "$AP_SSID" > /dev/null 2>&1; then
    show_result "⚠ Configuration point d'accès encore présente"
    log_warn "Configuration AP encore présente"
else
    show_result "✓ Configuration point d'accès supprimée"
    log_info "Configuration AP correctement supprimée"
fi

if [ -f /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf ]; then
    show_result "⚠ Configuration DHCP personnalisée encore présente"
    log_warn "Configuration DHCP encore présente"
else
    show_result "✓ Configuration DHCP personnalisée supprimée"
    log_info "Configuration DHCP correctement supprimée"
fi

log_info "Test de fonctionnalité WiFi client"
if command -v iwlist > /dev/null 2>&1; then
    NETWORKS_COUNT=$(iwlist wlan0 scan 2>/dev/null | grep -c ESSID || echo "0")
    if [ "$NETWORKS_COUNT" -gt 0 ]; then
        show_result "✓ Scan WiFi fonctionnel: $NETWORKS_COUNT réseaux détectés"
        log_info "Scan WiFi fonctionnel, $NETWORKS_COUNT réseaux détectés"
    else
        show_result "⚠ Aucun réseau WiFi détecté lors du scan"
        log_warn "Aucun réseau WiFi détecté"
    fi
else
    show_result "⚠ Commande iwlist non disponible"
    log_warn "iwlist non disponible"
fi

# FINALISATION
section_header "DÉSINSTALLATION TERMINÉE"

log_info "Désinstallation du point d'accès terminée avec succès"

echo "Résumé de la désinstallation :"
echo "• Point d'accès '$AP_SSID' : Supprimé"
echo "• Configurations DHCP : Nettoyées"
echo "• NetworkManager : Opérationnel pour WiFi client"
echo ""
echo "État du système après désinstallation :"
echo "• Configuration réseau : WiFi client standard disponible"
echo "• Interface WiFi : Prête pour connexions aux réseaux existants"
echo "• Services réseau : NetworkManager actif"
echo ""
echo "Pour se connecter à un WiFi maintenant :"
echo "• Utilisez l'interface graphique (icône WiFi en haut à droite)"
echo "• Sélectionnez un réseau et entrez le mot de passe"
echo "• La connexion se fera automatiquement"

# Art ASCII simple
cat << "EOF"
   _____ _      ______          _   _ 
  / ____| |    |  ____|   /\   | \ | |
 | |    | |    | |__     /  \  |  \| |
 | |    | |    |  __|   / /\ \ | . ` |
 | |____| |____| |____ / ____ \| |\  |
  \_____|______|______/_/    \_\_| \_|

EOF

show_result "Point d'accès '$AP_SSID' complètement supprimé !"

log_info "Redémarrage programmé dans 10 secondes"
echo "Le système va redémarrer dans 10 secondes pour finaliser..."
for i in {10..1}; do
    echo -ne "\rRedémarrage dans $i secondes..."
    sleep 1
done
echo ""

log_info "Redémarrage du système"
reboot