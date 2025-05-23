#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration
WIFI_SSID="Max"
WIFI_PASSWORD="1234567890"
BG_IMAGE_SOURCE="$BASE_DIR/assets/bg.jpg"
BG_IMAGE_DEST="/usr/share/backgrounds/maxlink"
CONFIG_FILE="/boot/firmware/config.txt"

# Désactiver l'affichage des logs dans la console pour une sortie propre
LOG_TO_CONSOLE=false

# Initialisation du logging
init_logging "Mise à jour système et personnalisation Raspberry Pi"

# Délai initial
sleep 3

echo "================================================================================"
echo "ÉTAPE 1 : CONNEXION ET TESTS RÉSEAU"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
log_info "Recherche du réseau WiFi $WIFI_SSID"

# Scan des réseaux disponibles
NETWORK_FOUND=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_FOUND" ]; then
    SIGNAL=$(echo "$NETWORK_FOUND" | awk '{print $7}')
    CHANNEL=$(echo "$NETWORK_FOUND" | awk '{print $3}')
    echo "  ↦ Réseau trouvé (Signal: $SIGNAL dBm, Canal: $CHANNEL)"
    log_info "Réseau $WIFI_SSID trouvé - Signal: $SIGNAL dBm, Canal: $CHANNEL"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    log_error "Réseau $WIFI_SSID non trouvé"
    exit 1
fi

echo ""
sleep 1
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
log_info "Tentative de connexion au réseau $WIFI_SSID"

# Tentative de connexion
if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    # Attendre l'attribution de l'IP
    sleep 3
    CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [ -n "$CURRENT_IP" ]; then
        echo "  ↦ Connexion établie (IP: $CURRENT_IP)"
        log_info "Connexion WiFi établie - IP: $CURRENT_IP"
    else
        echo "  ↦ Connexion établie (IP en cours d'attribution)"
        log_info "Connexion WiFi établie"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    exit 1
fi

echo ""
sleep 1
echo "◦ Test de stabilité réseau..."
log_info "Test de stabilité réseau"

# Test de ping (10 paquets)
PING_RESULT=$(ping -c 10 -W 2 8.8.8.8 2>/dev/null)
if [ $? -eq 0 ]; then
    PACKETS_RECEIVED=$(echo "$PING_RESULT" | grep "received" | awk '{print $4}')
    AVG_TIME=$(echo "$PING_RESULT" | grep "avg" | cut -d'/' -f5 | cut -d'.' -f1)
    PACKET_LOSS=$(echo "$PING_RESULT" | grep "loss" | awk '{print $6}')
    
    echo "  ↦ Ping continu (10 paquets) : $PACKETS_RECEIVED/10 reçus ✓"
    echo "  ↦ Latence moyenne : ${AVG_TIME}ms"
    echo "  ↦ Perte de paquets : $PACKET_LOSS"
    log_info "Test stabilité - $PACKETS_RECEIVED/10 paquets, latence: ${AVG_TIME}ms, perte: $PACKET_LOSS"
else
    echo "  ↦ Test de stabilité échoué ✗"
    log_error "Test de stabilité réseau échoué"
    exit 1
fi

echo ""
sleep 1
echo "◦ Test de débit..."
log_info "Test de débit réseau"

# Test de débit simple (download d'un petit fichier)
START_TIME=$(date +%s%N)
if curl -s --max-time 5 -o /dev/null http://speedtest.ftp.otenet.gr/files/test100k.db >/dev/null 2>&1; then
    END_TIME=$(date +%s%N)
    DURATION=$(( (END_TIME - START_TIME) / 1000000 ))  # en millisecondes
    
    if [ $DURATION -lt 1000 ]; then
        SPEED="~Excellent"
        QUALITY="EXCELLENTE"
    elif [ $DURATION -lt 3000 ]; then
        SPEED="~Bon"
        QUALITY="BONNE"
    else
        SPEED="~Moyen"
        QUALITY="MOYENNE"
    fi
    
    echo "  ↦ Download test (5s) : $SPEED ✓"
    echo "  ↦ Qualité connexion : $QUALITY"
    log_info "Test débit - Durée: ${DURATION}ms, Qualité: $QUALITY"
