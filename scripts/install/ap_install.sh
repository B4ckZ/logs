#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION DU MODE ACCESS POINT
# Version épurée - Less is More
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables et du logging
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation du mode Access Point"

# Configuration AP par défaut
AP_CHANNEL="6"        # Canal 2.4GHz stable
AP_BAND="bg"         # Mode compatible
AP_INTERFACE="wlan0"  # Interface WiFi

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
}

# ===============================================================================
# VÉRIFICATIONS
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 1 : VÉRIFICATIONS"
echo "========================================================================"
echo ""

send_progress 10 "Vérifications initiales"

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Privilèges root requis ✗"
    exit 1
fi

# Vérifier l'interface WiFi
echo "◦ Vérification de l'interface WiFi..."
if ! ip link show $AP_INTERFACE >/dev/null 2>&1; then
    echo "  ↦ Interface $AP_INTERFACE non trouvée ✗"
    exit 1
fi
echo "  ↦ Interface $AP_INTERFACE disponible ✓"

# Vérifier NetworkManager
echo ""
echo "◦ Vérification de NetworkManager..."
if ! systemctl is-active --quiet NetworkManager; then
    echo "  ↦ NetworkManager non actif ✗"
    exit 1
fi
echo "  ↦ NetworkManager actif ✓"

echo ""
sleep 2

# ===============================================================================
# INSTALLATION DES PAQUETS
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : VÉRIFICATION DES PAQUETS"
echo "========================================================================"
echo ""

send_progress 25 "Vérification des paquets"

echo "◦ Vérification des paquets requis..."

# Liste des paquets nécessaires
PACKAGES_NEEDED=""

# Vérifier dnsmasq
if ! dpkg -l dnsmasq >/dev/null 2>&1; then
    PACKAGES_NEEDED="$PACKAGES_NEEDED dnsmasq"
    echo "  ↦ dnsmasq manquant"
else
    echo "  ↦ dnsmasq installé ✓"
fi

# Installer si nécessaire
if [ -n "$PACKAGES_NEEDED" ]; then
    echo ""
    echo "◦ Installation des paquets manquants..."
    apt-get update -qq
    apt-get install -y $PACKAGES_NEEDED
    echo "  ↦ Paquets installés ✓"
else
    echo "  ↦ Tous les paquets sont présents ✓"
fi

echo ""
sleep 2

# ===============================================================================
# PRÉPARATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 3 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 40 "Préparation du système"

# Désactiver les connexions WiFi actives
echo "◦ Désactivation des connexions WiFi existantes..."
nmcli device disconnect $AP_INTERFACE 2>/dev/null || true
nmcli connection delete "$AP_SSID" 2>/dev/null || true
echo "  ↦ Connexions nettoyées ✓"

# Arrêter dnsmasq système (on utilisera celui de NetworkManager)
echo ""
echo "◦ Configuration de dnsmasq..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
echo "  ↦ Service dnsmasq système désactivé ✓"

echo ""
sleep 2

# ===============================================================================
# CRÉATION DE LA CONFIGURATION AP
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DU POINT D'ACCÈS"
echo "========================================================================"
echo ""

send_progress 60 "Configuration du point d'accès"

echo "◦ Création du profil Access Point..."
echo "  ↦ SSID: $AP_SSID"
echo "  ↦ IP: $AP_IP/$AP_NETMASK"
echo "  ↦ Canal: $AP_CHANNEL (2.4GHz)"

# Créer la connexion AP avec NetworkManager
nmcli connection add \
    type wifi \
    ifname $AP_INTERFACE \
    con-name "$AP_SSID" \
    autoconnect yes \
    ssid "$AP_SSID" \
    mode ap \
    802-11-wireless.band $AP_BAND \
    802-11-wireless.channel $AP_CHANNEL \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$AP_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses "$AP_IP/$AP_NETMASK" \
    ipv6.method disabled >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "  ↦ Profil AP créé ✓"
else
    echo "  ↦ Erreur lors de la création du profil ✗"
    exit 1
fi

# Configuration DHCP via NetworkManager
echo ""
echo "◦ Configuration DHCP..."
echo "  ↦ Plage: $AP_DHCP_START - $AP_DHCP_END"

# NetworkManager gère le DHCP automatiquement avec 'shared'
# Mais on peut personnaliser via dnsmasq
mkdir -p /etc/NetworkManager/dnsmasq-shared.d/

cat > /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf << EOF
# Configuration DHCP MaxLink AP
interface=$AP_INTERFACE
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,12h
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP,8.8.8.8
dhcp-authoritative
EOF

echo "  ↦ Configuration DHCP appliquée ✓"

echo ""
sleep 2

# ===============================================================================
# ACTIVATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 5 : ACTIVATION DU POINT D'ACCÈS"
echo "========================================================================"
echo ""

send_progress 80 "Activation du point d'accès"

echo "◦ Démarrage du point d'accès..."

# Redémarrer NetworkManager pour appliquer la config dnsmasq
systemctl restart NetworkManager
sleep 3

# Activer la connexion AP
nmcli connection up "$AP_SSID"

if [ $? -eq 0 ]; then
    echo "  ↦ Point d'accès activé ✓"
else
    echo "  ↦ Erreur lors de l'activation ✗"
    exit 1
fi

# Vérifier l'état
echo ""
echo "◦ Vérification de l'état..."
sleep 2

if nmcli connection show --active | grep -q "$AP_SSID"; then
    echo "  ↦ Point d'accès opérationnel ✓"
else
    echo "  ↦ Point d'accès non actif ✗"
    exit 1
fi

echo ""
sleep 2

# ===============================================================================
# FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 95 "Finalisation"

echo "◦ Configuration de démarrage automatique..."
echo "  ↦ Le point d'accès démarrera automatiquement ✓"

echo ""
echo "◦ Informations de connexion :"
echo "  ↦ Nom du réseau : $AP_SSID"
echo "  ↦ Mot de passe  : $AP_PASSWORD"
echo "  ↦ Adresse IP    : $AP_IP"
echo "  ↦ Plage DHCP    : $AP_DHCP_START - $AP_DHCP_END"

send_progress 100 "Installation terminée"

echo ""
echo "◦ Installation terminée avec succès !"
echo ""

echo "  ↦ Redémarrage dans 10 secondes..."
echo ""

log_info "Installation AP terminée - Redémarrage du système"

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
reboot