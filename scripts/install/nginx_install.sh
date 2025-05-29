#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION NGINX ET DASHBOARD
# Version avec système de logging unifié
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
init_logging "Installation Nginx et Dashboard" "install"

# Variables pour la connexion WiFi
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

# Fonction pour ajouter la configuration DNS si AP est installé
update_dns_if_ap_exists() {
    log_info "Vérification de la configuration AP existante"
    
    # Vérifier si le mode AP est configuré
    if [ -f "/etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf" ]; then
        echo "◦ Mode AP détecté, mise à jour de la configuration DNS..."
        log_info "Mode AP détecté, mise à jour DNS nécessaire"
        
        # Vérifier si l'entrée DNS existe déjà
        if ! grep -q "address=/$NGINX_DASHBOARD_DOMAIN/" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf; then
            # Ajouter l'entrée DNS
            echo "" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "# Dashboard MaxLink (ajouté par nginx_install.sh)" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "address=/$NGINX_DASHBOARD_DOMAIN/$AP_IP" >> /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
            echo "  ↦ Entrée DNS ajoutée pour $NGINX_DASHBOARD_DOMAIN ✓"
            log_success "Entrée DNS ajoutée pour $NGINX_DASHBOARD_DOMAIN"
            
            # Redémarrer NetworkManager si le mode AP est actif
            if nmcli con show --active | grep -q "$AP_SSID"; then
                echo "  ↦ Redémarrage de NetworkManager pour appliquer les changements..."
                log_command "systemctl restart NetworkManager" "Redémarrage NetworkManager"
                wait_silently 3
                
                # Réactiver le mode AP
                log_command "nmcli con up '$AP_SSID' >/dev/null 2>&1" "Réactivation mode AP"
                echo "  ↦ Mode AP réactivé avec la nouvelle configuration DNS ✓"
                log_info "Mode AP réactivé avec nouvelle configuration DNS"
            fi
        else
            echo "  ↦ Configuration DNS déjà présente ✓"
            log_info "Configuration DNS déjà présente"
        fi
    else
        echo "◦ Mode AP non installé - La résolution DNS sera configurée lors de l'installation de l'AP"
        log_info "Mode AP non installé - configuration DNS différée"
    fi
}

# ===============================================================================
# ÉTAPE 1 : PRÉPARATION ET VÉRIFICATION WIFI
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION NGINX ET DASHBOARD =========="

echo "========================================================================"
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 5 "Préparation du système..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Privilèges root requis ✗"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
log_info "Privilèges root confirmés"

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
log_command "nmcli device wifi rescan >/dev/null 2>&1" "Scan WiFi"
wait_silently 5

# Vérifier la présence du réseau
NETWORK_INFO=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_INFO" ]; then
    SIGNAL=$(echo "$NETWORK_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    echo "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A} dBm) ✓"
    log_info "Réseau $WIFI_SSID trouvé - Signal: ${SIGNAL:-N/A} dBm"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    log_error "Réseau $WIFI_SSID non trouvé"
    exit 1
fi

send_progress 20 "Connexion en cours..."

# Connexion au réseau
echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
log_command "nmcli connection delete '$WIFI_SSID' 2>/dev/null || true" "Suppression ancienne connexion"

if log_command "nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASSWORD' >/dev/null 2>&1" "Connexion WiFi"; then
    echo "  ↦ Connexion initiée ✓"
    echo "  ↦ Obtention de l'adresse IP..."
    log_info "Connexion WiFi initiée - attente IP"
    wait_silently 5
    
    IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
        echo "  ↦ Connexion établie (IP: $IP) ✓"
        log_success "Connexion établie - IP: $IP"
    else
        echo "  ↦ Connexion établie mais pas d'IP ⚠"
        log_warn "Connexion établie mais pas d'IP obtenue"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    log_error "Échec de la connexion WiFi"
    exit 1
fi

# Test de connectivité
echo ""
echo "◦ Test de connectivité..."
echo "  ↦ Stabilisation de la connexion..."
wait_silently 2

