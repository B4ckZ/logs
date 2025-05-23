#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration
WIFI_SSID="Max"
WIFI_PASSWORD="1234567890"
BG_IMAGE_SOURCE="$BASE_DIR/assets/bg.jpg"
BG_IMAGE_DEST="/usr/share/backgrounds/maxlink"

# Initialisation du logging
init_logging "Mise à jour système et personnalisation Raspberry Pi"

# Fonction pour personnaliser l'interface (ULTRA-SIMPLIFIÉE)
customize_desktop() {
    if [ ! -d "/etc/xdg/lxsession" ]; then
        return 1
    fi
    
    local current_user="max"
    local user_home="/home/$current_user"
    
    if [ ! -d "$user_home" ]; then
        current_user=$(ls -la /home | grep -v "^d.* \.$" | grep "^d" | head -1 | awk '{print $9}')
        user_home="/home/$current_user"
        
        if [ ! -d "$user_home" ] || [ "$current_user" = "root" ]; then
            if [ -n "$SUDO_USER" ]; then
                current_user="$SUDO_USER"
                user_home="/home/$current_user"
            fi
        fi
    fi
    
    if [ ! -d "$user_home" ]; then
        return 1
    fi
    
    # Gestion fond d'écran
    local wallpaper_path
    if [ -f "$BG_IMAGE_SOURCE" ]; then
        mkdir -p "$BG_IMAGE_DEST"
        cp -f "$BG_IMAGE_SOURCE" "$BG_IMAGE_DEST/bg.jpg" >/dev/null 2>&1
        chmod 644 "$BG_IMAGE_DEST/bg.jpg" >/dev/null 2>&1
        wallpaper_path="$BG_IMAGE_DEST/bg.jpg"
    else
        wallpaper_path="/usr/share/pixmaps/raspberry-pi-logo.png"
    fi
    
    # Configuration interface
    mkdir -p "$user_home/.config/pcmanfm/LXDE-pi"
    
    cat > "$user_home/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" << EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=$wallpaper_path
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
    
    chown -R $current_user:$current_user "$user_home/.config" >/dev/null 2>&1
    
    if [ -d "/etc/xdg" ]; then
        mkdir -p "/etc/xdg/pcmanfm/LXDE-pi"
        cp "$user_home/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" "/etc/xdg/pcmanfm/LXDE-pi/" >/dev/null 2>&1
    fi
}

# ÉTAPE 1 : VÉRIFICATIONS
echo "Vérification des privilèges..."
if [ "$EUID" -ne 0 ]; then
    echo "ERREUR: Exécuter avec sudo"
    exit 1
fi

echo "Nettoyage des verrous APT..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null
dpkg --configure -a >/dev/null 2>&1
sleep 2

# ÉTAPE 2 : CONFIGURATION VENTILATEUR
echo "Configuration du refroidissement..."
CONFIG_FILE="/boot/firmware/config.txt"
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q "dtparam=fan_temp0=0" "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        echo "# Configuration de refroidissement MaxLink" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp0=0" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp1=60" >> "$CONFIG_FILE"
        echo "dtparam=fan_temp2=60" >> "$CONFIG_FILE"
    fi
fi
sleep 2

# ÉTAPE 3 : CONNECTIVITÉ RÉSEAU
echo "Connexion WiFi ($WIFI_SSID)..."
nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" name "$WIFI_SSID" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERREUR: Connexion WiFi échouée"
        exit 1
    fi
fi

echo "Test connectivité Internet..."
sleep 5
packets_received=0
for i in {1..4}; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        packets_received=$((packets_received + 1))
    fi
    sleep 0.3
done

if [ $packets_received -eq 0 ]; then
    echo "ERREUR: Pas de connexion Internet"
    exit 1
elif [ $packets_received -lt 3 ]; then
    echo "Connexion Internet faible ($packets_received/4 paquets)"
else
    echo "Connexion Internet OK ($packets_received/4 paquets)"
fi

# ÉTAPE 4 : SYNCHRONISATION HORLOGE
echo "Vérification horloge système..."
current_date=$(date +%s)
online_date=$(curl -s --head http://google.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //g' | date -f - +%s 2>/dev/null || echo 0)

if [ "$online_date" != "0" ]; then
    date_diff=$((current_date - online_date))
    date_diff=${date_diff#-}
    
    if [ $date_diff -gt 60 ]; then
        echo "Correction horloge (décalage: ${date_diff}s)..."
        
        if ! command -v ntpdate >/dev/null; then
            apt-get update --allow-releaseinfo-change >/dev/null 2>&1
            apt-get install -y ntpdate >/dev/null 2>&1
        fi
        
        if ntpdate pool.ntp.org >/dev/null 2>&1; then
            echo "Horloge synchronisée: $(date)"
            sleep 10
        else
            echo "AVERTISSEMENT: Synchronisation horloge échouée"
        fi
    fi
fi

# ÉTAPE 5 : MISE À JOUR SYSTÈME
echo "Mise à jour des dépôts..."
if ! apt-get update -y >/dev/null 2>&1; then
    sleep 5
    if ! apt-get update -y >/dev/null 2>&1; then
        echo "ERREUR: Mise à jour des dépôts échouée"
        exit 1
    fi
fi

echo "Installation des mises à jour..."
if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null 2>&1; then
    echo "Nettoyage du système..."
    apt-get autoremove -y >/dev/null 2>&1
    apt-get autoclean -y >/dev/null 2>&1
else
    echo "AVERTISSEMENT: Certaines mises à jour ont échoué"
fi

# ÉTAPE 6 : PERSONNALISATION
echo "Personnalisation interface..."
customize_desktop

# ÉTAPE 7 : FINALISATION
echo "Déconnexion WiFi..."
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1

echo ""
echo "Mise à jour terminée avec succès"
echo "Redémarrage dans 10 secondes..."

for i in {10..1}; do
    echo -ne "\r$i..."
    sleep 1
done

echo ""
reboot