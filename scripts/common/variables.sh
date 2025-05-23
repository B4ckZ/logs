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
MAXLINK_VERSION="2.0"
MAXLINK_BUILD="Build 2025.01"
MAXLINK_COPYRIGHT="© 2025 WERIT. Tous droits réservés."
MAXLINK_WINDOW_TITLE="MaxLink™ Admin Panel V${MAXLINK_VERSION} - ${MAXLINK_COPYRIGHT} - Usage non autorisé strictement interdit."

# Informations de l'organisation
MAXLINK_COMPANY="WERIT"
MAXLINK_PROJECT_NAME="MaxLink"

# ===============================================================================
# CONFIGURATION UTILISATEUR SYSTÈME
# ===============================================================================

# Utilisateur principal du Raspberry Pi
# IMPORTANT: Changez cette valeur si votre utilisateur n'est pas "max"
SYSTEM_USER="max"
SYSTEM_USER_HOME="/home/$SYSTEM_USER"

# Utilisateur de fallback (sera utilisé si SYSTEM_USER n'existe pas)
# Laissez vide pour utiliser l'utilisateur sudo actuel
FALLBACK_USER=""

# ===============================================================================
# CONFIGURATION RÉSEAU WIFI
# ===============================================================================

# Réseau WiFi pour les mises à jour et tests
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
    "nginx:NginX Web:inactive"
    "mqtt:MQTT BKR:inactive"
)

# ===============================================================================
# CONFIGURATION DU LOGGING
# ===============================================================================

# Configuration des logs
LOG_TO_CONSOLE_DEFAULT=false
LOG_TO_FILE_DEFAULT=true
LOG_MAX_SIZE_MB=10

# ===============================================================================
# CONFIGURATION RÉSEAU ET SÉCURITÉ
# ===============================================================================

# Timeouts réseau (en secondes)
NETWORK_TIMEOUT=5
PING_COUNT=10
CONNECTIVITY_TEST_PACKETS=4

# Retry pour les commandes APT
APT_RETRY_MAX_ATTEMPTS=6
APT_RETRY_DELAY=5

# ===============================================================================
# CONFIGURATION AVANCÉE
# ===============================================================================

# Délais d'affichage pour l'interface (en secondes)
DISPLAY_DELAY_STARTUP=3
DISPLAY_DELAY_BETWEEN_STEPS=3
DISPLAY_DELAY_BETWEEN_ACTIONS=1

# Configuration ventilateur
FAN_TEMP_MIN=0
FAN_TEMP_ACTIVATE=60
FAN_TEMP_MAX=60

# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Fonction pour obtenir l'utilisateur système effectif
get_effective_user() {
    local target_user="$SYSTEM_USER"
    
    # Vérifier si l'utilisateur principal existe
    if [ -d "$SYSTEM_USER_HOME" ]; then
        echo "$SYSTEM_USER"
        return 0
    fi
    
    # Utiliser le fallback si défini
    if [ -n "$FALLBACK_USER" ] && [ -d "/home/$FALLBACK_USER" ]; then
        echo "$FALLBACK_USER"
        return 0
    fi
    
    # Utiliser l'utilisateur sudo actuel
    if [ -n "$SUDO_USER" ] && [ -d "/home/$SUDO_USER" ]; then
        echo "$SUDO_USER"
        return 0
    fi
    
    # En dernier recours, chercher le premier utilisateur non-système
    local first_user=$(ls -la /home 2>/dev/null | grep "^d" | grep -v "\.$" | head -1 | awk '{print $9}')
    if [ -n "$first_user" ] && [ "$first_user" != "root" ]; then
        echo "$first_user"
        return 0
    fi
    
    # Si rien ne fonctionne, retourner l'utilisateur par défaut
    echo "$SYSTEM_USER"
    return 1
}

# Fonction pour obtenir le répertoire home effectif
get_effective_user_home() {
    local effective_user=$(get_effective_user)
    echo "/home/$effective_user"
}

# Fonction pour construire les chemins d'assets
get_bg_image_source() {
    echo "$MAXLINK_BASE_DIR/$BG_IMAGE_SOURCE_DIR/$BG_IMAGE_FILENAME"
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
    
    # Vérifier que les variables essentielles sont définies
    if [ -z "$WIFI_SSID" ]; then
        echo "ERREUR: WIFI_SSID non défini dans variables.sh"
        errors=$((errors + 1))
    fi
    
    if [ -z "$AP_SSID" ]; then
        echo "ERREUR: AP_SSID non défini dans variables.sh"
        errors=$((errors + 1))
    fi
    
    if [ -z "$SYSTEM_USER" ]; then
        echo "ERREUR: SYSTEM_USER non défini dans variables.sh"
        errors=$((errors + 1))
    fi
    
    # Vérifier la cohérence des adresses IP
    if [[ ! "$AP_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERREUR: AP_IP ($AP_IP) n'est pas une adresse IP valide"
        errors=$((errors + 1))
    fi
    
    return $errors
}

# ===============================================================================
# VARIABLES DYNAMIQUES (NE PAS MODIFIER)
# ===============================================================================

# Ces variables sont calculées automatiquement
EFFECTIVE_USER=$(get_effective_user)
EFFECTIVE_USER_HOME=$(get_effective_user_home)
BG_IMAGE_SOURCE=$(get_bg_image_source)
BG_IMAGE_DEST=$(get_bg_image_dest)

# ===============================================================================
# EXPORT DES VARIABLES
# ===============================================================================

# Exporter toutes les variables pour qu'elles soient disponibles dans tous les scripts
export MAXLINK_VERSION MAXLINK_BUILD MAXLINK_COPYRIGHT MAXLINK_WINDOW_TITLE
export MAXLINK_COMPANY MAXLINK_PROJECT_NAME
export SYSTEM_USER SYSTEM_USER_HOME FALLBACK_USER
export EFFECTIVE_USER EFFECTIVE_USER_HOME
export WIFI_SSID WIFI_PASSWORD
export AP_SSID AP_PASSWORD AP_IP AP_NETMASK AP_DHCP_START AP_DHCP_END
export CONFIG_FILE
export BG_IMAGE_SOURCE_DIR BG_IMAGE_FILENAME BG_IMAGE_DEST_DIR
export BG_IMAGE_SOURCE BG_IMAGE_DEST
export DESKTOP_FONT DESKTOP_BG_COLOR DESKTOP_FG_COLOR DESKTOP_SHADOW_COLOR
export LOG_TO_CONSOLE_DEFAULT LOG_TO_FILE_DEFAULT LOG_MAX_SIZE_MB
export NETWORK_TIMEOUT PING_COUNT CONNECTIVITY_TEST_PACKETS
export APT_RETRY_MAX_ATTEMPTS APT_RETRY_DELAY
export DISPLAY_DELAY_STARTUP DISPLAY_DELAY_BETWEEN_STEPS DISPLAY_DELAY_BETWEEN_ACTIONS
export FAN_TEMP_MIN FAN_TEMP_ACTIVATE FAN_TEMP_MAX