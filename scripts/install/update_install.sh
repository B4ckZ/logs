#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Source des variables centralisées
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/variables.sh"

# ===============================================================================
# FONCTIONS DE PROGRESSION
# ===============================================================================

# Variables globales pour la progression
PROGRESS_CURRENT=0
PROGRESS_TOTAL=100
PROGRESS_START_TIME=$(date +%s)
PROGRESS_STEP_WEIGHT=()
PROGRESS_CURRENT_STEP=0

# Initialiser la progression avec les poids des étapes
init_progress() {
    # Définir le poids de chaque étape (total = 100)
    PROGRESS_STEP_WEIGHT=(
        20  # ÉTAPE 1 : Connexion réseau
        10  # ÉTAPE 2 : Synchronisation horloge
        30  # ÉTAPE 3 : Mise à jour système
        10  # ÉTAPE 4 : Configuration refroidissement
        20  # ÉTAPE 5 : Personnalisation interface
        10  # ÉTAPE 6 : Finalisation
    )
    PROGRESS_CURRENT=0
    PROGRESS_CURRENT_STEP=0
    PROGRESS_START_TIME=$(date +%s)
}

# Afficher la barre de progression (version ASCII simple)
show_progress() {
    local width=50
    local filled=$((width * PROGRESS_CURRENT / PROGRESS_TOTAL))
    local empty=$((width - filled))
    
    # Calcul du temps
    local elapsed=$(($(date +%s) - PROGRESS_START_TIME))
    local eta=0
    if [ $PROGRESS_CURRENT -gt 0 ]; then
        eta=$(((elapsed * PROGRESS_TOTAL / PROGRESS_CURRENT) - elapsed))
    fi
    
    # Formatage
    local elapsed_fmt=$(printf "%02d:%02d" $((elapsed/60)) $((elapsed%60)))
    local eta_fmt=$(printf "%02d:%02d" $((eta/60)) $((eta%60)))
    
    # Affichage sur la même ligne avec caractères ASCII simples
    printf "\r  ["
    printf "%${filled}s" | tr ' ' '='
    printf ">"
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%% | %s / ~%s restant  " $PROGRESS_CURRENT "$elapsed_fmt" "$eta_fmt"
}

# Mettre à jour la progression
update_progress() {
    local increment=${1:-1}
    PROGRESS_CURRENT=$((PROGRESS_CURRENT + increment))
    [ $PROGRESS_CURRENT -gt $PROGRESS_TOTAL ] && PROGRESS_CURRENT=$PROGRESS_TOTAL
    show_progress
}

