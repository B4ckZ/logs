#!/bin/bash

# ===============================================================================
# MAXLINK - SCRIPT DE MISE À JOUR SYSTÈME V4 LIGHT
# Version allégée sans ImageMagick lourd
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables centralisées
source "$SCRIPT_DIR/../common/variables.sh"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Fichier de log
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/update_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"

# Fichier pour la décision utilisateur
USER_CHOICE_FILE="/tmp/maxlink_update_choice"

# Temps de pause entre les étapes (en secondes)
PAUSE_COURT=2
PAUSE_MOYEN=5
PAUSE_LONG=10

# Variables de progression
PROGRESS_CURRENT=0

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Logger une information
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Logger et afficher
log_and_show() {
    local message=$1
    echo "$message"
    log "INFO" "$message"
}

# Logger une commande et son résultat
log_command() {
    local cmd=$1
    local desc=$2
    
    log "CMD" "Exécution: $cmd"
    
    # Exécuter la commande et capturer la sortie
    local output
    local exit_code
    
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    
    # Logger la sortie complète
    if [ -n "$output" ]; then
        echo "$output" | while IFS= read -r line; do
            log "OUT" "$line"
        done
    fi
    
    log "CMD" "Code de sortie: $exit_code"
    
    return $exit_code
}

# ===============================================================================
# NOUVELLE FONCTION : AJOUTER VERSION SUR IMAGE AVEC PYTHON
# ===============================================================================

add_version_to_image() {
    local source_image=$1
    local dest_image=$2
    local version_text="v$MAXLINK_VERSION"
    
    # Script Python pour ajouter la version
    cat > /tmp/add_version.py << 'EOF'
#!/usr/bin/env python3
import sys
import os

try:
    from PIL import Image, ImageDraw, ImageFont
    
    # Arguments
    source_path = sys.argv[1]
    dest_path = sys.argv[2]
    version_text = sys.argv[3]
    
    # Ouvrir l'image
    img = Image.open(source_path)
    draw = ImageDraw.Draw(img)
    
    # Position (coin inférieur droit)
    margin = 50
    x = img.width - margin
    y = img.height - margin
    
    # Essayer différentes tailles de police
    font_size = 60
    font = None
    
    # Essayer de charger une police système
    font_paths = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"
    ]
    
    for font_path in font_paths:
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except:
                pass
    
    # Si aucune police trouvée, utiliser la police par défaut
    if font is None:
        font = ImageFont.load_default()
    
    # Calculer la taille du texte
    bbox = draw.textbbox((0, 0), version_text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    
    # Position ajustée
    x = img.width - text_width - margin
    y = img.height - text_height - margin
    
    # Dessiner l'ombre
    shadow_offset = 3
    draw.text((x + shadow_offset, y + shadow_offset), version_text, 
              font=font, fill=(0, 0, 0, 128))
    
    # Dessiner le texte
    draw.text((x, y), version_text, font=font, fill=(255, 255, 255, 255))
    
    # Sauvegarder
    img.save(dest_path)
    print("Version ajoutée avec succès")
    
except ImportError:
    # Si PIL n'est pas disponible, copier simplement
    import shutil
    shutil.copy2(sys.argv[1], sys.argv[2])
    print("PIL non disponible, copie simple effectuée")
except Exception as e:
    print(f"Erreur: {e}")
    # En cas d'erreur, copier simplement
    import shutil
    shutil.copy2(sys.argv[1], sys.argv[2])
EOF

    # Exécuter le script Python
    if python3 /tmp/add_version.py "$source_image" "$dest_image" "$version_text" >/dev/null 2>&1; then
        rm -f /tmp/add_version.py
        return 0
    else
        # En cas d'échec, copier simplement
        cp "$source_image" "$dest_image"
        rm -f /tmp/add_version.py
        return 1
    fi
}

# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Afficher la progression pour l'interface Python
send_progress() {
    local value=$1
    local text=$2
    echo "PROGRESS:$value:$text"
}

# Pause avec message simple
pause_system() {
    local seconds=$1
    local message=$2
    [ -n "$message" ] && log_and_show "  ↦ $message..."
    sleep $seconds
}

# Vérifier si on est en mode AP
is_ap_mode() {
    nmcli con show --active | grep -q "$AP_SSID" && return 0 || return 1
}

# Désactiver le mode AP temporairement
disable_ap_mode() {
    if is_ap_mode; then
        log_and_show "  ↦ Désactivation du mode point d'accès..."
        log_command "nmcli con down '$AP_SSID'" "Désactivation AP"
        pause_system $PAUSE_COURT
        return 0
    fi
    return 1
}

