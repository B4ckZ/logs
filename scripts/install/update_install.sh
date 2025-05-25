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

# Fonction pour attendre avec message
wait_with_message() {
    local seconds=$1
    local message=$2
    echo "  ↦ $message (attente ${seconds}s)..."
    sleep $seconds
}

# ===============================================================================
# DÉBUT DU SCRIPT PRINCIPAL
# ===============================================================================

# Désactiver l'affichage des logs dans la console pour une sortie propre
LOG_TO_CONSOLE=false

# Initialisation du logging
init_logging "Mise à jour système et personnalisation Raspberry Pi"

# NOUVEAU : Attente initiale plus longue pour stabiliser le système
echo "◦ Stabilisation du système après démarrage..."
wait_with_message 5 "Initialisation des services réseau"

send_progress 0 "Initialisation..."

echo "========================================================================"
echo "ÉTAPE 1 : CONNEXION ET TESTS RÉSEAU"
echo "========================================================================"
echo ""

# NOUVEAU : Vérifier que l'interface WiFi est prête
echo "◦ Vérification de l'interface WiFi..."
send_progress 2 "Vérification de l'interface WiFi..."

# Attendre que l'interface WiFi soit disponible
WIFI_READY=false
for i in {1..10}; do
    if ip link show wlan0 >/dev/null 2>&1; then
        WIFI_READY=true
        echo "  ↦ Interface WiFi détectée ✓"
        break
    fi
    echo "  ↦ Tentative $i/10 - Interface WiFi non prête"
    sleep 2
done

if [ "$WIFI_READY" = false ]; then
    echo "  ↦ Interface WiFi non disponible ✗"
    log_error "Interface WiFi non disponible après 20 secondes"
    exit 1
fi

# NOUVEAU : Activer l'interface WiFi si nécessaire
echo ""
echo "◦ Activation de l'interface WiFi..."
nmcli radio wifi on >/dev/null 2>&1
wait_with_message 3 "Activation radio WiFi"

echo ""
echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
send_progress 5 "Recherche du réseau WiFi..."

# NOUVEAU : Forcer un scan des réseaux et attendre
echo "  ↦ Scan des réseaux disponibles..."
nmcli device wifi rescan >/dev/null 2>&1 || true
wait_with_message 5 "Scan en cours"

# Tentatives multiples pour trouver le réseau
NETWORK_FOUND=""
for attempt in {1..3}; do
    NETWORK_FOUND=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
    if [ -n "$NETWORK_FOUND" ]; then
        break
    fi
    echo "  ↦ Tentative $attempt/3 - Réseau non trouvé, nouveau scan..."
    nmcli device wifi rescan >/dev/null 2>&1 || true
    wait_with_message 3 "Nouveau scan"
done

