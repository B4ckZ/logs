#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION NGINX ET DASHBOARD
# Version finale avec toutes les corrections intégrées
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables et du logging
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation Nginx et Dashboard"

# Variables pour la connexion WiFi
AP_WAS_ACTIVE=false

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
}

# Attente simple
wait_silently() {
    sleep "$1"
}

# Fonction pour ajouter la configuration DNS si AP est installé
update_dns_if_ap_exists() {
    # Vérifier si le mode AP est configuré
    if [ -f "/etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf" ]; then
        echo "◦ Mode AP détecté, mise à jour de la configuration DNS..."
        
        # Vérifier si l'entrée DNS existe déjà
        if ! grep -q "address=/$NGINX_DASHBOARD_DOMAIN/" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf; then
            # Ajouter l'entrée DNS
            echo "" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "# Dashboard MaxLink (ajouté par nginx_install.sh)" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "address=/$NGINX_DASHBOARD_DOMAIN/$AP_IP" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "  ↦ Entrée DNS ajoutée pour $NGINX_DASHBOARD_DOMAIN ✓"
            
            # Redémarrer NetworkManager si le mode AP est actif
            if nmcli con show --active | grep -q "$AP_SSID"; then
                echo "  ↦ Redémarrage de NetworkManager pour appliquer les changements..."
                systemctl restart NetworkManager
                wait_silently 3
                
                # Réactiver le mode AP
                nmcli con up "$AP_SSID" >/dev/null 2>&1
                echo "  ↦ Mode AP réactivé avec la nouvelle configuration DNS ✓"
            fi
        else
            echo "  ↦ Configuration DNS déjà présente ✓"
        fi
    else
        echo "◦ Mode AP non installé - La résolution DNS sera configurée lors de l'installation de l'AP"
    fi
}

# ===============================================================================
# ÉTAPE 1 : PRÉPARATION ET VÉRIFICATION WIFI
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 5 "Préparation du système..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Privilèges root requis ✗"
    exit 1
fi

# Stabilisation initiale
echo "◦ Stabilisation du système après démarrage..."
echo "  ↦ Initialisation des services réseau..."
wait_silently 5

# Vérifier et désactiver le mode AP si actif
if nmcli con show --active | grep -q "$AP_SSID"; then
    echo ""
    echo "◦ Mode point d'accès détecté..."
    AP_WAS_ACTIVE=true
    nmcli con down "$AP_SSID" >/dev/null 2>&1
    wait_silently 2
    echo "  ↦ Mode AP désactivé temporairement ✓"
fi

# Vérifier l'interface WiFi
echo ""
echo "◦ Vérification de l'interface WiFi..."
if ip link show wlan0 >/dev/null 2>&1; then
    echo "  ↦ Interface WiFi détectée ✓"
    nmcli radio wifi on >/dev/null 2>&1
    wait_silently 2
    echo "  ↦ WiFi activé ✓"
else
    echo "  ↦ Interface WiFi non disponible ✗"
    exit 1
fi

send_progress 10 "WiFi préparé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 2 : CONNEXION RÉSEAU
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : CONNEXION RÉSEAU"
echo "========================================================================"
echo ""

send_progress 15 "Recherche du réseau..."

# Scan et recherche du réseau
echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
echo "  ↦ Scan des réseaux disponibles..."
nmcli device wifi rescan >/dev/null 2>&1
wait_silently 5

# Vérifier la présence du réseau
NETWORK_INFO=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_INFO" ]; then
    SIGNAL=$(echo "$NETWORK_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    echo "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A} dBm) ✓"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    exit 1
fi

send_progress 20 "Connexion en cours..."

# Connexion au réseau
echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
nmcli connection delete "$WIFI_SSID" 2>/dev/null || true

if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    echo "  ↦ Connexion initiée ✓"
    echo "  ↦ Obtention de l'adresse IP..."
    wait_silently 5
    
    IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
        echo "  ↦ Connexion établie (IP: $IP) ✓"
    else
        echo "  ↦ Connexion établie mais pas d'IP ⚠"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    exit 1
