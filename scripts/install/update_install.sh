#!/bin/bash

# ===============================================================================
# MAXLINK - SCRIPT DE MISE À JOUR SYSTÈME V7 AVEC CACHE COMPLET
# Version utilisant le système de cache centralisé
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des modules
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"
source "$SCRIPT_DIR/../common/packages.sh"
source "$SCRIPT_DIR/../common/wifi_helper.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging
init_logging "Mise à jour système MaxLink avec cache complet" "install"

# Variables pour le contrôle du processus
AP_WAS_ACTIVE=false

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
    log_info "Progression: $1% - $2" false
}

# Attente simple
wait_silently() {
    sleep "$1"
}

# Ajouter la version sur l'image de fond
add_version_to_image() {
    local source_image=$1
    local dest_image=$2
    local version_text="v$MAXLINK_VERSION"
    
    log_info "Ajout de la version $version_text sur l'image de fond"
    
    if python3 -c "import PIL" >/dev/null 2>&1; then
        python3 << EOF
import sys
from PIL import Image, ImageDraw, ImageFont

try:
    img = Image.open("$source_image")
    draw = ImageDraw.Draw(img)
    
    margin = 50
    x = img.width - margin - 100
    y = img.height - margin - 50
    
    font = ImageFont.load_default()
    
    draw.text((x + 2, y + 2), "$version_text", font=font, fill=(0, 0, 0, 128))
    draw.text((x, y), "$version_text", font=font, fill=(255, 255, 255, 255))
    
    img.save("$dest_image")
    print("Version ajoutée")
except Exception as e:
    import shutil
    shutil.copy2("$source_image", "$dest_image")
    print(f"Copie simple: {e}")
EOF
        if [ $? -eq 0 ]; then
            log_success "Version ajoutée sur l'image"
        else
            cp "$source_image" "$dest_image"
            log_info "Image copiée sans version"
        fi
    else
        cp "$source_image" "$dest_image"
        log_info "PIL non disponible - copie simple de l'image"
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE LA MISE À JOUR SYSTÈME V7 =========="

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi

# ===============================================================================
# ÉTAPE 1 : PRÉPARATION DU SYSTÈME
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 5 "Préparation du système..."

# Stabilisation initiale
echo "◦ Stabilisation du système après démarrage..."
echo "  ↦ Initialisation des services réseau..."
log_info "Stabilisation du système - attente 5s"
wait_silently 5

# Sauvegarder l'état réseau actuel
save_network_state

# Vérifier l'interface WiFi
echo ""
echo "◦ Vérification de l'interface WiFi..."
if ip link show wlan0 >/dev/null 2>&1; then
    echo "  ↦ Interface WiFi détectée ✓"
    log_info "Interface WiFi wlan0 détectée"
    log_command "nmcli radio wifi on >/dev/null 2>&1" "Activation WiFi"
    wait_silently 2
    echo "  ↦ WiFi activé ✓"
else
    echo "  ↦ Interface WiFi non disponible ✗"
    log_error "Interface WiFi non disponible"
    exit 1
fi

send_progress 10 "WiFi préparé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 2 : CONNEXION INITIALE
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : CONNEXION RÉSEAU"
echo "========================================================================"
echo ""

send_progress 15 "Connexion au réseau..."

# Établir la connexion internet
if ! ensure_internet_connection; then
    echo "  ↦ Impossible d'établir la connexion ✗"
    log_error "Échec de la connexion réseau"
    exit 1
fi

send_progress 30 "Connexion établie"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 3 : SYNCHRONISATION DE L'HORLOGE
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 3 : SYNCHRONISATION HORLOGE"
echo "========================================================================"
echo ""

send_progress 35 "Synchronisation de l'horloge..."

echo "◦ Synchronisation de l'horloge système..."
log_info "Synchronisation NTP"

if command -v timedatectl >/dev/null 2>&1; then
    log_command "timedatectl set-ntp true" "Activation NTP"
    
    echo "  ↦ Attente de la synchronisation NTP..."
    log_info "Stabilisation pour synchronisation NTP - attente 10s"
    wait_silently 10
    
    if timedatectl status | grep -q "synchronized: yes"; then
        echo "  ↦ Horloge synchronisée ✓"
        log_success "Synchronisation NTP confirmée"
    else
        echo "  ↦ Synchronisation en cours... ⚠"
        log_warn "Synchronisation NTP toujours en cours"
        wait_silently 5
    fi
    
    echo "  ↦ Date/Heure: $(date '+%d/%m/%Y %H:%M:%S')"
    log_info "Heure synchronisée: $(date)"
else
    echo "  ↦ timedatectl non disponible ⚠"
    log_warn "timedatectl non disponible"
fi

send_progress 40 "Horloge synchronisée"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 4 : MISE À JOUR DE SÉCURITÉ
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 4 : MISE À JOUR DE SÉCURITÉ"
echo "========================================================================"
echo ""

send_progress 45 "Préparation des mises à jour..."

# Nettoyer les verrous APT
echo "◦ Préparation du système de paquets..."
log_info "Nettoyage des verrous APT"

log_command "pkill -9 apt 2>/dev/null || true" "Kill processus APT"
log_command "pkill -9 dpkg 2>/dev/null || true" "Kill processus DPKG"
log_command "rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*" "Suppression verrous"

wait_silently 2

# Mise à jour des dépôts
echo ""
echo "◦ Mise à jour de la liste des paquets..."
if log_command "apt-get update -y" "APT update"; then
    echo "  ↦ Liste des paquets mise à jour ✓"
else
    echo "  ↦ Erreur lors de la mise à jour ✗"
    log_error "Échec apt-get update"
fi

send_progress 55 "Installation des mises à jour critiques..."

# Installation des mises à jour de sécurité critiques uniquement
echo ""
echo "◦ Installation des mises à jour de sécurité critiques..."
log_info "Installation des paquets critiques uniquement"

# Liste des paquets critiques
CRITICAL_PACKAGES="openssh-server openssh-client openssl libssl* sudo systemd apt dpkg libc6 libpam* ca-certificates tzdata"

# Installer uniquement les mises à jour critiques
if log_command "DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $CRITICAL_PACKAGES" "Mise à jour sécurité"; then
    echo "  ↦ Mises à jour de sécurité installées ✓"
    log_success "Mises à jour de sécurité installées"
else
    echo "  ↦ Erreur lors des mises à jour ⚠"
    log_warn "Certaines mises à jour ont échoué"
fi

send_progress 65 "Création du cache de paquets..."

# ===============================================================================
# ÉTAPE 5 : CRÉATION DU CACHE COMPLET
# ===============================================================================

echo ""
echo "========================================================================"
echo "ÉTAPE 5 : CRÉATION DU CACHE DE PAQUETS"
echo "========================================================================"
echo ""

echo "◦ Initialisation du système de cache..."
log_info "Initialisation du cache de paquets"

# Initialiser le cache
if init_package_cache; then
    echo "  ↦ Cache initialisé ✓"
    log_success "Cache initialisé avec succès"
else
    echo "  ↦ Erreur d'initialisation du cache ✗"
    log_error "Échec de l'initialisation du cache"
fi

# Télécharger tous les paquets définis dans packages.list
echo ""
echo "◦ Téléchargement de tous les paquets MaxLink..."
echo "  ↦ Cette opération peut prendre quelques minutes..."

if download_all_packages; then
    echo ""
    echo "  ↦ Cache de paquets créé avec succès ✓"
    log_success "Tous les paquets ont été téléchargés"
    
    # Afficher les statistiques
    get_cache_stats
else
    echo ""
    echo "  ↦ Certains paquets n'ont pas pu être téléchargés ⚠"
    log_warn "Cache créé partiellement"
fi

# TÉLÉCHARGEMENT DU DASHBOARD
echo ""
echo "◦ Téléchargement du dashboard MaxLink..."
DASHBOARD_CACHE_DIR="/var/cache/maxlink/dashboard"
DASHBOARD_ARCHIVE="$DASHBOARD_CACHE_DIR/dashboard.tar.gz"

# Créer le répertoire de cache pour le dashboard
mkdir -p "$DASHBOARD_CACHE_DIR"

echo "  ↦ Téléchargement depuis GitHub..."
log_info "Téléchargement du dashboard depuis GitHub"

# Supprimer l'ancienne archive si elle existe
rm -f "$DASHBOARD_ARCHIVE"

# Construire l'URL de téléchargement
GITHUB_ARCHIVE_URL="${GITHUB_REPO_URL}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

# Télécharger avec curl ou wget
if command -v curl >/dev/null 2>&1; then
    if log_command "curl -L -o '$DASHBOARD_ARCHIVE' '$GITHUB_ARCHIVE_URL'" "Téléchargement dashboard (curl)"; then
        echo "  ↦ Dashboard téléchargé ✓"
        log_success "Dashboard téléchargé avec curl"
    else
        echo "  ↦ Erreur lors du téléchargement ✗"
        log_error "Échec du téléchargement du dashboard"
    fi
elif command -v wget >/dev/null 2>&1; then
    if log_command "wget -O '$DASHBOARD_ARCHIVE' '$GITHUB_ARCHIVE_URL'" "Téléchargement dashboard (wget)"; then
        echo "  ↦ Dashboard téléchargé ✓"
        log_success "Dashboard téléchargé avec wget"
    else
        echo "  ↦ Erreur lors du téléchargement ✗"
        log_error "Échec du téléchargement du dashboard"
    fi
else
    echo "  ↦ Ni curl ni wget disponibles ✗"
    log_error "Aucun outil de téléchargement disponible"
fi

# Vérifier que l'archive est valide
if [ -f "$DASHBOARD_ARCHIVE" ] && tar -tzf "$DASHBOARD_ARCHIVE" >/dev/null 2>&1; then
    echo "  ↦ Archive dashboard valide ✓"
    log_success "Archive dashboard valide"
    
    # Créer aussi les métadonnées pour le dashboard
    cat > "$DASHBOARD_CACHE_DIR/metadata.json" << EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "version": "$MAXLINK_VERSION",
    "branch": "$GITHUB_BRANCH",
    "url": "$GITHUB_ARCHIVE_URL"
}
EOF
else
    echo "  ↦ Archive dashboard corrompue ✗"
    log_error "Archive dashboard corrompue"
    rm -f "$DASHBOARD_ARCHIVE"
