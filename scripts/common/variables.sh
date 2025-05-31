#!/bin/bash

# ===============================================================================
# MAXLINK - CONFIGURATION CENTRALE
# ===============================================================================
# Ce fichier contient toutes les variables configurables du projet MaxLink.
# Modifiez ces valeurs selon vos besoins, elles seront utilisées partout.
# ===============================================================================

# ===============================================================================
# INFORMATIONS GÉNÉRALES DU PROJET
# ===============================================================================

# Version et informations de l'interface
MAXLINK_VERSION="2.4"
MAXLINK_COPYRIGHT="© 2025 WERIT. Tous droits réservés."

# ===============================================================================
# CONFIGURATION DE L'OVERLAY DE VERSION
# ===============================================================================

# Configuration de l'overlay de version sur le fond d'écran
VERSION_OVERLAY_ENABLED=true                 # Activer/désactiver l'overlay
VERSION_OVERLAY_FONT_SIZE=48                 # Taille de la police (pixels)
VERSION_OVERLAY_FONT_COLOR="#FFFFFF"         # Couleur du texte (hex)
VERSION_OVERLAY_SHADOW_COLOR="#000000"       # Couleur de l'ombre (hex)
VERSION_OVERLAY_SHADOW_OPACITY=128           # Opacité de l'ombre (0-255)
VERSION_OVERLAY_MARGIN_RIGHT=50              # Marge depuis le bord droit
VERSION_OVERLAY_MARGIN_BOTTOM=50             # Marge depuis le bas
VERSION_OVERLAY_FONT_BOLD=true               # Police en gras
VERSION_OVERLAY_PREFIX="MaxLink "            # Préfixe avant la version

# ===============================================================================
# CONFIGURATION UTILISATEUR SYSTÈME
# ===============================================================================

# Utilisateur principal du Raspberry Pi (créé lors du flash avec Pi Imager)
SYSTEM_USER="prod"
SYSTEM_USER_HOME="/home/$SYSTEM_USER"

# ===============================================================================
# CONFIGURATION DES UTILISATEURS SFTP/FILEZILLA
# ===============================================================================

# Super admin FileZilla (accès complet au système)
SFTP_ADMIN_USER="max"
SFTP_ADMIN_PASS="max"
SFTP_ADMIN_DESC="Super Admin FileZilla - Accès complet"

# Utilisateur limité (téléchargement uniquement)
SFTP_DATA_USER="franck"
SFTP_DATA_PASS="franck"
SFTP_DATA_DIR="/home/franck/downloads"
SFTP_DATA_DESC="Utilisateur limité - Téléchargement uniquement"

# Liste extensible d'utilisateurs limités pour évolutions futures
# Format: "username:password:directory:description"
SFTP_LIMITED_USERS=(
    "franck:franck:/home/franck/downloads:Utilisateur limité - Téléchargement uniquement"
    # Ajouter d'autres utilisateurs ici si besoin
    # "client1:Pass123:/home/client1/data:Client 1 - Accès données"
    # "client2:Pass456:/home/client2/exports:Client 2 - Export only"
)

# ===============================================================================
# CONFIGURATION RÉSEAU WIFI
# ===============================================================================

# Réseau WiFi pour les mises à jour
WIFI_SSID="Max"
WIFI_PASSWORD="1234567890"

# Configuration du point d'accès WiFi
AP_SSID="MaxLink-NETWORK"
AP_PASSWORD="MDPsupersecret007"
AP_IP="192.168.4.1"
AP_NETMASK="24"
AP_DHCP_START="192.168.4.10"
AP_DHCP_END="192.168.4.100"

# ===============================================================================
# CONFIGURATION GITHUB
# ===============================================================================

# Configuration du dépôt GitHub pour le dashboard
GITHUB_REPO_URL="https://github.com/B4ckZ/MaxLink"
GITHUB_BRANCH="main"
GITHUB_DASHBOARD_DIR="DashBoardV1"
# Token GitHub (laisser vide si dépôt public)
GITHUB_TOKEN=""

# ===============================================================================
# CONFIGURATION MQTT
# ===============================================================================

# Configuration du broker MQTT
MQTT_USER="mosquitto"
MQTT_PASS="mqtt"
MQTT_PORT="1883"
MQTT_WEBSOCKET_PORT="9001"