# Test IP d'abord
if log_command "ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1" "Test ping Google DNS"; then
    echo "  ↦ Connectivité IP confirmée ✓"
    
    # Test DNS ensuite
    if log_command "ping -c 3 -W 2 google.com >/dev/null 2>&1" "Test résolution DNS"; then
        echo "  ↦ Résolution DNS fonctionnelle ✓"
        log_success "Connectivité internet complète"
    else
        echo "  ↦ Problème de résolution DNS ✗"
        log_warn "Problème DNS détecté - tentative de correction"
        # Forcer les serveurs DNS
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        wait_silently 2
        
        if ping -c 3 -W 2 google.com >/dev/null 2>&1; then
            echo "  ↦ DNS corrigé ✓"
            log_success "DNS corrigé avec succès"
        else
            echo "  ↦ DNS toujours non fonctionnel ✗"
            log_error "DNS non fonctionnel après correction"
            exit 1
        fi
    fi
else
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet"
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
    log_info "Nginx déjà installé"
else
    echo "  ↦ Installation de Nginx..."
    log_info "Installation de Nginx nécessaire"
    log_command "apt-get update -qq" "Mise à jour des dépôts"
    if log_command "apt-get install -y nginx >/dev/null 2>&1" "Installation Nginx"; then
        echo "  ↦ Nginx installé ✓"
        log_success "Nginx installé avec succès"
    else
        echo "  ↦ Erreur lors de l'installation ✗"
        log_error "Échec de l'installation de Nginx"
        exit 1
    fi
fi

# Arrêter Nginx pour la configuration
echo ""
echo "◦ Préparation de Nginx..."
log_command "systemctl stop nginx >/dev/null 2>&1" "Arrêt Nginx"
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
    log_info "Installation de Git nécessaire"
    if log_command "apt-get install -y git >/dev/null 2>&1" "Installation Git"; then
        echo "  ↦ Git installé ✓"
        log_success "Git installé avec succès"
    else
        log_error "Échec de l'installation de Git"
        exit 1
    fi
else
    echo "  ↦ Git disponible ✓"
    log_info "Git déjà disponible"
fi

# Vérifier si le dashboard existe déjà
if [ -d "$NGINX_DASHBOARD_DIR" ]; then
    echo ""
    echo "◦ Dashboard existant détecté..."
    echo "  ↦ Sauvegarde de l'ancienne version..."
    log_info "Dashboard existant détecté - création sauvegarde"
    
    # Créer une sauvegarde datée
    BACKUP_DIR="/var/www/maxlink-dashboard-backup-$(date +%Y%m%d_%H%M%S)"
    log_command "cp -r '$NGINX_DASHBOARD_DIR' '$BACKUP_DIR'" "Sauvegarde dashboard"
    echo "  ↦ Sauvegarde créée : $BACKUP_DIR ✓"
    log_info "Sauvegarde créée: $BACKUP_DIR"
    
    # Supprimer l'ancienne version
    rm -rf "$NGINX_DASHBOARD_DIR"
fi

# Créer le répertoire temporaire
echo ""
echo "◦ Téléchargement du dashboard depuis GitHub..."
TEMP_DIR="/tmp/maxlink-dashboard-$(date +%s)"
mkdir -p "$TEMP_DIR"
log_info "Répertoire temporaire: $TEMP_DIR"

# Construire l'URL de clone (avec token si défini)
if [ -n "$GITHUB_TOKEN" ]; then
    CLONE_URL="https://${GITHUB_TOKEN}@${GITHUB_REPO_URL#https://}"
else
    CLONE_URL="$GITHUB_REPO_URL"
fi

# Cloner le dépôt (ajouter .git à l'URL)
echo "  ↦ Clonage du dépôt..."
CLONE_URL_FIXED="${CLONE_URL%.git}.git"
log_info "Clonage depuis: $CLONE_URL_FIXED (branch: $GITHUB_BRANCH)"

# Cloner avec sortie réduite
if log_command "git clone --branch '$GITHUB_BRANCH' --depth 1 '$CLONE_URL_FIXED' '$TEMP_DIR/repo' >/dev/null 2>&1" "Clonage GitHub"; then
    echo "  ↦ Dépôt cloné ✓"
    log_success "Dépôt cloné avec succès"
else
    echo "  ↦ Erreur lors du clonage ✗"
    log_error "Échec du clonage depuis $CLONE_URL_FIXED"
    
    # Si une sauvegarde existe, la restaurer
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Restauration de la sauvegarde..."
        log_info "Restauration de la sauvegarde suite à échec"
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
    log_command "cp -r '$TEMP_DIR/repo/$GITHUB_DASHBOARD_DIR' '$NGINX_DASHBOARD_DIR'" "Copie dashboard"
    echo "  ↦ Dashboard copié ✓"
    log_success "Dashboard copié avec succès"
    
    # Si c'était une mise à jour, afficher l'info
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Mise à jour effectuée (ancienne version sauvegardée)"
        log_info "Mise à jour du dashboard effectuée"
    fi