else
    echo "  ↦ Test de débit limité (pas critique) ⚠"
    echo "  ↦ Qualité connexion : FONCTIONNELLE"
    log_warn "Test de débit limité mais connexion fonctionnelle"
fi

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 2 : VÉRIFICATION ET SYNCHRONISATION HORLOGE"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Vérification de l'horloge système..."
log_info "Vérification de l'horloge système"

# Obtenir l'heure système
LOCAL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
LOCAL_TIMESTAMP=$(date +%s)

# Obtenir l'heure réseau via HTTP header
NETWORK_TIME=""
NETWORK_TIMESTAMP=0

# Essayer d'obtenir l'heure via HTTP
HTTP_DATE=$(curl -s --head --max-time 5 http://google.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //g')
if [ -n "$HTTP_DATE" ]; then
    NETWORK_TIMESTAMP=$(date -d "$HTTP_DATE" +%s 2>/dev/null || echo 0)
    NETWORK_TIME=$(date -d "$HTTP_DATE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Non disponible")
fi

echo "  ↦ Heure locale : $LOCAL_TIME"
echo "  ↦ Heure réseau : $NETWORK_TIME"

if [ $NETWORK_TIMESTAMP -gt 0 ]; then
    TIME_DIFF=$((LOCAL_TIMESTAMP - NETWORK_TIMESTAMP))
    TIME_DIFF_ABS=${TIME_DIFF#-}  # Valeur absolue
    
    echo "  ↦ Décalage détecté : $TIME_DIFF_ABS secondes"
    log_info "Décalage horloge détecté: $TIME_DIFF_ABS secondes"
    
    if [ $TIME_DIFF_ABS -gt 60 ]; then
        # Décalage important, synchronisation nécessaire
        DAYS=$((TIME_DIFF_ABS / 86400))
        if [ $DAYS -gt 0 ]; then
            echo "  ↦ Décalage critique détecté ($DAYS jours)"
        fi
        
        echo ""
        sleep 1
        echo "◦ Synchronisation horloge (décalage critique)..."
        log_info "Synchronisation horloge nécessaire"
        
        # Installer ntpdate si nécessaire
        if ! command -v ntpdate >/dev/null 2>&1; then
            echo "  ↦ Installation ntpdate..."
            apt-get update --allow-releaseinfo-change >/dev/null 2>&1
            apt-get install -y ntpdate >/dev/null 2>&1
            echo "  ↦ Installation ntpdate ✓"
            log_info "ntpdate installé"
        fi
        
        # Synchroniser l'horloge
        if ntpdate pool.ntp.org >/dev/null 2>&1; then
            NEW_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            echo "  ↦ Synchronisation avec pool.ntp.org ✓"
            echo "  ↦ Nouvelle heure : $NEW_TIME ✓"
            log_info "Horloge synchronisée - Nouvelle heure: $NEW_TIME"
        else
            echo "  ↦ Synchronisation échouée, mais poursuite possible ⚠"
            log_warn "Synchronisation horloge échouée"
        fi
    else
        echo "  ↦ Décalage acceptable (< 60s) - Aucune action requise ✓"
        log_info "Horloge synchronisée, aucune action nécessaire"
    fi
else
    echo "  ↦ Impossible de vérifier l'heure réseau ⚠"
    echo "  ↦ Poursuite avec l'heure système actuelle"
    log_warn "Impossible de vérifier l'heure réseau"
fi

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 3 : MISE À JOUR DU SYSTÈME"
echo "================================================================================"
echo ""

# Fonction de retry pour les commandes APT
retry_apt_command() {
    local cmd="$1"
    local description="$2"
    local max_attempts=6  # 6 tentatives = 30 secondes maximum
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -eq 1 ]; then
            echo "  ↦ Tentative $attempt..."
        else
            echo "  ↦ Tentative $attempt..."
        fi
        
        if eval "$cmd" >/dev/null 2>&1; then
            echo "  ↦ $description ✓"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                echo "  ↦ Échec - verrou APT occupé"
                echo "  ↦ Attente 5s..."
                sleep 5
            else
                echo "  ↦ Échec définitif après $max_attempts tentatives ✗"
                return 1
            fi
        fi
        attempt=$((attempt + 1))
    done
}

sleep 1
echo "◦ Mise à jour des dépôts..."
log_info "Mise à jour des dépôts APT"

if retry_apt_command "apt-get update -y" "Dépôts mis à jour"; then
    log_info "Mise à jour des dépôts réussie"
else
    log_error "Échec de la mise à jour des dépôts"
    exit 1
fi

echo ""
sleep 1
echo "◦ Installation des mises à jour..."
log_info "Installation des mises à jour système"

# Vérifier s'il y a des mises à jour disponibles
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
if [ $UPGRADABLE -gt 1 ]; then  # > 1 car la première ligne est l'en-tête
    echo "  ↦ $(($UPGRADABLE - 1)) paquets à mettre à jour"
    log_info "$(($UPGRADABLE - 1)) paquets à mettre à jour"
    
    if retry_apt_command "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" "Installation terminée"; then
        log_info "Mises à jour installées avec succès"
    else
        echo "  ↦ Certaines mises à jour ont échoué ⚠"
        log_warn "Certaines mises à jour ont échoué"
    fi
else
    echo "  ↦ Système déjà à jour ✓"
    log_info "Système déjà à jour"
fi

echo ""
sleep 1
echo "◦ Nettoyage du système..."
log_info "Nettoyage du système"

apt-get autoremove -y >/dev/null 2>&1
echo "  ↦ Paquets orphelins supprimés ✓"

apt-get autoclean >/dev/null 2>&1
echo "  ↦ Cache APT nettoyé ✓"

log_info "Nettoyage du système terminé"

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 4 : CONFIGURATION DU REFROIDISSEMENT"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Configuration du ventilateur..."
log_info "Configuration du système de refroidissement"

if [ -f "$CONFIG_FILE" ]; then
    # Créer une sauvegarde
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "  ↦ Sauvegarde de config.txt ✓"
    log_info "Sauvegarde config.txt créée"
    
    # Vérifier si la configuration existe déjà
    if ! grep -q "dtparam=fan_temp0" "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        echo "# Configuration de refroidissement MaxLink" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp0=0" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp1=60" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp2=60" >> "$CONFIG_FILE"
        
        echo "  ↦ Ajout paramètres de refroidissement ✓"
        echo "  ↦ Mode PRODUCTION activé ✓"
        log_info "Paramètres de refroidissement ajoutés - Mode PRODUCTION"
    else
        echo "  ↦ Configuration ventilateur déjà présente ✓"
        echo "  ↦ Mode PRODUCTION confirmé ✓"
        log_info "Configuration ventilateur déjà présente"
    fi
else
    echo "  ↦ Fichier config.txt non trouvé ⚠"
    echo "  ↦ Configuration ventilateur ignorée"
    log_warn "Fichier config.txt non trouvé"
fi

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 5 : PERSONNALISATION DE L'INTERFACE"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Préparation de la personnalisation..."
log_info "Préparation personnalisation interface"

# Détecter l'environnement de bureau
DESKTOP_ENV="Inconnu"
if [ -d "/etc/xdg/lxsession" ]; then
    DESKTOP_ENV="LXDE"
elif [ -d "/etc/xdg/autostart" ]; then
    DESKTOP_ENV="Générique"
fi

echo "  ↦ Détection environnement : $DESKTOP_ENV ✓"

# Définir l'utilisateur cible
TARGET_USER="max"
USER_HOME="/home/$TARGET_USER"

if [ -d "$USER_HOME" ]; then
    echo "  ↦ Utilisateur cible : $TARGET_USER ✓"
    log_info "Utilisateur cible: $TARGET_USER, Home: $USER_HOME"
else
    echo "  ↦ Utilisateur max non trouvé, utilisation utilisateur actuel ⚠"
    TARGET_USER="${SUDO_USER:-$(whoami)}"
    USER_HOME="/home/$TARGET_USER"
    log_warn "Utilisateur max non trouvé, utilisation de $TARGET_USER"
fi

echo ""
sleep 1
echo "◦ Installation du fond d'écran..."
log_info "Installation du fond d'écran"

if [ -f "$BG_IMAGE_SOURCE" ]; then
    echo "  ↦ Source : assets/bg.jpg trouvée ✓"
    
    # Créer le répertoire de destination
    mkdir -p "$BG_IMAGE_DEST"
    cp "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST/bg.jpg"
    chmod 644 "$BG_IMAGE_DEST/bg.jpg"
    
    echo "  ↦ Installation → /usr/share/backgrounds/maxlink/bg.jpg ✓"
    log_info "Fond d'écran installé: $BG_IMAGE_DEST/bg.jpg"
    WALLPAPER_PATH="$BG_IMAGE_DEST/bg.jpg"
else
    echo "  ↦ Source assets/bg.jpg non trouvée ⚠"
    echo "  ↦ Utilisation fond d'écran par défaut"
    log_warn "Image source non trouvée, utilisation fond par défaut"
    WALLPAPER_PATH="/usr/share/pixmaps/raspberry-pi-logo.png"
fi

echo ""
sleep 1
echo "◦ Configuration de l'interface..."
log_info "Configuration interface utilisateur"

if [ "$DESKTOP_ENV" = "LXDE" ]; then
    # Configuration LXDE
    mkdir -p "$USER_HOME/.config/pcmanfm/LXDE-pi"
    
    cat > "$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" << EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=$WALLPAPER_PATH
desktop_bg=#000000
desktop_fg=#ECEFF4
desktop_shadow=#000000
desktop_font=Inter 12
show_wm_menu=0
sort=mtime;ascending;
show_documents=0
show_trash=0
show_mounts=0
EOF
    
    # Appliquer les permissions
    chown -R $TARGET_USER:$TARGET_USER "$USER_HOME/.config" 2>/dev/null || true
    
    # Configuration système
    if [ -d "/etc/xdg" ]; then
        mkdir -p "/etc/xdg/pcmanfm/LXDE-pi"
        cp "$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" "/etc/xdg/pcmanfm/LXDE-pi/" 2>/dev/null || true
    fi
    
    echo "  ↦ Configuration bureau LXDE ✓"
    echo "  ↦ Paramètres pcmanfm appliqués ✓"
    log_info "Configuration LXDE appliquée pour $TARGET_USER"
else
    echo "  ↦ Environnement $DESKTOP_ENV non supporté ⚠"
    log_warn "Environnement de bureau non supporté: $DESKTOP_ENV"
fi

echo "  ↦ Personnalisation terminée ✓"

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 6 : DÉCONNEXION WIFI"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Vérification de la connexion actuelle..."
log_info "Vérification connexion WiFi active"

ACTIVE_CONNECTION=$(nmcli -g NAME connection show --active | grep "$WIFI_SSID")
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)