# Attendre la décision utilisateur depuis l'interface
wait_for_user_choice() {
    local timeout=${1:-60}
    local count=0
    
    # Effacer l'ancien fichier
    rm -f "$USER_CHOICE_FILE"
    
    # Attendre que le fichier apparaisse
    while [ ! -f "$USER_CHOICE_FILE" ] && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    if [ -f "$USER_CHOICE_FILE" ]; then
        local choice=$(cat "$USER_CHOICE_FILE")
        rm -f "$USER_CHOICE_FILE"
        [ "$choice" = "yes" ] && return 0 || return 1
    else
        # Timeout - considérer comme "non"
        return 1
    fi
}

# ===============================================================================
# FONCTION DE RÉPARATION DES DÉPENDANCES
# ===============================================================================

repair_dependencies() {
    log_and_show "◦ Réparation des dépendances cassées..."
    
    # Étape 1 : Forcer la configuration des paquets en attente
    log_and_show "  ↦ Configuration forcée des paquets..."
    log_command "dpkg --configure -a --force-depends" "Configuration forcée"
    
    # Étape 2 : Installer les dépendances manquantes
    log_and_show "  ↦ Installation des dépendances manquantes..."
    
    # Essayer d'installer spécifiquement les paquets Python problématiques
    log_command "apt-get install -f -y libpython3.11-stdlib=3.11.2-6+deb12u6" "Installation libpython3.11-stdlib"
    log_command "apt-get install -f -y python3.11-minimal=3.11.2-6+deb12u6" "Installation python3.11-minimal"
    
    # Étape 3 : Réparer avec apt --fix-broken
    log_and_show "  ↦ Réparation automatique des paquets cassés..."
    if log_command "DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y" "Réparation des paquets"; then
        log_and_show "  ↦ Dépendances réparées ✓"
        return 0
    else
        # Si ça ne marche pas, essayer une approche plus agressive
        log_and_show "  ↦ Tentative de réparation forcée..."
        
        # Forcer la suppression des paquets problématiques
        log_command "dpkg --remove --force-remove-reinstreq python3.11 python3.11-dev python3.11-venv libpython3.11 libpython3.11-dev" "Suppression forcée"
        
        # Nettoyer
        log_command "apt-get autoremove -y" "Nettoyage"
        
        # Réinstaller proprement
        log_command "apt-get update" "Mise à jour des dépôts"
        log_command "apt-get install -y python3.11" "Réinstallation Python"
        
        # Vérifier si c'est réparé
        if dpkg -l | grep -E "^[^i].*python3\.11" >/dev/null 2>&1; then
            log_and_show "  ↦ Certains problèmes persistent ⚠"
            return 1
        else
            log_and_show "  ↦ Dépendances réparées après suppression/réinstallation ✓"
            return 0
        fi
    fi
}

# ===============================================================================
# ÉTAPES PRINCIPALES
# ===============================================================================

# ÉTAPE 1 : Préparation et vérification WiFi
step_prepare_wifi() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 5 "Préparation du système..."
    
    # Informations système pour debug
    log "INFO" "=== INFORMATIONS SYSTÈME ==="
    log "INFO" "Date/Heure: $(date)"
    log "INFO" "Utilisateur: $(whoami)"
    log "INFO" "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    log "INFO" "Kernel: $(uname -r)"
    log "INFO" "Architecture: $(uname -m)"
    log "INFO" "=========================="
    
    # Stabilisation initiale
    log_and_show "◦ Stabilisation du système après démarrage..."
    pause_system $PAUSE_MOYEN "Initialisation des services"
    
    # Vérifier et désactiver le mode AP si actif
    local AP_WAS_ACTIVE=false
    if is_ap_mode; then
        echo ""
        log_and_show "◦ Mode point d'accès détecté..."
        AP_WAS_ACTIVE=true
        disable_ap_mode
        log_and_show "  ↦ Mode AP désactivé temporairement ✓"
    fi
    
    # Vérifier l'interface WiFi
    echo ""
    log_and_show "◦ Vérification de l'interface WiFi..."
    
    # Logger l'état des interfaces réseau
    log "INFO" "=== INTERFACES RÉSEAU ==="
    log_command "ip link show" "Liste des interfaces"
    log_command "rfkill list" "État rfkill"
    log "INFO" "========================"
    
    if ip link show wlan0 >/dev/null 2>&1; then
        log_and_show "  ↦ Interface WiFi détectée ✓"
        
        # Activer le WiFi
        log_command "nmcli radio wifi on" "Activation WiFi"
        pause_system $PAUSE_COURT "Activation radio WiFi"
        log_and_show "  ↦ WiFi activé ✓"
    else
        log_and_show "  ↦ Interface WiFi non disponible ✗"
        log "ERROR" "Interface wlan0 non trouvée"
        exit 1
    fi
    
    send_progress 10 "WiFi préparé"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 2 : Connexion au réseau