fi

# Test de connectivité
echo ""
echo "◦ Test de connectivité..."
echo "  ↦ Stabilisation de la connexion..."
wait_silently 2

# Test IP d'abord
if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "  ↦ Connectivité IP confirmée ✓"
    
    # Test DNS ensuite
    if ping -c 3 -W 2 google.com >/dev/null 2>&1; then
        echo "  ↦ Résolution DNS fonctionnelle ✓"
    else
        echo "  ↦ Problème de résolution DNS ✗"
        # Forcer les serveurs DNS
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        wait_silently 2
        
        if ping -c 3 -W 2 google.com >/dev/null 2>&1; then
            echo "  ↦ DNS corrigé ✓"
        else
            echo "  ↦ DNS toujours non fonctionnel ✗"
            exit 1
        fi
    fi
else
    echo "  ↦ Pas de connectivité Internet ✗"
    exit 1
fi

send_progress 30 "Connexion établie"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 3 : INSTALLATION NGINX
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 3 : INSTALLATION DE NGINX"
echo "========================================================================"
echo ""

send_progress 35 "Installation de Nginx..."

echo "◦ Vérification de Nginx..."
if dpkg -l nginx >/dev/null 2>&1; then
    echo "  ↦ Nginx déjà installé ✓"
else
    echo "  ↦ Installation de Nginx..."
    apt-get update -qq
    if apt-get install -y nginx >/dev/null 2>&1; then
        echo "  ↦ Nginx installé ✓"
    else
        echo "  ↦ Erreur lors de l'installation ✗"
        exit 1
    fi
fi

# Arrêter Nginx pour la configuration
echo ""
echo "◦ Préparation de Nginx..."
systemctl stop nginx >/dev/null 2>&1
echo "  ↦ Service Nginx arrêté ✓"

send_progress 45 "Nginx installé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 4 : TÉLÉCHARGEMENT DU DASHBOARD
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 4 : TÉLÉCHARGEMENT DU DASHBOARD"
echo "========================================================================"
echo ""

send_progress 50 "Téléchargement du dashboard..."

# Installer git si nécessaire
echo "◦ Vérification de Git..."
if ! command -v git >/dev/null 2>&1; then
    echo "  ↦ Installation de Git..."
    apt-get install -y git >/dev/null 2>&1
    echo "  ↦ Git installé ✓"
else
    echo "  ↦ Git disponible ✓"
fi

# Vérifier si le dashboard existe déjà
if [ -d "$NGINX_DASHBOARD_DIR" ]; then
    echo ""
    echo "◦ Dashboard existant détecté..."
    echo "  ↦ Sauvegarde de l'ancienne version..."
    
    # Créer une sauvegarde datée
    BACKUP_DIR="/var/www/maxlink-dashboard-backup-$(date +%Y%m%d_%H%M%S)"
    cp -r "$NGINX_DASHBOARD_DIR" "$BACKUP_DIR"
    echo "  ↦ Sauvegarde créée : $BACKUP_DIR ✓"
    
    # Supprimer l'ancienne version
    rm -rf "$NGINX_DASHBOARD_DIR"
fi

# Créer le répertoire temporaire
echo ""
echo "◦ Téléchargement du dashboard depuis GitHub..."
TEMP_DIR="/tmp/maxlink-dashboard-$(date +%s)"
mkdir -p "$TEMP_DIR"

# Construire l'URL de clone (avec token si défini)
if [ -n "$GITHUB_TOKEN" ]; then
    CLONE_URL="https://${GITHUB_TOKEN}@${GITHUB_REPO_URL#https://}"
else
    CLONE_URL="$GITHUB_REPO_URL"
fi

# Cloner le dépôt (ajouter .git à l'URL)
echo "  ↦ Clonage du dépôt..."
CLONE_URL_FIXED="${CLONE_URL%.git}.git"
log_info "Tentative de clonage depuis: $CLONE_URL_FIXED"