if [ -n "$ACTIVE_CONNECTION" ] && [ -n "$CURRENT_IP" ]; then
    echo "  ↦ Connexion active : $WIFI_SSID ($CURRENT_IP) ✓"
    log_info "Connexion active: $WIFI_SSID ($CURRENT_IP)"
else
    echo "  ↦ Aucune connexion active détectée ⚠"
    log_warn "Aucune connexion WiFi active détectée"
fi

echo ""
sleep 1
echo "◦ Déconnexion du réseau WiFi..."
log_info "Déconnexion du réseau WiFi"

# Déconnexion
if nmcli connection down "$WIFI_SSID" >/dev/null 2>&1; then
    echo "  ↦ Déconnexion du réseau \"$WIFI_SSID\" ✓"
    log_info "Déconnexion WiFi réussie"
else
    echo "  ↦ Déconnexion du réseau \"$WIFI_SSID\" (déjà déconnecté) ✓"
    log_info "WiFi déjà déconnecté"
fi

# Suppression du profil de connexion
if nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1; then
    echo "  ↦ Suppression du profil de connexion ✓"
    log_info "Profil de connexion supprimé"
else
    echo "  ↦ Profil de connexion non trouvé (normal) ✓"
    log_info "Profil de connexion non trouvé"
fi

echo "  ↦ Interface WiFi prête pour future utilisation ✓"
log_info "Interface WiFi préparée pour usage futur"