fi

# Nettoyage APT
echo ""
echo "◦ Nettoyage du système..."
log_command "apt-get autoremove -y >/dev/null 2>&1" "APT autoremove"
log_command "apt-get autoclean >/dev/null 2>&1" "APT autoclean"
echo "  ↦ Système nettoyé ✓"

send_progress 75 "Cache créé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 6 : CONFIGURATION DU SYSTÈME
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : CONFIGURATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 80 "Configuration du système..."

# Configuration du refroidissement
echo "◦ Configuration du ventilateur..."
log_info "Configuration du ventilateur"

if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q "dtparam=fan_temp0" "$CONFIG_FILE"; then
        {
            echo ""
            echo "# Configuration ventilateur MaxLink"
            echo "dtparam=fan_temp0=$FAN_TEMP_MIN"
            echo "dtparam=fan_temp1=$FAN_TEMP_ACTIVATE"
            echo "dtparam=fan_temp2=$FAN_TEMP_MAX"
        } >> "$CONFIG_FILE"
        echo "  ↦ Configuration ajoutée ✓"
        log_success "Configuration ventilateur ajoutée"
    else
        echo "  ↦ Configuration existante ✓"
        log_info "Configuration ventilateur déjà présente"
    fi
else
    echo "  ↦ Fichier config.txt non trouvé ⚠"
    log_warn "Fichier $CONFIG_FILE non trouvé"