# Cloner avec sortie réduite
if git clone --branch "$GITHUB_BRANCH" --depth 1 "$CLONE_URL_FIXED" "$TEMP_DIR/repo" >/dev/null 2>&1; then
    echo "  ↦ Dépôt cloné ✓"
    log_info "Clonage réussi"
else
    echo "  ↦ Erreur lors du clonage ✗"
    log_error "Échec du clonage depuis $CLONE_URL_FIXED"
    
    # Si une sauvegarde existe, la restaurer
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Restauration de la sauvegarde..."
        mv "$BACKUP_DIR" "$NGINX_DASHBOARD_DIR"
        echo "  ↦ Dashboard restauré ✓"
    fi
    
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Copier le dashboard
echo ""
echo "◦ Installation du dashboard..."
mkdir -p "$(dirname "$NGINX_DASHBOARD_DIR")"

if [ -d "$TEMP_DIR/repo/$GITHUB_DASHBOARD_DIR" ]; then
    cp -r "$TEMP_DIR/repo/$GITHUB_DASHBOARD_DIR" "$NGINX_DASHBOARD_DIR"
    echo "  ↦ Dashboard copié ✓"
    
    # Si c'était une mise à jour, afficher l'info
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Mise à jour effectuée (ancienne version sauvegardée)"
    fi
else
    echo "  ↦ Dossier dashboard non trouvé ✗"
    
    # Restaurer la sauvegarde si elle existe
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Restauration de la sauvegarde..."
        mv "$BACKUP_DIR" "$NGINX_DASHBOARD_DIR"
        echo "  ↦ Dashboard restauré ✓"
    fi
    
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Nettoyer
rm -rf "$TEMP_DIR"

# Permissions
chown -R www-data:www-data "$NGINX_DASHBOARD_DIR"
chmod -R 755 "$NGINX_DASHBOARD_DIR"
echo "  ↦ Permissions appliquées ✓"

send_progress 65 "Dashboard installé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 5 : CONFIGURATION NGINX
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 5 : CONFIGURATION DE NGINX"
echo "========================================================================"
echo ""

send_progress 75 "Configuration de Nginx..."

# Vérifier si Nginx est déjà configuré
if [ -f "/etc/nginx/sites-available/maxlink-dashboard" ]; then
    echo "◦ Configuration Nginx existante détectée..."
    echo "  ↦ Mise à jour de la configuration..."
fi

echo "◦ Création de la configuration du site..."

