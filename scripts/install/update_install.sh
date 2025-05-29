#!/bin/bash

# ===============================================================================
# MAXLINK - SCRIPT DE MISE À JOUR SYSTÈME V5 OPTIMISÉ
# Version simplifiée sans popups, sans vérifications inutiles
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables et du logging unifié
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging - catégorie "install"
init_logging "Mise à jour système MaxLink" "install"

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
    
    # Si Python3-PIL est disponible, l'utiliser, sinon copier simplement
    if python3 -c "import PIL" >/dev/null 2>&1; then
        # Script Python inline pour ajouter la version
        python3 << EOF
import sys
from PIL import Image, ImageDraw, ImageFont

try:
    img = Image.open("$source_image")
    draw = ImageDraw.Draw(img)
    
    # Position en bas à droite
    margin = 50
    x = img.width - margin - 100
    y = img.height - margin - 50
    
    # Utiliser la police par défaut
    font = ImageFont.load_default()
    
    # Dessiner l'ombre
    draw.text((x + 2, y + 2), "$version_text", font=font, fill=(0, 0, 0, 128))
    # Dessiner le texte
    draw.text((x, y), "$version_text", font=font, fill=(255, 255, 255, 255))
    
    img.save("$dest_image")
    print("Version ajoutée")
except Exception as e:
    # En cas d'erreur, copier simplement
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

log_info "========== DÉBUT DE LA MISE À JOUR SYSTÈME =========="

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi

# ===============================================================================
# ÉTAPE 1 : PRÉPARATION ET CONNEXION WIFI
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

# Vérifier et désactiver le mode AP si actif
if nmcli con show --active | grep -q "$AP_SSID"; then
    echo ""
    echo "◦ Mode point d'accès détecté..."
    AP_WAS_ACTIVE=true
    log_info "Mode AP actif détecté - désactivation temporaire"
    log_command "nmcli con down '$AP_SSID' >/dev/null 2>&1" "Désactivation AP"
    wait_silently 2
    echo "  ↦ Mode AP désactivé temporairement ✓"
fi

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
# ÉTAPE 2 : CONNEXION AU RÉSEAU
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : CONNEXION RÉSEAU"
echo "========================================================================"
echo ""

send_progress 15 "Connexion au réseau..."

# Connexion directe au réseau configuré (pas de scan inutile)
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
log_info "Tentative de connexion à $WIFI_SSID"

# Supprimer l'ancienne connexion si elle existe
log_command "nmcli connection delete '$WIFI_SSID' 2>/dev/null || true" "Suppression ancienne connexion"

# Se connecter directement
if log_command "nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASSWORD' >/dev/null 2>&1" "Connexion WiFi"; then
    echo "  ↦ Connexion initiée ✓"
    echo "  ↦ Obtention de l'adresse IP..."
    wait_silently 5
    
    IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
        echo "  ↦ Connexion établie (IP: $IP) ✓"
        log_success "Connexion établie - IP: $IP"
    else
        echo "  ↦ Connexion établie mais pas d'IP ⚠"
        log_warn "Pas d'IP obtenue"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    
    # Réactiver l'AP si nécessaire et sortir
    if [ "$AP_WAS_ACTIVE" = true ]; then
        nmcli con up "$AP_SSID" >/dev/null 2>&1
    fi
    exit 1
fi

# Test de connectivité
echo ""
echo "◦ Test de connectivité..."
echo "  ↦ Vérification de la connexion Internet..."
wait_silently 2

if log_command "ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1" "Test connectivité"; then
    echo "  ↦ Connectivité Internet confirmée ✓"
    log_success "Connectivité Internet OK"
else
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet"
    
    # Déconnexion et réactivation AP si nécessaire
    nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
    nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
    if [ "$AP_WAS_ACTIVE" = true ]; then
        nmcli con up "$AP_SSID" >/dev/null 2>&1
    fi
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
    wait_silently 3
    echo "  ↦ Horloge synchronisée ✓"
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

# Vérifier l'intégrité du système de paquets
echo ""
echo "◦ Vérification de l'intégrité du système de paquets..."
if ! dpkg --configure -a >/dev/null 2>&1; then
    echo "  ↦ Réparation des paquets en cours..."
    log_warn "Problèmes de dépendances détectés"
    log_command "apt-get install -f -y" "Réparation automatique"
else
    echo "  ↦ Système de paquets intact ✓"
    log_info "Système de paquets OK"
fi

# Mise à jour des dépôts
echo ""
echo "◦ Mise à jour de la liste des paquets..."
if log_command "apt-get update -y" "APT update"; then
    echo "  ↦ Liste des paquets mise à jour ✓"
else
    echo "  ↦ Erreur lors de la mise à jour ✗"
    log_error "Échec apt-get update"
fi

send_progress 60 "Installation des mises à jour critiques..."

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

# Nettoyage
echo ""
echo "◦ Nettoyage du système..."
log_command "apt-get autoremove -y >/dev/null 2>&1" "APT autoremove"
log_command "apt-get autoclean >/dev/null 2>&1" "APT autoclean"
echo "  ↦ Système nettoyé ✓"

send_progress 75 "Mises à jour terminées"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 5 : CONFIGURATION DU SYSTÈME
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 5 : CONFIGURATION DU SYSTÈME"
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
# ÉTAPE 6 : FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 95 "Finalisation..."

# Déconnexion WiFi
echo "◦ Déconnexion du réseau WiFi..."
log_command "nmcli connection down '$WIFI_SSID' >/dev/null 2>&1" "Déconnexion WiFi"
wait_silently 2
log_command "nmcli connection delete '$WIFI_SSID' >/dev/null 2>&1" "Suppression profil WiFi"
echo "  ↦ WiFi déconnecté ✓"

# Réactiver le mode AP si nécessaire
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    log_info "Réactivation du mode AP"
    log_command "nmcli con up '$AP_SSID' >/dev/null 2>&1 || true" "Activation AP"
    wait_silently 3
    echo "  ↦ Mode AP réactivé ✓"
fi

send_progress 100 "Mise à jour terminée !"

echo ""
echo "◦ Mise à jour terminée avec succès !"
echo "  ↦ Version: v$MAXLINK_VERSION"
log_success "Mise à jour système terminée - Version: v$MAXLINK_VERSION"

echo ""
echo "  ↦ Redémarrage dans 10 secondes..."
echo ""

log_info "Redémarrage du système prévu dans 10 secondes"

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
log_info "Redémarrage du système"
reboot