fi

# Personnalisation de l'interface
echo ""
echo "◦ Personnalisation de l'interface..."
log_info "Installation du fond d'écran personnalisé"

# Créer le répertoire des fonds d'écran
mkdir -p "$BG_IMAGE_DEST_DIR"

# Copier le fond d'écran avec ajout de version
if [ -f "$BG_IMAGE_SOURCE" ]; then
    add_version_to_image "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST"
    echo "  ↦ Fond d'écran installé ✓"
else
    echo "  ↦ Fond d'écran source non trouvé ⚠"
    log_warn "Fond d'écran source non trouvé: $BG_IMAGE_SOURCE"
fi

# Configuration bureau LXDE
if [ -d "$EFFECTIVE_USER_HOME/.config" ]; then
    mkdir -p "$EFFECTIVE_USER_HOME/.config/pcmanfm/LXDE-pi"
    
    cat > "$EFFECTIVE_USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" << EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=$BG_IMAGE_DEST
desktop_bg=$DESKTOP_BG_COLOR
desktop_fg=$DESKTOP_FG_COLOR
desktop_shadow=$DESKTOP_SHADOW_COLOR
desktop_font=$DESKTOP_FONT
show_wm_menu=0
show_documents=0
show_trash=0
show_mounts=0
EOF
    
    chown -R $EFFECTIVE_USER:$EFFECTIVE_USER "$EFFECTIVE_USER_HOME/.config"
    echo "  ↦ Bureau configuré ✓"
    log_success "Configuration bureau LXDE appliquée"
fi

send_progress 90 "Configuration terminée"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 7 : FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 7 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 95 "Finalisation..."

# Restaurer l'état réseau
echo "◦ Restauration de l'état réseau..."
restore_network_state
echo "  ↦ État réseau restauré ✓"

send_progress 100 "Mise à jour terminée !"

echo ""
echo "◦ Mise à jour terminée avec succès !"
echo "  ↦ Version: v$MAXLINK_VERSION"
echo "  ↦ Système à jour et configuré"
echo "  ↦ Cache de paquets créé pour installation offline"
log_success "Mise à jour système terminée - Version: v$MAXLINK_VERSION"

# Afficher le résumé du cache
echo ""
echo "◦ Résumé du cache créé :"
get_cache_stats

echo ""
echo "  ↦ Redémarrage dans 10 secondes..."
echo ""

log_info "Redémarrage du système prévu dans 10 secondes"

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
log_info "Redémarrage du système"
reboot