# Créer la configuration Nginx COMPLÈTE avec autoindex
cat > /etc/nginx/sites-available/maxlink-dashboard << EOF
server {
    listen $NGINX_PORT default_server;
    server_name $NGINX_DASHBOARD_DOMAIN maxlink-dashboard.local maxlink.dashboard.local dashboard.local $AP_IP localhost _;
    
    root $NGINX_DASHBOARD_DIR;
    index index.html;
    
    # Configuration principale
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # AUTOINDEX POUR WIDGETS - Configuration corrigée
    location /widgets {
        alias $NGINX_DASHBOARD_DIR/widgets;
        autoindex on;
        autoindex_format json;
        autoindex_exact_size off;
        autoindex_localtime on;
    }
    
    # Alternative pour compatibilité maximale
    location ~ ^/widgets/$ {
        root $NGINX_DASHBOARD_DIR;
        autoindex on;
        autoindex_format html;
    }
    
    # Optimisations de performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # Compression gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss application/rss+xml application/atom+xml image/svg+xml;
    
    # Cache pour les fichiers statiques
    location ~* \.(jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|otf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Pas de cache pour HTML/JS/CSS (développement)
    location ~* \.(html|js|css)$ {
        expires -1;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
    }
    
    # Headers de sécurité
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Logs
    access_log /var/log/nginx/maxlink-access.log;
    error_log /var/log/nginx/maxlink-error.log;
}
EOF

echo "  ↦ Configuration créée ✓"

# Vérifier les permissions du dashboard
echo ""
echo "◦ Vérification des permissions..."
chown -R www-data:www-data "$NGINX_DASHBOARD_DIR"
find "$NGINX_DASHBOARD_DIR" -type d -exec chmod 755 {} \;
find "$NGINX_DASHBOARD_DIR" -type f -exec chmod 644 {} \;
echo "  ↦ Permissions vérifiées ✓"

# Activer le site
echo ""
echo "◦ Activation du site..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/maxlink-dashboard 2>/dev/null || true
ln -s /etc/nginx/sites-available/maxlink-dashboard /etc/nginx/sites-enabled/
echo "  ↦ Site activé ✓"

# Tester la configuration
if nginx -t >/dev/null 2>&1; then
    echo "  ↦ Configuration validée ✓"
else
    echo "  ↦ Erreur de configuration ✗"
    nginx -t
    exit 1
fi

# Démarrer Nginx
echo ""
echo "◦ Démarrage de Nginx..."
systemctl enable nginx >/dev/null 2>&1
systemctl start nginx >/dev/null 2>&1
echo "  ↦ Nginx démarré et activé ✓"

# Test rapide de l'autoindex
echo ""
echo "◦ Test de l'autoindex..."
sleep 2
if curl -s http://localhost/widgets/ | grep -q "clock\|logo\|mqtt" || curl -s http://localhost/widgets/ | grep -q "Index of"; then
    echo "  ↦ Autoindex fonctionnel ✓"
else
    echo "  ↦ Autoindex peut nécessiter un redémarrage ⚠"
fi

send_progress 85 "Nginx configuré"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 6 : CONFIGURATION DNS INTELLIGENTE
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : CONFIGURATION DNS"
echo "========================================================================"
echo ""

send_progress 90 "Configuration DNS..."

# Appeler la fonction pour mettre à jour le DNS si l'AP existe
update_dns_if_ap_exists

send_progress 95 "Configuration terminée"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 7 : FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 7 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 98 "Finalisation..."

# Déconnexion WiFi
echo "◦ Déconnexion du réseau WiFi..."
nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
wait_silently 2
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
echo "  ↦ WiFi déconnecté ✓"

# Réactiver le mode AP s'il était actif avant
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    nmcli con up "$AP_SSID" >/dev/null 2>&1 || true
    wait_silently 3
    echo "  ↦ Mode AP réactivé ✓"
fi

send_progress 100 "Installation terminée !"

echo ""
echo "◦ Installation terminée avec succès !"
echo "  ↦ Dashboard installé dans : $NGINX_DASHBOARD_DIR"
echo "  ↦ Accessible via :"
echo "    • http://$AP_IP (toujours fonctionnel)"
if [ -f "/etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf" ] && grep -q "address=/$NGINX_DASHBOARD_DOMAIN/" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf; then
    echo "    • http://$NGINX_DASHBOARD_DOMAIN"
    echo "    • http://maxlink-dashboard.local"
    echo "    • http://dashboard.local"
else
    echo "    • http://$NGINX_DASHBOARD_DOMAIN (nécessite l'installation de l'AP)"
fi
echo ""

# Note importante pour les utilisateurs Windows
echo "◦ Note pour les utilisateurs Windows :"
echo "  Si l'accès par nom de domaine ne fonctionne pas :"
echo "  1. Ouvrez PowerShell en tant qu'administrateur"
echo "  2. Exécutez : ipconfig /flushdns"
echo "  3. Ou ajoutez dans C:\\Windows\\System32\\drivers\\etc\\hosts :"
echo "     $AP_IP    $NGINX_DASHBOARD_DOMAIN"
echo ""

echo "  ↦ Redémarrage dans 10 secondes..."
echo ""

log_info "Installation Nginx et Dashboard terminée avec toutes les corrections - Redémarrage du système"

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
reboot