if [ -n "$NETWORK_FOUND" ]; then
    # Extraire le signal correctement (peut être à différentes positions)
    SIGNAL=$(echo "$NETWORK_FOUND" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    echo "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A}) ✓"
    log_info "Réseau $WIFI_SSID trouvé - Signal: ${SIGNAL:-N/A}"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    log_error "Réseau $WIFI_SSID non trouvé après 3 tentatives"
    exit 1
fi

send_progress 10 "Connexion au réseau WiFi..."
echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."

# NOUVEAU : Supprimer toute connexion existante avant de reconnecter
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1 || true
wait_with_message 2 "Nettoyage des connexions existantes"

# Tentative de connexion avec timeout plus long
if timeout 30 nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    echo "  ↦ Connexion initiée ✓"
    wait_with_message 5 "Obtention de l'adresse IP"
    
    # Vérifier l'obtention de l'IP
    CURRENT_IP=""
    for i in {1..10}; do
        CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$CURRENT_IP" ]; then
            break
        fi
        sleep 1
    done
    
    if [ -n "$CURRENT_IP" ]; then
        echo "  ↦ Connexion établie (IP: $CURRENT_IP) ✓"
        log_info "Connexion WiFi établie - IP: $CURRENT_IP"
    else
        echo "  ↦ Connexion établie mais IP non attribuée ⚠"
        log_warn "Connexion WiFi établie mais pas d'IP"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    exit 1
fi

send_progress 15 "Test de connectivité..."
echo ""
echo "◦ Test de connectivité..."

# NOUVEAU : Attendre avant le test de connectivité
wait_with_message 3 "Stabilisation de la connexion"

# Test de connectivité avec plusieurs tentatives
CONNECTIVITY_OK=false
for attempt in {1..5}; do
    if ping -c $PING_COUNT -W 2 8.8.8.8 >/dev/null 2>&1; then
        CONNECTIVITY_OK=true
        echo "  ↦ Connectivité Internet confirmée ✓"
        log_info "Connectivité Internet OK"
        break
    fi
    echo "  ↦ Tentative $attempt/5 - Pas de connectivité"
    sleep 2
done

if [ "$CONNECTIVITY_OK" = false ]; then
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet après 5 tentatives"
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
    wait_with_message 5 "Synchronisation NTP"
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

# NOUVEAU : Libérer les verrous APT avant de commencer
echo "◦ Préparation du système de paquets..."
send_progress 32 "Préparation APT..."

# Tuer les processus APT bloquants
pkill -9 apt >/dev/null 2>&1 || true
pkill -9 dpkg >/dev/null 2>&1 || true

# Supprimer les verrous
rm -f /var/lib/apt/lists/lock >/dev/null 2>&1 || true
rm -f /var/cache/apt/archives/lock >/dev/null 2>&1 || true
rm -f /var/lib/dpkg/lock* >/dev/null 2>&1 || true

# Reconfigurer dpkg si nécessaire
dpkg --configure -a >/dev/null 2>&1 || true

wait_with_message 3 "Nettoyage des verrous APT"

# Vérifier l'espace disque
echo ""
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

# Fonction de retry améliorée pour APT
retry_apt() {
    local cmd="$1"
    local desc="$2"
    local attempt=1
    
    while [ $attempt -le $APT_RETRY_MAX_ATTEMPTS ]; do
        echo "  ↦ Tentative $attempt/$APT_RETRY_MAX_ATTEMPTS..."
        
        # Nettoyer les verrous avant chaque tentative
        rm -f /var/lib/apt/lists/lock >/dev/null 2>&1 || true
        rm -f /var/cache/apt/archives/lock >/dev/null 2>&1 || true
        
        if timeout 180 bash -c "$cmd" >/dev/null 2>&1; then
            echo "  ↦ $desc ✓"
            return 0
        fi
        
        if [ $attempt -lt $APT_RETRY_MAX_ATTEMPTS ]; then
            wait_with_message 5 "Attente avant nouvelle tentative"
        fi
        ((attempt++))
    done
    
    echo "  ↦ $desc ✗"
    return 1
}

send_progress 40 "Mise à jour des dépôts..."
echo ""
echo "◦ Mise à jour des dépôts..."

# NOUVEAU : Attendre que le service APT soit prêt
wait_with_message 5 "Attente service APT"

retry_apt "apt-get update -y --allow-releaseinfo-change" "Dépôts mis à jour" || {
    echo "  ⚠ Échec de la mise à jour des dépôts, tentative avec fix-missing..."
    retry_apt "apt-get update -y --fix-missing" "Dépôts mis à jour (fix-missing)" || exit 1
}

send_progress 50 "Installation des mises à jour..."
echo ""
echo "◦ Installation des mises à jour..."

# Vérifier les mises à jour disponibles
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "1")
if [ $UPGRADABLE -gt 1 ]; then
    echo "  ↦ $(($UPGRADABLE - 1)) paquet(s) à mettre à jour"
    wait_with_message 3 "Préparation des mises à jour"
    retry_apt "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" "Mises à jour installées"
else
    echo "  ↦ Système déjà à jour ✓"
fi

# Installation d'ImageMagick si nécessaire
if ! command -v convert >/dev/null 2>&1; then
    send_progress 55 "Installation d'ImageMagick..."
    echo ""
    echo "◦ Installation d'ImageMagick..."
    wait_with_message 3 "Préparation installation ImageMagick"
    
    # Installer ImageMagick avec toutes ses dépendances
    retry_apt "apt-get install -y imagemagick imagemagick-6-common" "ImageMagick installé" || {
        echo "  ⚠ Installation standard échouée, essai avec --fix-broken..."
        retry_apt "apt-get install -y --fix-broken imagemagick" "ImageMagick installé (fix-broken)"
    }
    
    # Vérifier l'installation
    wait_with_message 2 "Vérification de l'installation"
    if command -v convert >/dev/null 2>&1; then
        echo "  ↦ ImageMagick installé et fonctionnel ✓"
        log_info "ImageMagick installé avec succès"
    else
        echo "  ↦ ImageMagick installé mais commande convert non trouvée ⚠"
        log_warn "Installation ImageMagick incomplète"
    fi
