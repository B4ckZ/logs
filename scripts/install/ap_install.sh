#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION DU MODE ACCESS POINT (VERSION NETTOYÉE)
# Installation sans delays - nécessite l'orchestrateur
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
init_logging "Installation du mode Access Point" "install"

# Configuration AP par défaut
AP_CHANNEL="6"        # Canal 2.4GHz stable
AP_BAND="bg"         # Mode compatible
AP_INTERFACE="wlan0"  # Interface WiFi

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

# ===============================================================================
# VÉRIFICATIONS
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION AP =========="

echo "========================================================================"
echo "ÉTAPE 1 : VÉRIFICATIONS"
echo "========================================================================"
echo ""

send_progress 10 "Vérifications initiales"

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Privilèges root requis ✗"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
log_info "Privilèges root confirmés"

# Vérifier l'interface WiFi
echo "◦ Vérification de l'interface WiFi..."
if ! ip link show $AP_INTERFACE >/dev/null 2>&1; then
    echo "  ↦ Interface $AP_INTERFACE non trouvée ✗"
    log_error "Interface $AP_INTERFACE non trouvée"
    exit 1
fi
echo "  ↦ Interface $AP_INTERFACE disponible ✓"
log_info "Interface $AP_INTERFACE disponible"

# Vérifier NetworkManager
echo ""
echo "◦ Vérification de NetworkManager..."
if ! systemctl is-active --quiet NetworkManager; then
    echo "  ↦ NetworkManager non actif ✗"
    log_error "NetworkManager non actif"
    exit 1
fi
echo "  ↦ NetworkManager actif ✓"
log_info "NetworkManager actif"

echo ""
sleep 2

# ===============================================================================
# INSTALLATION DES PAQUETS
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : INSTALLATION DES PAQUETS"
echo "========================================================================"
echo ""

send_progress 25 "Installation des paquets"

# Utiliser la fonction hybride pour installer les paquets AP
if hybrid_package_install "Point d'accès" "dnsmasq iptables"; then
    echo ""
    log_success "Tous les paquets AP installés"
else
    echo ""
    echo "  ↦ Échec de l'installation des paquets ✗"
    log_error "Impossible d'installer les paquets requis"
    exit 1
fi

echo ""
sleep 2

# ===============================================================================
# PRÉPARATION DU SYSTÈME
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 3 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 35 "Préparation du système"

# Créer un resolv.conf fonctionnel
echo "◦ Configuration du resolv.conf..."
log_info "Configuration du resolv.conf"

cat > /etc/resolv.conf << EOF
# Serveurs DNS pour MaxLink
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Protéger le fichier
log_command "chattr +i /etc/resolv.conf 2>/dev/null || true" "Protection du resolv.conf"
echo "  ↦ resolv.conf configuré et protégé ✓"
log_info "resolv.conf configuré avec succès"

# Désactiver les services conflictuels
echo ""
echo "◦ Nettoyage des services DNS conflictuels..."
log_info "Désactivation des services DNS conflictuels"

if systemctl is-active --quiet systemd-resolved; then
    log_command "systemctl stop systemd-resolved" "Arrêt systemd-resolved"
    log_command "systemctl disable systemd-resolved" "Désactivation systemd-resolved"
    echo "  ↦ systemd-resolved désactivé ✓"
fi

if systemctl is-active --quiet dnsmasq; then
    log_command "systemctl stop dnsmasq" "Arrêt dnsmasq système"
    log_command "systemctl disable dnsmasq" "Désactivation dnsmasq système"
    echo "  ↦ dnsmasq système désactivé ✓"
fi

# Désactiver les connexions WiFi actives
echo ""
echo "◦ Désactivation des connexions WiFi existantes..."
log_info "Nettoyage des connexions WiFi existantes"

log_command "nmcli device disconnect $AP_INTERFACE 2>/dev/null || true" "Déconnexion interface"
log_command "nmcli connection delete '$AP_SSID' 2>/dev/null || true" "Suppression ancienne config AP"
echo "  ↦ Connexions nettoyées ✓"

# Configurer NetworkManager pour utiliser dnsmasq
echo ""
echo "◦ Configuration de NetworkManager..."
log_info "Configuration de NetworkManager pour dnsmasq"

if [ ! -f "/etc/NetworkManager/NetworkManager.conf.original" ]; then
    log_command "cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.original" "Sauvegarde config NetworkManager"
fi

cat > /etc/NetworkManager/NetworkManager.conf << EOF
[main]
plugins=ifupdown,keyfile
dns=dnsmasq
rc-manager=resolvconf