# ===============================================================================
# CONFIGURATION FILTRAGE MQTT
# ===============================================================================

# Topics MQTT à ignorer dans les statistiques
# Utilisez des patterns avec wildcards (* et +) si nécessaire
MQTT_IGNORED_TOPICS=(
    # Topics de test et latence
    "test/#"
    "test/latency/+"
    "test/widget/+"
    
    # Topics internes des widgets qui génèrent du bruit
    "rpi/network/mqtt/stats"
    "rpi/network/mqtt/topics"
    
    # Ajoutez vos propres topics à ignorer ici
    # "device/telemetry/frequent"
    # "sensor/noisy/+"
)

# Convertir en string pour l'export (séparateur |)
MQTT_IGNORED_TOPICS_STRING=$(IFS='|'; echo "${MQTT_IGNORED_TOPICS[*]}")

# ===============================================================================
# CONFIGURATION NGINX
# ===============================================================================

# Configuration du serveur web
NGINX_DASHBOARD_DIR="/var/www/maxlink-dashboard"
NGINX_DASHBOARD_DOMAIN="maxlink-dashboard.local"
NGINX_PORT="80"

# ===============================================================================
# CONFIGURATION FICHIERS SYSTÈME
# ===============================================================================

# Fichiers de configuration système
CONFIG_FILE="/boot/firmware/config.txt"

# Répertoires pour les assets
BG_IMAGE_SOURCE_DIR="assets"
BG_IMAGE_FILENAME="bg.jpg"
BG_IMAGE_DEST_DIR="/usr/share/backgrounds/maxlink"

# ===============================================================================
# CONFIGURATION INTERFACE GRAPHIQUE
# ===============================================================================

# Configuration de l'environnement de bureau
DESKTOP_FONT="Inter 12"
DESKTOP_BG_COLOR="#000000"
DESKTOP_FG_COLOR="#ECEFF4"
DESKTOP_SHADOW_COLOR="#000000"

# Services disponibles dans l'interface
# Format: "id:nom:statut_initial"
SERVICES_LIST=(
    "update:Update RPI:active"
    "ap:Network AP:active" 
    "nginx:NginX Web:active"
    "mqtt:MQTT BKR:active"
)

# ===============================================================================
# CONFIGURATION DU LOGGING
# ===============================================================================

# Configuration des logs
LOG_TO_CONSOLE_DEFAULT=false
LOG_TO_FILE_DEFAULT=true

# ===============================================================================
# CONFIGURATION RÉSEAU ET SÉCURITÉ
# ===============================================================================

# Timeouts réseau (en secondes)
NETWORK_TIMEOUT=5
PING_COUNT=3
APT_RETRY_MAX_ATTEMPTS=3
APT_RETRY_DELAY=3

# ===============================================================================
# CONFIGURATION AVANCÉE
# ===============================================================================

# Délais d'affichage pour l'interface (en secondes)
DISPLAY_DELAY_STARTUP=2
DISPLAY_DELAY_BETWEEN_STEPS=2

# Configuration ventilateur
FAN_TEMP_MIN=0
FAN_TEMP_ACTIVATE=60
FAN_TEMP_MAX=60

# ===============================================================================
# CONFIGURATION DES DELAYS DE DÉMARRAGE
# ===============================================================================

# Delays de démarrage des services
STARTUP_DELAY_MOSQUITTO=10
STARTUP_DELAY_NGINX=20
STARTUP_DELAY_WIDGETS=40


# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Fonction pour obtenir l'utilisateur système effectif
get_effective_user() {
    if [ -d "$SYSTEM_USER_HOME" ]; then
        echo "$SYSTEM_USER"
    elif [ -n "$SUDO_USER" ] && [ -d "/home/$SUDO_USER" ]; then
        echo "$SUDO_USER"
    else
        echo "$SYSTEM_USER"
    fi
}

# Fonction pour obtenir le répertoire home effectif
get_effective_user_home() {
    local effective_user=$(get_effective_user)
    echo "/home/$effective_user"
}

# Fonction pour construire les chemins d'assets
get_bg_image_source() {
    echo "${MAXLINK_BASE_DIR:-/media/prod/MAXLINK}/$BG_IMAGE_SOURCE_DIR/$BG_IMAGE_FILENAME"
}