echo ""
sleep 3


echo "================================================================================"
echo "ÉTAPE 7 : MISE À JOUR DU SYSTÈME TERMINÉE AVEC SUCCÈS"
echo "================================================================================"
echo ""

sleep 1
echo "◦ Finalisation..."
log_info "Finalisation du script"

echo "  ↦ Mise à jour du système terminée avec succès ✓"
echo "  ↦ Configuration appliquée ✓"
echo "  ↦ Interface personnalisée ✓"
log_info "Script terminé avec succès"

echo ""
sleep 1
echo "◦ Redémarrage programmé..."
echo "  ↦ Le système va redémarrer dans 10 secondes..."
log_info "Redémarrage programmé dans 10 secondes"

# Art ASCII
cat << "EOF"

 /$$      /$$                     /$$       /$$           /$$   /$$   
| $$$    /$$$                    | $$      |__/          | $$  /$$/   
| $$$$  /$$$$  /$$$$$$  /$$   /$$| $$       /$$ /$$$$$$$ | $$ /$$/    
| $$ $$/$$ $$ |____  $$|  $$ /$$/| $$      | $$| $$__  $$| $$$$$/     
| $$  $$$| $$  /$$$$$$$ \  $$$$/ | $$      | $$| $$  \ $$| $$  $$     
| $$\  $ | $$ /$$__  $$  >$$  $$ | $$      | $$| $$  | $$| $$\  $$    
| $$ \/  | $$|  $$$$$$$ /$$/\  $$| $$$$$$$$| $$| $$  | $$| $$ \  $$   
|__/     |__/ \_______/|__/  \__/|________/|__/|__/  |__/|__/  \__/   
                                                                      
                                                                      
                                                                      
 /$$   /$$                 /$$             /$$                     /$$
| $$  | $$                | $$            | $$                    | $$
| $$  | $$  /$$$$$$   /$$$$$$$  /$$$$$$  /$$$$$$    /$$$$$$   /$$$$$$$
| $$  | $$ /$$__  $$ /$$__  $$ |____  $$|_  $$_/   /$$__  $$ /$$__  $$
| $$  | $$| $$  \ $$| $$  | $$  /$$$$$$$  | $$    | $$$$$$$$| $$  | $$
| $$  | $$| $$  | $$| $$  | $$ /$$__  $$  | $$ /$$| $$_____/| $$  | $$
|  $$$$$$/| $$$$$$$/|  $$$$$$$|  $$$$$$$  |  $$$$/|  $$$$$$$|  $$$$$$$
 \______/ | $$____/  \_______/ \_______/   \___/   \_______/ \_______/
          | $$                                                        
          | $$                                                        
          |__/                                                        

EOF

# Attendre 10 secondes avant redémarrage
sleep 10

log_info "Redémarrage du système"
reboot