[ifupdown]
managed=false

[device]
wifi.scan-rand-mac-address=no
EOF

echo "  ↦ NetworkManager configuré pour dnsmasq ✓"
log_info "NetworkManager configuré avec succès"

echo ""
sleep 2

# ===============================================================================
# CRÉATION DE LA CONFIGURATION AP
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DU POINT D'ACCÈS"
echo "========================================================================"
echo ""

send_progress 50 "Configuration du point d'accès"

echo "◦ Création du profil Access Point..."
echo "  ↦ SSID: $AP_SSID"
echo "  ↦ IP: $AP_IP/$AP_NETMASK"
echo "  ↦ Canal: $AP_CHANNEL (2.4GHz)"

log_info "Configuration AP - SSID: $AP_SSID, IP: $AP_IP/$AP_NETMASK, Canal: $AP_CHANNEL"

# Créer la connexion AP avec NetworkManager
if log_command "nmcli connection add \
    type wifi \
    ifname $AP_INTERFACE \
    con-name '$AP_SSID' \
    autoconnect yes \
    ssid '$AP_SSID' \
    mode ap \
    802-11-wireless.band $AP_BAND \
    802-11-wireless.channel $AP_CHANNEL \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk '$AP_PASSWORD' \
    ipv4.method shared \
    ipv4.addresses '$AP_IP/$AP_NETMASK' \
    ipv6.method disabled" "Création profil AP"; then
    echo "  ↦ Profil AP créé ✓"
    log_success "Profil AP créé avec succès"
else
    echo "  ↦ Erreur lors de la création du profil ✗"
    log_error "Échec de la création du profil AP"
    exit 1
fi

# Configuration DHCP et DNS
echo ""
echo "◦ Configuration DHCP et DNS..."
log_info "Configuration DHCP/DNS pour l'AP"

mkdir -p /etc/NetworkManager/dnsmasq-shared.d/
mkdir -p /etc/NetworkManager/dnsmasq.d/

# Configuration principale COMPLÈTE
cat > /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf << EOF
# Configuration DHCP MaxLink AP
interface=$AP_INTERFACE
bind-interfaces
listen-address=$AP_IP

# Plage DHCP
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,12h

# Options DHCP
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP,8.8.8.8
dhcp-option=option:domain-name,maxlink.local
dhcp-authoritative

# Résolution DNS locale
address=/$NGINX_DASHBOARD_DOMAIN/$AP_IP
address=/maxlink-dashboard.local/$AP_IP
address=/maxlink.dashboard.local/$AP_IP
address=/dashboard.local/$AP_IP
address=/maxlink.local/$AP_IP
address=/maxlink/$AP_IP

# Serveurs DNS upstream
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1

# Cache DNS optimisé
cache-size=1000
no-negcache

# Sécurité
domain-needed
bogus-priv

# Résoudre les requêtes locales
local=/local/
expand-hosts

# Options supplémentaires pour la stabilité
resolv-file=/etc/resolv.conf
strict-order
EOF

echo "  ↦ Configuration DHCP/DNS créée ✓"
log_info "Configuration dnsmasq créée dans /etc/NetworkManager/dnsmasq-shared.d/"

# Configuration DNS supplémentaire
cat > /etc/NetworkManager/dnsmasq.d/maxlink.conf << EOF
# Écouter sur l'interface AP
interface=$AP_INTERFACE
except-interface=lo

# Résolutions locales supplémentaires (redondance)
address=/$NGINX_DASHBOARD_DOMAIN/$AP_IP
EOF

echo "  ↦ Configuration DNS supplémentaire ajoutée ✓"
log_info "Configuration DNS supplémentaire créée"

echo ""
sleep 2

# ===============================================================================
# CONFIGURATION DU PARE-FEU
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 5 : CONFIGURATION DU PARE-FEU"
echo "========================================================================"
echo ""

send_progress 70 "Configuration du pare-feu"

echo "◦ Configuration des règles de pare-feu..."
log_info "Configuration des règles iptables"