step_connect_wifi() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 2 : CONNEXION RÉSEAU"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 15 "Recherche du réseau..."
    
    # Scan et recherche du réseau
    log_and_show "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
    log_and_show "  ↦ Scan des réseaux disponibles..."
    
    log_command "nmcli device wifi rescan" "Scan WiFi"
    pause_system $PAUSE_MOYEN
    
    # Logger tous les réseaux trouvés
    log "INFO" "=== RÉSEAUX DISPONIBLES ==="
    log_command "nmcli device wifi list" "Liste des réseaux"
    log "INFO" "=========================="
    
    # Vérifier la présence du réseau
    NETWORK_INFO=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
    if [ -n "$NETWORK_INFO" ]; then
        SIGNAL=$(echo "$NETWORK_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
        log_and_show "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A} dBm) ✓"
        log "INFO" "Réseau trouvé avec signal: ${SIGNAL:-N/A}"
    else
        log_and_show "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
        log "ERROR" "Réseau $WIFI_SSID non trouvé"
        exit 1
    fi
    
    send_progress 20 "Connexion en cours..."
    
    # Connexion au réseau
    echo ""
    log_and_show "◦ Connexion au réseau \"$WIFI_SSID\"..."
    
    # Supprimer l'ancienne connexion si elle existe
    log_command "nmcli connection delete '$WIFI_SSID' 2>/dev/null || true" "Suppression ancienne connexion"
    
    # Se connecter
    if log_command "nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASSWORD'" "Connexion WiFi"; then
        log_and_show "  ↦ Connexion initiée ✓"
        pause_system $PAUSE_MOYEN "Obtention de l'adresse IP"
        
        # Récupérer l'IP
        IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$IP" ]; then
            log_and_show "  ↦ Connexion établie (IP: $IP) ✓"
            log "INFO" "IP obtenue: $IP"
        else
            log_and_show "  ↦ Connexion établie mais pas d'IP ⚠"
            log "WARN" "Pas d'IP obtenue"
        fi
    else
        log_and_show "  ↦ Échec de la connexion ✗"
        log "ERROR" "Échec de la connexion WiFi"
        exit 1
    fi
    
    # Test de connectivité
    echo ""
    log_and_show "◦ Test de connectivité..."
    pause_system $PAUSE_COURT "Stabilisation de la connexion"
    
    if log_command "ping -c 3 -W 2 8.8.8.8" "Test ping Google DNS"; then
        log_and_show "  ↦ Connectivité Internet confirmée ✓"
    else
        log_and_show "  ↦ Pas de connectivité Internet ✗"
        log "ERROR" "Pas de connectivité Internet"
        exit 1
    fi
    
    send_progress 30 "Connexion établie"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 3 : Synchronisation de l'horloge
step_sync_time() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 3 : SYNCHRONISATION HORLOGE"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 35 "Synchronisation de l'horloge..."
    
    log_and_show "◦ Synchronisation de l'horloge système..."
    
    log "INFO" "Heure avant sync: $(date)"
    
    if command -v timedatectl >/dev/null 2>&1; then
        log_command "timedatectl set-ntp true" "Activation NTP"
        pause_system $PAUSE_MOYEN "Synchronisation NTP"
        log_and_show "  ↦ Horloge synchronisée ✓"
        log_and_show "  ↦ Date/Heure: $(date '+%d/%m/%Y %H:%M:%S')"
        log "INFO" "Heure après sync: $(date)"
    else
        log_and_show "  ↦ timedatectl non disponible ⚠"
        log "WARN" "timedatectl non disponible"
    fi
    
    send_progress 40 "Horloge synchronisée"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 4 : Mise à jour du système (sécurité uniquement)
step_system_update() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 4 : MISE À JOUR DE SÉCURITÉ"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 45 "Vérification des mises à jour..."
    
    # Nettoyer les verrous APT
    log_and_show "◦ Préparation du système de paquets..."
    
    log "INFO" "=== NETTOYAGE APT ==="
    log_command "pkill -9 apt 2>/dev/null || true" "Kill processus APT"
    log_command "pkill -9 dpkg 2>/dev/null || true" "Kill processus DPKG"
    log_command "rm -f /var/lib/apt/lists/lock" "Suppression lock lists"
    log_command "rm -f /var/cache/apt/archives/lock" "Suppression lock archives"
    log_command "rm -f /var/lib/dpkg/lock*" "Suppression lock dpkg"
    log "INFO" "==================="
    
    # Vérifier s'il y a des problèmes de dépendances
    echo ""
    log_and_show "◦ Vérification de l'intégrité du système de paquets..."
    
    if ! dpkg --configure -a >/dev/null 2>&1; then
        log_and_show "  ↦ Problèmes de dépendances détectés"
        repair_dependencies
    else
        log_and_show "  ↦ Système de paquets intact ✓"
    fi
    
    pause_system $PAUSE_COURT
    
    # Mise à jour des dépôts
    echo ""
    log_and_show "◦ Mise à jour de la liste des paquets..."
    
    if log_command "apt-get update -y" "APT update"; then
        log_and_show "  ↦ Liste des paquets mise à jour ✓"
    else
        log_and_show "  ↦ Erreur lors de la mise à jour ✗"
        log "ERROR" "Échec apt-get update"
        exit 1
    fi
    
    send_progress 50 "Installation des mises à jour de sécurité..."
    
    echo ""
    log_and_show "◦ Installation des mises à jour de sécurité critiques..."
    
    # NOUVELLE APPROCHE : Installer uniquement les paquets critiques
    # Liste des paquets essentiels à maintenir à jour
    CRITICAL_PACKAGES=(
        "openssh-server"
        "openssh-client"
        "openssl"
        "libssl*"
        "sudo"
        "passwd"
        "login"
        "systemd"
        "apt"
        "dpkg"
        "libc6"
        "libpam*"
        "ca-certificates"
        "tzdata"
    )
    
    # Créer une liste des paquets critiques installés
    PACKAGES_TO_UPDATE=""
    for pkg in "${CRITICAL_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg"; then
            PACKAGES_TO_UPDATE="$PACKAGES_TO_UPDATE $pkg"
        fi
    done
    
    if [ -n "$PACKAGES_TO_UPDATE" ]; then
        log_and_show "  ↦ Mise à jour des paquets critiques uniquement"
        log "INFO" "Paquets critiques: $PACKAGES_TO_UPDATE"
        
        # Installer uniquement les mises à jour critiques
        if log_command "DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $PACKAGES_TO_UPDATE" "Mise à jour sécurité"; then
            log_and_show "  ↦ Mises à jour de sécurité installées ✓"
        else
            log_and_show "  ↦ Erreur lors des mises à jour de sécurité ⚠"
        fi
    else
        log_and_show "  ↦ Aucun paquet critique à mettre à jour ✓"
    fi
    
    # Optionnel : Afficher le nombre total de mises à jour disponibles (sans les installer)
    echo ""
    log_and_show "◦ Information sur les autres mises à jour..."
    TOTAL_UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
    if [ $TOTAL_UPDATES -gt 0 ]; then
        log_and_show "  ↦ $TOTAL_UPDATES mises à jour disponibles au total (non installées)"
        log_and_show "  ↦ Seules les mises à jour de sécurité ont été appliquées"
    else
        log_and_show "  ↦ Système entièrement à jour ✓"
    fi
    
    send_progress 65 "Mises à jour de sécurité terminées"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 5 : Installation de Python3-PIL (au lieu d'ImageMagick)
step_install_image_tools() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 5 : INSTALLATION DES OUTILS D'IMAGE"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 70 "Installation des outils d'image..."
    
    log_and_show "◦ Vérification de Python PIL/Pillow..."
    
    # Vérifier si PIL est déjà installé
    if python3 -c "import PIL" >/dev/null 2>&1; then
        log_and_show "  ↦ Python PIL/Pillow déjà installé ✓"
        log "INFO" "PIL/Pillow déjà présent"
    else
        log_and_show "  ↦ Python PIL/Pillow non installé"
        echo ""
        log_and_show "◦ Installation de Python3-PIL..."
        
        # Installer python3-pil (beaucoup plus léger qu'ImageMagick)
        if log_command "apt-get install -y python3-pil" "Installation python3-pil"; then
            log_and_show "  ↦ Python3-PIL installé ✓"
            log "INFO" "Python3-PIL installé avec succès"
        else
            log_and_show "  ↦ Erreur lors de l'installation ⚠"
            log "ERROR" "Échec installation Python3-PIL"
        fi
    fi
    
    # Nettoyage
    echo ""
    log_and_show "◦ Nettoyage du système..."
    log_command "apt-get autoremove -y" "APT autoremove"
    log_command "apt-get autoclean" "APT autoclean"
    log_and_show "  ↦ Système nettoyé ✓"
    
    send_progress 75 "Outils d'image installés"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 6 : Configuration du système
step_configure_system() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 6 : CONFIGURATION DU SYSTÈME"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 80 "Configuration du système..."
    
    # Configuration du refroidissement
    log_and_show "◦ Configuration du ventilateur..."
    
    if [ -f "$CONFIG_FILE" ]; then
        if ! grep -q "dtparam=fan_temp0" "$CONFIG_FILE"; then
            {
                echo ""
                echo "# Configuration ventilateur MaxLink"
                echo "dtparam=fan_temp0=$FAN_TEMP_MIN"
                echo "dtparam=fan_temp1=$FAN_TEMP_ACTIVATE"
                echo "dtparam=fan_temp2=$FAN_TEMP_MAX"
            } >> "$CONFIG_FILE"
            log_and_show "  ↦ Configuration ajoutée ✓"
            log "INFO" "Configuration ventilateur ajoutée"
        else
            log_and_show "  ↦ Configuration existante ✓"
            log "INFO" "Configuration ventilateur déjà présente"
        fi
    else
        log_and_show "  ↦ Fichier config.txt non trouvé ⚠"
        log "WARN" "Fichier $CONFIG_FILE non trouvé"
    fi
    
    # Personnalisation de l'interface
    echo ""
    log_and_show "◦ Personnalisation de l'interface..."
    
    # Créer le répertoire des fonds d'écran
    mkdir -p "$BG_IMAGE_DEST_DIR"
    
    # Copier le fond d'écran avec ajout de version
    if [ -f "$BG_IMAGE_SOURCE" ]; then
        # Utiliser la fonction Python pour ajouter la version
        if add_version_to_image "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST" ; then
            log_and_show "  ↦ Fond d'écran installé avec version ✓"
            log "INFO" "Fond d'écran installé avec version v$MAXLINK_VERSION"
        else
            log_and_show "  ↦ Fond d'écran installé (sans version) ✓"
            log "INFO" "Fond d'écran copié sans version"
        fi
    else
        log_and_show "  ↦ Fond d'écran non trouvé ⚠"
        log "WARN" "Fond d'écran source non trouvé: $BG_IMAGE_SOURCE"
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
        log_and_show "  ↦ Bureau configuré ✓"
        log "INFO" "Configuration bureau LXDE appliquée"
    fi
    
    send_progress 90 "Configuration terminée"
    echo ""
    sleep $PAUSE_COURT
}

# ÉTAPE 7 : Finalisation
step_finalize() {
    log_and_show "========================================================================"
    log_and_show "ÉTAPE 7 : FINALISATION"
    log_and_show "========================================================================"
    echo ""
    
    send_progress 95 "Finalisation..."
    
    # Déconnexion WiFi
    log_and_show "◦ Déconnexion du réseau WiFi..."
    log_command "nmcli connection down '$WIFI_SSID'" "Déconnexion WiFi"
    pause_system $PAUSE_COURT
    log_command "nmcli connection delete '$WIFI_SSID'" "Suppression profil WiFi"
    log_and_show "  ↦ WiFi déconnecté ✓"
    
    send_progress 100 "Mise à jour terminée !"
    
    echo ""
    log_and_show "◦ Mise à jour terminée avec succès !"
    log_and_show "  ↦ Version: v$MAXLINK_VERSION"
    log_and_show "  ↦ Redémarrage en cours..."
    echo ""
    
    log "INFO" "Script terminé avec succès"
    log "INFO" "Fichier de log: $LOG_FILE"
    
    # Pause de 3 secondes avant reboot
    sleep 3
    
    # Redémarrer
    reboot
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    exit 1
fi

# Initialiser le log
log "INFO" "=========================================="
log "INFO" "DÉBUT DU SCRIPT UPDATE_INSTALL V4 LIGHT"
log "INFO" "=========================================="
log "INFO" "Version: $MAXLINK_VERSION"
log "INFO" "Utilisateur: $(whoami)"
log "INFO" "PWD: $(pwd)"
log "INFO" "Script: $0"
log "INFO" "=========================================="

# Message initial
echo ""
echo "Démarrage du script de mise à jour MaxLink (version allégée)..."
echo "Les logs détaillés sont disponibles dans :"
echo "$LOG_FILE"
echo ""

# Enregistrer si le mode AP était actif
export AP_WAS_ACTIVE=false

# Exécuter les étapes
step_prepare_wifi
step_connect_wifi
step_sync_time
step_system_update
step_install_image_tools  # Au lieu de step_install_imagemagick
step_configure_system
step_finalize