else
    echo "  ↦ Dossier dashboard non trouvé ✗"
    log_error "Dossier $GITHUB_DASHBOARD_DIR non trouvé dans le dépôt"
    
    # Restaurer la sauvegarde si elle existe
    if [ -d "$BACKUP_DIR" ]; then
        echo "  ↦ Restauration de la sauvegarde..."
        mv "$BACKUP_DIR" "$NGINX_DASHBOARD_DIR"
        echo "  ↦ Dashboard restauré ✓"
        log_info "Dashboard restauré depuis sauvegarde"
    fi
    
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Nettoyer
rm -rf "$TEMP_DIR"
log_info "Nettoyage du répertoire temporaire"

# Permissions
log_command "chown -R www-data:www-data '$NGINX_DASHBOARD_DIR'" "Application permissions"
log_command "chmod -R 755 '$NGINX_DASHBOARD_DIR'" "Application droits"
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
    log_info "Configuration Nginx existante - mise à jour"
fi

echo "◦ Création de la configuration du site..."
log_info "Création de la configuration Nginx"

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
log_success "Configuration Nginx créée"

# Vérifier les permissions du dashboard
echo ""
echo "◦ Vérification des permissions..."
log_command "chown -R www-data:www-data '$NGINX_DASHBOARD_DIR'" "Vérification propriétaire"
log_command "find '$NGINX_DASHBOARD_DIR' -type d -exec chmod 755 {} \;" "Permissions dossiers"
log_command "find '$NGINX_DASHBOARD_DIR' -type f -exec chmod 644 {} \;" "Permissions fichiers"
echo "  ↦ Permissions vérifiées ✓"

# Activer le site
echo ""
echo "◦ Activation du site..."
log_command "rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true" "Suppression site par défaut"
log_command "rm -f /etc/nginx/sites-enabled/maxlink-dashboard 2>/dev/null || true" "Suppression ancien lien"
log_command "ln -s /etc/nginx/sites-available/maxlink-dashboard /etc/nginx/sites-enabled/" "Création lien symbolique"
echo "  ↦ Site activé ✓"
log_info "Site Nginx activé"

# Tester la configuration
if log_command "nginx -t >/dev/null 2>&1" "Test configuration Nginx"; then
    echo "  ↦ Configuration validée ✓"
    log_success "Configuration Nginx valide"
else
    echo "  ↦ Erreur de configuration ✗"
    log_error "Configuration Nginx invalide"
    nginx -t
    exit 1
fi

# Démarrer Nginx
echo ""
echo "◦ Démarrage de Nginx..."
log_command "systemctl enable nginx >/dev/null 2>&1" "Activation au démarrage"
log_command "systemctl start nginx >/dev/null 2>&1" "Démarrage Nginx"
echo "  ↦ Nginx démarré et activé ✓"
log_success "Nginx démarré avec succès"

# Test rapide de l'autoindex
echo ""
echo "◦ Test de l'autoindex..."
sleep 2
if curl -s http://localhost/widgets/ | grep -q "clock\|logo\|mqtt" || curl -s http://localhost/widgets/ | grep -q "Index of"; then
    echo "  ↦ Autoindex fonctionnel ✓"
    log_success "Autoindex fonctionnel"
else
    echo "  ↦ Autoindex peut nécessiter un redémarrage ⚠"
    log_warn "Autoindex non confirmé - redémarrage peut être nécessaire"
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
log_command "nmcli connection down '$WIFI_SSID' >/dev/null 2>&1" "Déconnexion WiFi"
wait_silently 2
log_command "nmcli connection delete '$WIFI_SSID' >/dev/null 2>&1" "Suppression profil WiFi"
echo "  ↦ WiFi déconnecté ✓"
log_info "WiFi déconnecté"

# Réactiver le mode AP s'il était actif avant
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    log_info "Réactivation du mode AP"
    log_command "nmcli con up '$AP_SSID' >/dev/null 2>&1 || true" "Activation AP"
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

log_info "Installation terminée avec succès"
log_info "Dashboard accessible à: http://$AP_IP et http://$NGINX_DASHBOARD_DOMAIN"

echo "  ↦ Redémarrage dans 10 secondes..."
echo ""

log_info "Redémarrage du système prévu dans 10 secondes"

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
log_info "Redémarrage du système"
reboot