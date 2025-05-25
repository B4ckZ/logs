#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Source des variables centralisées
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/variables.sh"

# ===============================================================================
# FONCTIONS DE PROGRESSION SIMPLIFIÉES
# ===============================================================================

# Variable pour tracker la progression globale
PROGRESS_CURRENT=0
PROGRESS_TOTAL=100

# Fonction pour envoyer la progression à l'interface Python
send_progress() {
    local value=$1
    local text=$2
    echo "PROGRESS:$value:$text"
}

# Fonction pour convertir MB en GB avec 1 décimale
mb_to_gb() {
    local mb=$1
    echo "scale=1; $mb / 1024" | bc 2>/dev/null || awk "BEGIN {printf \"%.1f\", $mb/1024}"
}

# ===============================================================================
# DÉBUT DU SCRIPT PRINCIPAL
# ===============================================================================

# Désactiver l'affichage des logs dans la console pour une sortie propre
LOG_TO_CONSOLE=false

# Initialisation du logging
init_logging "Mise à jour système et personnalisation Raspberry Pi"

# Délai initial
sleep $DISPLAY_DELAY_STARTUP

send_progress 0 "Initialisation..."

echo "========================================================================"
echo "ÉTAPE 1 : CONNEXION ET TESTS RÉSEAU"
echo "========================================================================"
echo ""

echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
send_progress 5 "Recherche du réseau WiFi..."

# Scan des réseaux disponibles
NETWORK_FOUND=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_FOUND" ]; then
    SIGNAL=$(echo "$NETWORK_FOUND" | awk '{print $7}')
    echo "  ↦ Réseau trouvé (Signal: $SIGNAL dBm) ✓"
    log_info "Réseau $WIFI_SSID trouvé - Signal: $SIGNAL dBm"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    log_error "Réseau $WIFI_SSID non trouvé"
    exit 1
fi

send_progress 10 "Connexion au réseau WiFi..."
echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."

# Tentative de connexion
if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    sleep 2
    CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    echo "  ↦ Connexion établie${CURRENT_IP:+ (IP: $CURRENT_IP)} ✓"
    log_info "Connexion WiFi établie${CURRENT_IP:+ - IP: $CURRENT_IP}"
else
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    exit 1
fi

send_progress 15 "Test de connectivité..."
echo ""
echo "◦ Test de connectivité..."

# Test de connectivité
if ping -c $PING_COUNT -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "  ↦ Connectivité Internet confirmée ✓"
    log_info "Connectivité Internet OK"
else
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet"
    exit 1
fi

send_progress 20 "Réseau configuré"
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 2 : SYNCHRONISATION HORLOGE"
echo "========================================================================"
echo ""

echo "◦ Vérification de l'horloge système..."
send_progress 25 "Synchronisation de l'horloge..."
log_info "Vérification de l'horloge système"

# Synchronisation avec timedatectl
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1
    sleep 2
    echo "  ↦ Horloge synchronisée ✓"
    log_info "Horloge synchronisée via timedatectl"
else
    echo "  ↦ Synchronisation non disponible ⚠"
    log_warn "timedatectl non disponible"
fi

send_progress 30 "Horloge synchronisée"
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 3 : MISE À JOUR DU SYSTÈME"
echo "========================================================================"
echo ""

# Vérifier l'espace disque
echo "◦ Vérification de l'espace disque..."
send_progress 35 "Vérification de l'espace disque..."

AVAILABLE_SPACE_MB=$(df -BM / | tail -1 | awk '{print $4}' | sed 's/M//')
AVAILABLE_SPACE_GB=$(mb_to_gb $AVAILABLE_SPACE_MB)

if [ $AVAILABLE_SPACE_MB -lt 500 ]; then
    echo "  ↦ Espace insuffisant (${AVAILABLE_SPACE_GB} Go disponible) ✗"
    log_error "Espace disque insuffisant: ${AVAILABLE_SPACE_GB} Go"
    exit 1
fi
echo "  ↦ Espace disponible: ${AVAILABLE_SPACE_GB} Go ✓"

# Fonction de retry pour APT
retry_apt() {
    local cmd="$1"
    local desc="$2"
    local attempt=1
    
    while [ $attempt -le $APT_RETRY_MAX_ATTEMPTS ]; do
        if timeout 120 bash -c "$cmd" >/dev/null 2>&1; then
            echo "  ↦ $desc ✓"
            return 0
        fi
        if [ $attempt -lt $APT_RETRY_MAX_ATTEMPTS ]; then
            echo "  ↦ Tentative $attempt échouée, nouvelle tentative..."
            sleep $APT_RETRY_DELAY
        fi
        ((attempt++))
    done
    
    echo "  ↦ $desc ✗"
    return 1
}

send_progress 40 "Mise à jour des dépôts..."
echo ""
echo "◦ Mise à jour des dépôts..."
retry_apt "apt-get update -y" "Dépôts mis à jour" || exit 1

send_progress 50 "Installation des mises à jour..."
echo ""
echo "◦ Installation des mises à jour..."