fi

send_progress 60 "Nettoyage du système..."
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

# NOUVEAU : Vérifier les chemins et créer l'image
VERSION_TEXT="v${MAXLINK_VERSION}"

# Debug des chemins
echo "  ↦ Source: $BG_IMAGE_SOURCE"
echo "  ↦ Destination: $BG_IMAGE_DEST"

# Vérifier que le répertoire source existe
if [ ! -f "$BG_IMAGE_SOURCE" ]; then
    echo "  ↦ Image source non trouvée, création d'une image par défaut..."
    
    # Créer le répertoire assets s'il n'existe pas
    mkdir -p "$(dirname "$BG_IMAGE_SOURCE")"
    
    # Créer une image par défaut avec ImageMagick si disponible
    if command -v convert >/dev/null 2>&1; then
        convert -size 1920x1080 gradient:"#2E3440"-"#3B4252" \
                -gravity center -pointsize 100 -fill "#81A1C1" \
                -annotate +0-100 "MaxLink™" \
                -gravity SouthEast -pointsize 60 -fill white \
                -stroke black -strokewidth 2 \
                -annotate +50+50 "$VERSION_TEXT" \
                "$BG_IMAGE_DEST"
        echo "  ↦ Image de fond créée avec version $VERSION_TEXT ✓"
        log_info "Image de fond créée par défaut avec version"
    else
        echo "  ↦ Impossible de créer l'image (ImageMagick non disponible) ✗"
        log_error "Impossible de créer l'image de fond"
    fi
elif command -v convert >/dev/null 2>&1; then
    # Ajouter la version sur l'image existante
    echo "  ↦ Ajout de la version sur l'image..."
    convert "$BG_IMAGE_SOURCE" \
        -gravity SouthEast \
        -pointsize 60 \
        -fill white \
        -stroke black \
        -strokewidth 2 \
        -annotate +50+50 "$VERSION_TEXT" \
        "$BG_IMAGE_DEST"
    
    # Vérifier que l'image a été créée
    if [ -f "$BG_IMAGE_DEST" ]; then
        echo "  ↦ Fond d'écran installé avec version $VERSION_TEXT ✓"
        log_info "Fond d'écran installé avec version $VERSION_TEXT"
    else
        echo "  ↦ Erreur lors de la création de l'image ✗"
        log_error "Erreur lors de la création de l'image avec version"
    fi
else
    # Copie simple si ImageMagick non disponible
    cp "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST"
    echo "  ↦ Fond d'écran copié (sans version) ⚠"
    log_warn "Fond d'écran copié sans version (ImageMagick non disponible)"
fi

# Configuration LXDE si présent
if [ -d "/etc/xdg/lxsession" ] && [ -d "$USER_HOME" ]; then
    echo ""
    echo "◦ Configuration du bureau..."
    
    wait_with_message 2 "Préparation de la configuration bureau"
    
    mkdir -p "$USER_HOME/.config/pcmanfm/LXDE-pi"
    
    # S'assurer que l'image de destination existe pour la configuration
    WALLPAPER_PATH="$BG_IMAGE_DEST"
    if [ ! -f "$WALLPAPER_PATH" ]; then
        WALLPAPER_PATH="/usr/share/pixmaps/raspberry-pi-logo.png"
        echo "  ↦ Image personnalisée non trouvée, utilisation image par défaut ⚠"
    fi
    
    cat > "$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" << EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=$WALLPAPER_PATH
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
wait_with_message 2 "Déconnexion en cours"

nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
echo "  ↦ WiFi déconnecté ✓"
log_info "WiFi déconnecté et profil supprimé"

send_progress 100 "Mise à jour terminée !"

echo ""
echo "◦ Mise à jour terminée avec succès !"
echo "  ↦ Version: $VERSION_TEXT"
echo "  ↦ Redémarrage dans 10 secondes..."

log_info "Script terminé avec succès - Redémarrage programmé"

# Compte à rebours visuel plus long
for i in {10..1}; do
    printf "\r  ↦ Redémarrage dans %2d secondes... " $i
    sleep 1
done
printf "\r  ↦ Redémarrage en cours...          \n"

# NOUVEAU : Petit délai avant le reboot pour s'assurer que les logs sont écrits
sleep 2

reboot