get_bg_image_dest() {
    echo "$BG_IMAGE_DEST_DIR/$BG_IMAGE_FILENAME"
}

# ===============================================================================
# VALIDATION DE LA CONFIGURATION
# ===============================================================================

# Fonction pour valider la configuration
validate_config() {
    local errors=0
    
    # Vérifier les variables essentielles
    [ -z "$WIFI_SSID" ] && echo "ERREUR: WIFI_SSID non défini" && ((errors++))
    [ -z "$AP_SSID" ] && echo "ERREUR: AP_SSID non défini" && ((errors++))
    [ -z "$SYSTEM_USER" ] && echo "ERREUR: SYSTEM_USER non défini" && ((errors++))
    [ -z "$SFTP_ADMIN_USER" ] && echo "ERREUR: SFTP_ADMIN_USER non défini" && ((errors++))
    [ -z "$SFTP_DATA_USER" ] && echo "ERREUR: SFTP_DATA_USER non défini" && ((errors++))
    
    # Vérifier la validité de l'IP
    if [[ ! "$AP_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERREUR: AP_IP ($AP_IP) n'est pas une adresse IP valide"
        ((errors++))
    fi
    
    return $errors
}

# ===============================================================================
# VARIABLES DYNAMIQUES
# ===============================================================================

# Ces variables sont calculées automatiquement
EFFECTIVE_USER=$(get_effective_user)
EFFECTIVE_USER_HOME=$(get_effective_user_home)
BG_IMAGE_SOURCE=$(get_bg_image_source)
BG_IMAGE_DEST=$(get_bg_image_dest)

# ===============================================================================
# EXPORT DES VARIABLES
# ===============================================================================

# Exporter toutes les variables nécessaires
export MAXLINK_VERSION MAXLINK_COPYRIGHT
export VERSION_OVERLAY_ENABLED VERSION_OVERLAY_FONT_SIZE
export VERSION_OVERLAY_FONT_COLOR VERSION_OVERLAY_SHADOW_COLOR VERSION_OVERLAY_SHADOW_OPACITY
export VERSION_OVERLAY_MARGIN_RIGHT VERSION_OVERLAY_MARGIN_BOTTOM
export VERSION_OVERLAY_FONT_BOLD VERSION_OVERLAY_PREFIX
export SYSTEM_USER SYSTEM_USER_HOME
export EFFECTIVE_USER EFFECTIVE_USER_HOME
export SFTP_ADMIN_USER SFTP_ADMIN_PASS SFTP_ADMIN_DESC
export SFTP_DATA_USER SFTP_DATA_PASS SFTP_DATA_DIR SFTP_DATA_DESC
export SFTP_LIMITED_USERS
export WIFI_SSID WIFI_PASSWORD
export AP_SSID AP_PASSWORD AP_IP AP_NETMASK AP_DHCP_START AP_DHCP_END
export GITHUB_REPO_URL GITHUB_BRANCH GITHUB_DASHBOARD_DIR GITHUB_TOKEN
export NGINX_DASHBOARD_DIR NGINX_DASHBOARD_DOMAIN NGINX_PORT
export CONFIG_FILE
export BG_IMAGE_SOURCE_DIR BG_IMAGE_FILENAME BG_IMAGE_DEST_DIR
export BG_IMAGE_SOURCE BG_IMAGE_DEST
export DESKTOP_FONT DESKTOP_BG_COLOR DESKTOP_FG_COLOR DESKTOP_SHADOW_COLOR
export LOG_TO_CONSOLE_DEFAULT LOG_TO_FILE_DEFAULT
export NETWORK_TIMEOUT PING_COUNT APT_RETRY_MAX_ATTEMPTS APT_RETRY_DELAY
export DISPLAY_DELAY_STARTUP DISPLAY_DELAY_BETWEEN_STEPS
export FAN_TEMP_MIN FAN_TEMP_ACTIVATE FAN_TEMP_MAX
export MQTT_USER MQTT_PASS MQTT_PORT MQTT_WEBSOCKET_PORT
export STARTUP_DELAY_MOSQUITTO STARTUP_DELAY_NGINX STARTUP_DELAY_WIDGETS
export MQTT_IGNORED_TOPICS_STRING

# Valider la configuration
if ! validate_config; then
    echo "ATTENTION: Des erreurs de configuration ont été détectées"
fi