if command -v iptables >/dev/null 2>&1; then
    log_command "iptables -A INPUT -i $AP_INTERFACE -p udp --dport 53 -j ACCEPT 2>/dev/null || true" "Règle DNS UDP"
    log_command "iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 53 -j ACCEPT 2>/dev/null || true" "Règle DNS TCP"
    echo "  ↦ Port DNS (53) ouvert ✓"
    
    log_command "iptables -A INPUT -i $AP_INTERFACE -p udp --dport 67:68 -j ACCEPT 2>/dev/null || true" "Règle DHCP"
    echo "  ↦ Ports DHCP (67-68) ouverts ✓"
    
    log_command "iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 80 -j ACCEPT 2>/dev/null || true" "Règle HTTP"
    echo "  ↦ Port HTTP (80) ouvert ✓"
    
    log_command "iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 1883 -j ACCEPT 2>/dev/null || true" "Règle MQTT"
    log_command "iptables -A INPUT -i $AP_INTERFACE -p tcp --dport 9001 -j ACCEPT 2>/dev/null || true" "Règle MQTT WebSocket"
    echo "  ↦ Ports MQTT (1883, 9001) ouverts ✓"
    
    log_info "Règles iptables configurées avec succès"
fi

if command -v netfilter-persistent >/dev/null 2>&1; then
    log_command "netfilter-persistent save >/dev/null 2>&1 || true" "Sauvegarde règles iptables"
fi

echo ""
sleep 2

# ===============================================================================
# ACTIVATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : ACTIVATION DU POINT D'ACCÈS"
echo "========================================================================"
echo ""

send_progress 85 "Activation du point d'accès"

echo "◦ Démarrage du point d'accès..."
log_info "Activation du point d'accès"

# Redémarrer NetworkManager pour appliquer toutes les configurations
log_command "systemctl restart NetworkManager" "Redémarrage NetworkManager"
sleep 5

# Activer la connexion AP
if log_command "nmcli connection up '$AP_SSID'" "Activation connexion AP"; then
    echo "  ↦ Point d'accès activé ✓"
    log_success "Point d'accès activé avec succès"
else
    echo "  ↦ Erreur lors de l'activation ✗"
    log_error "Échec de l'activation du point d'accès"
    exit 1
fi

# Vérifier l'état
echo ""
echo "◦ Vérification de l'état..."
log_info "Vérification de l'état du point d'accès"
sleep 3

if nmcli connection show --active | grep -q "$AP_SSID"; then
    echo "  ↦ Point d'accès opérationnel ✓"
    log_success "Point d'accès opérationnel"
    
    if pgrep -f "dnsmasq.*NetworkManager" > /dev/null; then
        echo "  ↦ Service DNS actif ✓"
        log_info "Service dnsmasq actif"
    else
        echo "  ↦ Service DNS non détecté ⚠"
        log_warn "Service dnsmasq non détecté"
    fi
else
    echo "  ↦ Point d'accès non actif ✗"
    log_error "Point d'accès non actif"
    exit 1
fi

echo ""
sleep 2

# ===============================================================================
# FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 7 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 95 "Finalisation"

echo "◦ Configuration de démarrage automatique..."
echo "  ↦ Le point d'accès démarrera automatiquement ✓"
log_info "Configuration de démarrage automatique activée"

echo ""
echo "◦ Informations de connexion :"
echo "  ↦ Nom du réseau : $AP_SSID"
echo "  ↦ Mot de passe  : $AP_PASSWORD"
echo "  ↦ Adresse IP    : $AP_IP"
echo "  ↦ Plage DHCP    : $AP_DHCP_START - $AP_DHCP_END"
echo ""
echo "◦ Accès au dashboard :"
echo "  ↦ http://$AP_IP"
echo "  ↦ http://$NGINX_DASHBOARD_DOMAIN"
echo "  ↦ http://dashboard.local"

log_info "Configuration finale:"
log_info "  - SSID: $AP_SSID"
log_info "  - IP: $AP_IP"
log_info "  - DHCP: $AP_DHCP_START - $AP_DHCP_END"

send_progress 100 "Installation terminée"

echo ""
echo "◦ Installation terminée avec succès !"
echo ""
echo "◦ IMPORTANT : L'orchestrateur doit être installé pour gérer le démarrage ordonné"
echo ""

# Test final rapide
echo "◦ Test rapide de la résolution DNS..."
if dig +short @127.0.0.1 maxlink-dashboard.local | grep -q "$AP_IP"; then
    echo "  ↦ DNS fonctionnel ✓"
    log_success "Test DNS final réussi"
else
    echo "  ↦ DNS non fonctionnel - Un redémarrage peut être nécessaire ⚠"
    log_warn "Test DNS final échoué - redémarrage recommandé"
fi

echo ""
echo "  ↦ Redémarrage du système prévu dans 15 secondes..."
echo ""

log_info "Redémarrage du système prévu dans 15 secondes"
sleep 15

log_info "Redémarrage du système"
reboot