# Vérifier les mises à jour disponibles
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
if [ $UPGRADABLE -gt 1 ]; then
    echo "  ↦ $(($UPGRADABLE - 1)) paquet(s) à mettre à jour"
    retry_apt "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" "Mises à jour installées"
else
    echo "  ↦ Système déjà à jour ✓"
fi

# Installation d'ImageMagick si nécessaire
if ! command -v convert >/dev/null 2>&1; then
    send_progress 55 "Installation d'ImageMagick..."
    echo ""
    echo "◦ Installation d'ImageMagick..."
    retry_apt "apt-get install -y imagemagick" "ImageMagick installé"
fi

send_progress 60 "Nettoyage du système..."
# Nettoyage
echo ""
echo "◦ Nettoyage du système..."
apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1
echo "  ↦ Système nettoyé ✓"

echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DU REFROIDISSEMENT"
echo "========================================================================"
echo ""

send_progress 70 "Configuration du ventilateur..."
echo "◦ Configuration du ventilateur..."

if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q "dtparam=fan_temp0" "$CONFIG_FILE"; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        {
            echo ""
            echo "# Configuration de refroidissement MaxLink"
            echo "dtparam=fan_temp0=${FAN_TEMP_MIN}"
            echo "dtparam=fan_temp1=${FAN_TEMP_ACTIVATE}"
            echo "dtparam=fan_temp2=${FAN_TEMP_MAX}"
        } >> "$CONFIG_FILE"
        echo "  ↦ Configuration ajoutée ✓"
        log_info "Configuration ventilateur ajoutée"
    else
        echo "  ↦ Configuration existante ✓"
    fi
else
    echo "  ↦ Fichier config.txt non trouvé ⚠"
    log_warn "Fichier config.txt non trouvé"
fi

echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 5 : PERSONNALISATION DE L'INTERFACE"
echo "========================================================================"
echo ""

send_progress 80 "Personnalisation de l'interface..."

# Déterminer l'utilisateur cible
TARGET_USER="$EFFECTIVE_USER"
USER_HOME="$EFFECTIVE_USER_HOME"

echo "◦ Installation du fond d'écran..."

# Créer le répertoire de destination
mkdir -p "$BG_IMAGE_DEST_DIR"

# Préparer le fond d'écran avec version
VERSION_TEXT="v${MAXLINK_VERSION}"

if [ -f "$BG_IMAGE_SOURCE" ] && command -v convert >/dev/null 2>&1; then
    # Ajouter la version sur l'image existante
    convert "$BG_IMAGE_SOURCE" \
        -gravity SouthEast \
        -pointsize 60 \
        -fill white \
        -stroke black \
        -strokewidth 2 \
        -annotate +50+50 "$VERSION_TEXT" \
        "$BG_IMAGE_DEST"
    echo "  ↦ Fond d'écran installé avec version $VERSION_TEXT ✓"
    log_info "Fond d'écran installé avec version $VERSION_TEXT"
else
    # Copie simple si ImageMagick non disponible
    [ -f "$BG_IMAGE_SOURCE" ] && cp "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST"
    echo "  ↦ Fond d'écran installé ✓"
fi

# Configuration LXDE si présent
if [ -d "/etc/xdg/lxsession" ] && [ -d "$USER_HOME" ]; then
    echo ""
    echo "◦ Configuration du bureau..."
    
    mkdir -p "$USER_HOME/.config/pcmanfm/LXDE-pi"
    cat > "$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" << EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=${BG_IMAGE_DEST:-/usr/share/pixmaps/raspberry-pi-logo.png}
desktop_bg=$DESKTOP_BG_COLOR
desktop_fg=$DESKTOP_FG_COLOR
desktop_shadow=$DESKTOP_SHADOW_COLOR
desktop_font=$DESKTOP_FONT
show_wm_menu=0
sort=mtime;ascending;
show_documents=0
show_trash=0
show_mounts=0
EOF
    
    chown -R $TARGET_USER:$TARGET_USER "$USER_HOME/.config" 2>/dev/null || true
    echo "  ↦ Bureau configuré ✓"
    log_info "Bureau LXDE configuré pour $TARGET_USER"
fi

send_progress 90 "Interface personnalisée"
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 6 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 95 "Finalisation..."
echo "◦ Déconnexion WiFi..."

# Déconnexion et suppression du profil
nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
echo "  ↦ WiFi déconnecté ✓"
log_info "WiFi déconnecté et profil supprimé"

send_progress 100 "Mise à jour terminée !"

echo ""
echo "◦ Mise à jour terminée avec succès !"
echo "  ↦ Version: $VERSION_TEXT"
echo "  ↦ Redémarrage dans 5 secondes..."

log_info "Script terminé avec succès - Redémarrage programmé"

# Compte à rebours visuel
for i in {5..1}; do
    printf "\r  ↦ Redémarrage dans %d secondes... " $i
    sleep 1
done
printf "\r  ↦ Redémarrage en cours...          \n"

reboot