# Commencer une nouvelle étape
start_step() {
    local step_num=$1
    if [ $step_num -le ${#PROGRESS_STEP_WEIGHT[@]} ]; then
        PROGRESS_CURRENT_STEP=$step_num
        # Calculer la progression de début de cette étape
        local progress_before=0
        for ((i=1; i<step_num; i++)); do
            progress_before=$((progress_before + PROGRESS_STEP_WEIGHT[i-1]))
        done
        PROGRESS_CURRENT=$progress_before
        show_progress
    fi
}

# Terminer l'étape courante
complete_step() {
    if [ $PROGRESS_CURRENT_STEP -gt 0 ] && [ $PROGRESS_CURRENT_STEP -le ${#PROGRESS_STEP_WEIGHT[@]} ]; then
        local step_weight=${PROGRESS_STEP_WEIGHT[$PROGRESS_CURRENT_STEP-1]}
        local target_progress=0
        for ((i=1; i<=PROGRESS_CURRENT_STEP; i++)); do
            target_progress=$((target_progress + PROGRESS_STEP_WEIGHT[i-1]))
        done
        PROGRESS_CURRENT=$target_progress
        show_progress
    fi
}

# Nettoyer la ligne de progression avant d'afficher du texte
clear_progress_line() {
    printf "\r\033[K"
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

# Initialiser la progression
init_progress

# Délai initial
sleep $DISPLAY_DELAY_STARTUP

echo "========================================================================"
echo "ÉTAPE 1 : CONNEXION ET TESTS RÉSEAU"
echo "========================================================================"
echo ""

start_step 1

echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
show_progress

# Scan des réseaux disponibles
update_progress 5
NETWORK_FOUND=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_FOUND" ]; then
    SIGNAL=$(echo "$NETWORK_FOUND" | awk '{print $7}')
    clear_progress_line
    echo "  ↦ Réseau trouvé (Signal: $SIGNAL dBm) ✓"
    log_info "Réseau $WIFI_SSID trouvé - Signal: $SIGNAL dBm"
    update_progress 5
else
    clear_progress_line
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    log_error "Réseau $WIFI_SSID non trouvé"
    exit 1
fi

echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
show_progress

# Tentative de connexion
update_progress 5
if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    update_progress 5
    sleep 2
    CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    clear_progress_line
    echo "  ↦ Connexion établie${CURRENT_IP:+ (IP: $CURRENT_IP)} ✓"
    log_info "Connexion WiFi établie${CURRENT_IP:+ - IP: $CURRENT_IP}"
else
    clear_progress_line
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    exit 1
fi

echo ""
echo "◦ Test de connectivité..."
show_progress

# Test de connectivité
update_progress 5
if ping -c $PING_COUNT -W 2 8.8.8.8 >/dev/null 2>&1; then
    clear_progress_line
    echo "  ↦ Connectivité Internet confirmée ✓"
    log_info "Connectivité Internet OK"
    update_progress 5
else
    clear_progress_line
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet"
    exit 1
fi

complete_step
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 2 : SYNCHRONISATION HORLOGE"
echo "========================================================================"
echo ""

start_step 2

echo "◦ Vérification de l'horloge système..."
show_progress

update_progress 5
log_info "Vérification de l'horloge système"

# Synchronisation avec timedatectl
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1
    sleep 2
    clear_progress_line
    echo "  ↦ Horloge synchronisée ✓"
    log_info "Horloge synchronisée via timedatectl"
    update_progress 5
else
    clear_progress_line
    echo "  ↦ Synchronisation non disponible ⚠"
    log_warn "timedatectl non disponible"
    update_progress 5
fi

complete_step
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 3 : MISE À JOUR DU SYSTÈME"
echo "========================================================================"
echo ""

start_step 3

# Vérifier l'espace disque
echo "◦ Vérification de l'espace disque..."
show_progress

update_progress 2
AVAILABLE_SPACE_MB=$(df -BM / | tail -1 | awk '{print $4}' | sed 's/M//')
AVAILABLE_SPACE_GB=$(mb_to_gb $AVAILABLE_SPACE_MB)

if [ $AVAILABLE_SPACE_MB -lt 500 ]; then
    clear_progress_line
    echo "  ↦ Espace insuffisant (${AVAILABLE_SPACE_GB} Go disponible) ✗"
    log_error "Espace disque insuffisant: ${AVAILABLE_SPACE_GB} Go"
    exit 1
fi
clear_progress_line
echo "  ↦ Espace disponible: ${AVAILABLE_SPACE_GB} Go ✓"
update_progress 3

# Fonction de retry pour APT avec progression
retry_apt_with_progress() {
    local cmd="$1"
    local desc="$2"
    local weight=$3
    local attempt=1
    
    while [ $attempt -le $APT_RETRY_MAX_ATTEMPTS ]; do
        show_progress
        if timeout 120 bash -c "$cmd" >/dev/null 2>&1; then
            clear_progress_line
            echo "  ↦ $desc ✓"
            update_progress $weight
            return 0
        fi
        if [ $attempt -lt $APT_RETRY_MAX_ATTEMPTS ]; then
            clear_progress_line
            echo "  ↦ Tentative $attempt échouée, nouvelle tentative..."
            sleep $APT_RETRY_DELAY
        fi
        ((attempt++))
    done
    
    clear_progress_line
    echo "  ↦ $desc ✗"
    return 1
}

echo ""
echo "◦ Mise à jour des dépôts..."
show_progress
retry_apt_with_progress "apt-get update -y" "Dépôts mis à jour" 10 || exit 1

echo ""
echo "◦ Installation des mises à jour..."
show_progress

# Vérifier les mises à jour disponibles
update_progress 2
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
if [ $UPGRADABLE -gt 1 ]; then
    clear_progress_line
    echo "  ↦ $(($UPGRADABLE - 1)) paquet(s) à mettre à jour"
    show_progress
    retry_apt_with_progress "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" "Mises à jour installées" 10
else
    clear_progress_line
    echo "  ↦ Système déjà à jour ✓"
    update_progress 10
fi

# Installation d'ImageMagick si nécessaire
if ! command -v convert >/dev/null 2>&1; then
    echo ""
    echo "◦ Installation d'ImageMagick..."
    show_progress
    retry_apt_with_progress "apt-get install -y imagemagick" "ImageMagick installé" 3
else
    update_progress 3
fi

# Nettoyage
echo ""
echo "◦ Nettoyage du système..."
show_progress
apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean >/dev/null 2>&1
clear_progress_line
echo "  ↦ Système nettoyé ✓"

complete_step
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DU REFROIDISSEMENT"
echo "========================================================================"
echo ""

start_step 4

echo "◦ Configuration du ventilateur..."
show_progress

update_progress 5
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
        clear_progress_line
        echo "  ↦ Configuration ajoutée ✓"
        log_info "Configuration ventilateur ajoutée"
    else
        clear_progress_line
        echo "  ↦ Configuration existante ✓"
    fi
else
    clear_progress_line
    echo "  ↦ Fichier config.txt non trouvé ⚠"
    log_warn "Fichier config.txt non trouvé"
fi

update_progress 5
complete_step
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 5 : PERSONNALISATION DE L'INTERFACE"
echo "========================================================================"
echo ""

start_step 5

# Déterminer l'utilisateur cible
TARGET_USER="$EFFECTIVE_USER"
USER_HOME="$EFFECTIVE_USER_HOME"

echo "◦ Installation du fond d'écran..."
show_progress

update_progress 5

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
    clear_progress_line
    echo "  ↦ Fond d'écran installé avec version $VERSION_TEXT ✓"
    log_info "Fond d'écran installé avec version $VERSION_TEXT"
else
    # Copie simple si ImageMagick non disponible
    [ -f "$BG_IMAGE_SOURCE" ] && cp "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST"
    clear_progress_line
    echo "  ↦ Fond d'écran installé ✓"
fi

update_progress 10

# Configuration LXDE si présent
if [ -d "/etc/xdg/lxsession" ] && [ -d "$USER_HOME" ]; then
    echo ""
    echo "◦ Configuration du bureau..."
    show_progress
    
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
    clear_progress_line
    echo "  ↦ Bureau configuré ✓"
    log_info "Bureau LXDE configuré pour $TARGET_USER"
    update_progress 5
else
    update_progress 5
fi

complete_step
echo ""
sleep $DISPLAY_DELAY_BETWEEN_STEPS

echo "========================================================================"
echo "ÉTAPE 6 : FINALISATION"
echo "========================================================================"
echo ""

start_step 6

echo "◦ Déconnexion WiFi..."
show_progress

update_progress 5

# Déconnexion et suppression du profil
nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
clear_progress_line
echo "  ↦ WiFi déconnecté ✓"
log_info "WiFi déconnecté et profil supprimé"

update_progress 5
complete_step

echo ""
echo "◦ Mise à jour terminée avec succès !"
echo "  ↦ Version: $VERSION_TEXT"
echo "  ↦ Durée totale: $(printf "%02d:%02d" $((($(date +%s) - PROGRESS_START_TIME)/60)) $((($(date +%s) - PROGRESS_START_TIME)%60)))"
echo "  ↦ Redémarrage dans 5 secondes..."

log_info "Script terminé avec succès - Redémarrage programmé"

# Compte à rebours visuel
for i in {5..1}; do
    printf "\r  ↦ Redémarrage dans %d secondes... " $i
    sleep 1
done
printf "\r  ↦ Redémarrage en cours...          \n"

reboot