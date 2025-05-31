#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT BROKER (VERSION AVEC STATISTIQUES)
# Installation avec configuration des topics système $SYS activés
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
init_logging "Installation MQTT Broker avec statistiques" "install"

# Variables MQTT - Utiliser les valeurs de variables.sh ou les valeurs par défaut
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mqtt}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_WEBSOCKET_PORT="${MQTT_WEBSOCKET_PORT:-9001}"
MQTT_CONFIG_DIR="/etc/mosquitto"

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
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION MQTT BROKER =========="

echo ""
echo "========================================================================"
echo "INSTALLATION DU BROKER MQTT (MOSQUITTO)"
echo "========================================================================"
echo ""
echo "Configuration : utilisateur '$MQTT_USER' / mot de passe '$MQTT_PASS'"
echo ""

send_progress 5 "Initialisation..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
log_info "Privilèges root confirmés"

# ÉTAPE 1 : Nettoyage et préparation
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 10 "Préparation du système..."

# Arrêter mosquitto s'il est en cours
if systemctl is-active --quiet mosquitto 2>/dev/null; then
    echo "◦ Arrêt du service Mosquitto existant..."
    systemctl stop mosquitto
    echo "  ↦ Service arrêté ✓"
    log_info "Service Mosquitto arrêté"
fi

# Nettoyer les verrous APT si nécessaire
echo "◦ Nettoyage du système de paquets..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null
dpkg --configure -a >/dev/null 2>&1
echo "  ↦ Système de paquets prêt ✓"
log_info "Système de paquets nettoyé"

send_progress 20 "Système préparé"
echo ""
sleep 2

# ÉTAPE 2 : Installation des paquets
echo "========================================================================"
echo "ÉTAPE 2 : INSTALLATION DES PAQUETS"
echo "========================================================================"
echo ""

send_progress 30 "Installation de Mosquitto..."

# Utiliser la fonction hybride pour installer tous les paquets nécessaires
if hybrid_package_install "Mosquitto et dépendances" "libmosquitto1 libdlt2 mosquitto mosquitto-clients"; then
    echo ""
    log_success "Tous les paquets installés avec succès"
else
    echo ""
    echo "  ↦ Certains paquets n'ont pas pu être installés ✗"
    log_error "Installation incomplète des paquets"
    
    # Essayer de corriger
    echo ""
    echo "◦ Tentative de correction des dépendances..."
    apt-get install -f -y >/dev/null 2>&1
    echo "  ↦ Correction appliquée"
fi

# Vérifier que mosquitto est bien installé
if ! command -v mosquitto >/dev/null 2>&1; then
    echo "  ↦ Mosquitto n'est pas installé correctement ✗"
    log_error "Mosquitto non trouvé après installation"
    exit 1
fi

echo "  ↦ Mosquitto installé ✓"
log_info "Mosquitto installé avec succès"

send_progress 50 "Paquets installés"
echo ""
sleep 2

# ÉTAPE 3 : Configuration système
echo "========================================================================"
echo "ÉTAPE 3 : CONFIGURATION SYSTÈME"
echo "========================================================================"
echo ""

send_progress 60 "Configuration du système..."

# Créer l'utilisateur système mosquitto si nécessaire
echo "◦ Vérification de l'utilisateur système..."
if ! id mosquitto >/dev/null 2>&1; then
    echo "  ↦ Création de l'utilisateur système mosquitto..."
    useradd --system --no-create-home --shell /usr/sbin/nologin mosquitto
    echo "  ↦ Utilisateur système créé ✓"
    log_info "Utilisateur système mosquitto créé"
else
    echo "  ↦ Utilisateur système existant ✓"
fi

# Créer les répertoires nécessaires
echo ""
echo "◦ Création des répertoires..."
mkdir -p /var/lib/mosquitto /var/log/mosquitto /var/run/mosquitto
chown -R mosquitto:mosquitto /var/lib/mosquitto /var/log/mosquitto /var/run/mosquitto
chmod 755 /var/lib/mosquitto /var/log/mosquitto /var/run/mosquitto
echo "  ↦ Répertoires créés et permissions appliquées ✓"
log_info "Répertoires Mosquitto créés"

# Mettre à jour le cache des bibliothèques
echo ""
echo "◦ Mise à jour du cache des bibliothèques..."
ldconfig
echo "  ↦ Cache des bibliothèques mis à jour ✓"
log_info "ldconfig exécuté"

send_progress 70 "Système configuré"
echo ""
sleep 2

# ÉTAPE 4 : Configuration Mosquitto
echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 75 "Configuration de Mosquitto..."

# Créer le fichier de mots de passe
echo "◦ Création de l'utilisateur MQTT..."
rm -f "$MQTT_CONFIG_DIR/passwords"
log_command "/usr/bin/mosquitto_passwd -b -c '$MQTT_CONFIG_DIR/passwords' '$MQTT_USER' '$MQTT_PASS'" "Création utilisateur MQTT"
chmod 600 "$MQTT_CONFIG_DIR/passwords"
chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
echo "  ↦ Utilisateur '$MQTT_USER' créé ✓"
log_info "Utilisateur MQTT créé: $MQTT_USER"

# IMPORTANT : Créer la configuration avec topics système activés
echo ""
echo "◦ Création du fichier de configuration avec statistiques..."

# Sauvegarder l'ancienne configuration si elle existe
if [ -f "$MQTT_CONFIG_DIR/mosquitto.conf" ]; then
    cp "$MQTT_CONFIG_DIR/mosquitto.conf" "$MQTT_CONFIG_DIR/mosquitto.conf.backup_$(date +%Y%m%d_%H%M%S)"
    log_info "Ancienne configuration sauvegardée"
fi

# Créer la configuration avec topics système $SYS activés
cat > "$MQTT_CONFIG_DIR/mosquitto.conf" << EOF
# Configuration Mosquitto MaxLink - Avec statistiques système
allow_anonymous false
password_file /etc/mosquitto/passwords

# Listener MQTT standard sur port $MQTT_PORT
listener $MQTT_PORT

# Listener WebSocket sur port $MQTT_WEBSOCKET_PORT
listener $MQTT_WEBSOCKET_PORT
protocol websockets

# =======================================
# CONFIGURATION DES TOPICS SYSTÈME ($SYS)
# =======================================

# Activer les topics système
sys_interval 10

# Autoriser l'accès aux topics système pour l'utilisateur authentifié
# Les topics $SYS sont en lecture seule par défaut

# Configuration ACL pour permettre la lecture des topics système
# L'utilisateur mosquitto peut lire tous les topics système et publier/lire sur tous les autres
acl_file /etc/mosquitto/acl

# Logging pour debug (optionnel)
log_dest file /var/log/mosquitto/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
EOF

echo "  ↦ Configuration créée avec statistiques activées ✓"
log_success "Configuration Mosquitto créée avec topics système"

# Créer le fichier ACL pour autoriser la lecture des topics $SYS
echo ""
echo "◦ Configuration des permissions ACL..."
cat > "$MQTT_CONFIG_DIR/acl" << EOF
# ACL pour MaxLink MQTT
# Format: user username
#         topic [read|write|readwrite] topic

# L'utilisateur mosquitto a accès complet
user $MQTT_USER
topic readwrite #

# Tous les utilisateurs authentifiés peuvent lire les topics système
pattern read \$SYS/#
EOF

chmod 644 "$MQTT_CONFIG_DIR/acl"
chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/acl"
echo "  ↦ Permissions ACL configurées ✓"
log_info "Fichier ACL créé pour autoriser la lecture des topics système"

# Afficher la configuration pour vérification
echo ""
echo "◦ Configuration appliquée :"
echo "  ----------------------------------------"
cat "$MQTT_CONFIG_DIR/mosquitto.conf" | sed 's/^/  | /'
echo "  ----------------------------------------"

# Permissions sur le fichier de configuration
chmod 644 "$MQTT_CONFIG_DIR/mosquitto.conf"
chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/mosquitto.conf"

send_progress 85 "Configuration terminée"
echo ""
sleep 2

# ÉTAPE 5 : Démarrage du service
echo "========================================================================"
echo "ÉTAPE 5 : DÉMARRAGE DU SERVICE"
echo "========================================================================"
echo ""

send_progress 90 "Démarrage du service..."

# Créer un override systemd pour le delay de démarrage
echo "◦ Configuration du délai de démarrage..."
mkdir -p /etc/systemd/system/mosquitto.service.d/
cat > /etc/systemd/system/mosquitto.service.d/startup-delay.conf << EOF
[Service]
# Delay de démarrage pour attendre la stabilisation du réseau
ExecStartPre=/bin/sleep $STARTUP_DELAY_MOSQUITTO
EOF
echo "  ↦ Délai de démarrage configuré (${STARTUP_DELAY_MOSQUITTO}s) ✓"
log_info "Delay de démarrage Mosquitto configuré: ${STARTUP_DELAY_MOSQUITTO}s"

# Recharger systemd pour prendre en compte l'override
systemctl daemon-reload

# Activer le service au démarrage
echo ""
echo "◦ Activation du service au démarrage..."
log_command "systemctl enable mosquitto >/dev/null 2>&1" "Activation au démarrage"
echo "  ↦ Service activé ✓"

# Démarrer le service
echo ""
echo "◦ Démarrage de Mosquitto..."
if log_command "systemctl start mosquitto" "Démarrage Mosquitto"; then
    echo "  ↦ Mosquitto démarré ✓"
    log_success "Mosquitto démarré avec succès"
    
    # Attendre que le service soit complètement démarré
    wait_silently 3
    
    # Vérifier que le service est actif
    if systemctl is-active --quiet mosquitto; then
        echo "  ↦ Service actif et fonctionnel ✓"
        log_info "Service Mosquitto actif"
    else
        echo "  ↦ Le service n'est pas actif ✗"
        log_error "Service Mosquitto non actif après démarrage"
        journalctl -u mosquitto -n 20 --no-pager
        exit 1
    fi
else
    echo "  ↦ Erreur au démarrage ✗"
    log_error "Mosquitto n'a pas pu démarrer"
    echo ""
    echo "Dernières lignes du journal :"
    journalctl -u mosquitto -n 20 --no-pager
    exit 1
fi

send_progress 95 "Service démarré"
echo ""
sleep 2

# ÉTAPE 6 : Tests de connexion
echo "========================================================================"
echo "ÉTAPE 6 : TESTS DE CONNEXION"
echo "========================================================================"
echo ""

send_progress 98 "Tests de connexion..."

# Test MQTT standard
echo "◦ Test de connexion MQTT (port $MQTT_PORT)..."
if mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/installation" -m "MaxLink MQTT OK" 2>/dev/null; then
    echo "  ↦ Connexion MQTT réussie ✓"
    log_success "Test de connexion MQTT réussi"
else
    echo "  ↦ Connexion MQTT échouée ✗"
    log_error "Test de connexion MQTT échoué"
    echo ""
    echo "Vérification des logs :"
    journalctl -u mosquitto -n 10 --no-pager
fi

# Test WebSocket
echo ""
echo "◦ Test du port WebSocket ($MQTT_WEBSOCKET_PORT)..."
if nc -z localhost $MQTT_WEBSOCKET_PORT 2>/dev/null; then
    echo "  ↦ Port WebSocket accessible ✓"
    log_success "Port WebSocket accessible"
else
    echo "  ↦ Port WebSocket non accessible ⚠"
    log_warn "Port WebSocket non accessible immédiatement"
    echo "  ↦ Le port peut prendre quelques secondes pour s'ouvrir"
fi

# Test des topics système
echo ""
echo "◦ Test des topics système ($SYS)..."
# Essayer de lire un topic système
if timeout 2 mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t '$SYS/broker/version' -C 1 2>/dev/null; then
    echo "  ↦ Topics système accessibles ✓"
    log_success "Topics système $SYS accessibles"
    
    # Afficher quelques statistiques système
    echo ""
    echo "◦ Aperçu des statistiques système disponibles :"
    echo "  ↦ Version : $(mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t '$SYS/broker/version' -C 1 2>/dev/null || echo 'N/A')"
    echo "  ↦ Uptime : $(mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t '$SYS/broker/uptime' -C 1 2>/dev/null || echo 'N/A')"
else
    echo "  ↦ Topics système non accessibles ⚠"
    log_warn "Topics système non accessibles - vérifier la configuration"
fi

# Afficher les ports en écoute
echo ""
echo "◦ Ports en écoute :"
netstat -tlnp 2>/dev/null | grep mosquitto || ss -tlnp 2>/dev/null | grep mosquitto || echo "  ↦ Impossible de vérifier les ports (outils non disponibles)"

send_progress 100 "Installation terminée"
echo ""
sleep 2

# RÉSUMÉ FINAL
echo "========================================================================"
echo "INSTALLATION TERMINÉE AVEC SUCCÈS !"
echo "========================================================================"
echo ""
echo "◦ Broker MQTT Mosquitto installé et configuré"
echo "◦ Topics système ($SYS) activés pour les statistiques"
echo "◦ Délai de démarrage : ${STARTUP_DELAY_MOSQUITTO}s"
echo ""
echo "◦ Informations de connexion :"
echo "  • Serveur      : localhost (ou IP du Raspberry Pi)"
echo "  • Port MQTT    : $MQTT_PORT"
echo "  • Port WebSocket : $MQTT_WEBSOCKET_PORT"
echo "  • Utilisateur  : $MQTT_USER"
echo "  • Mot de passe : $MQTT_PASS"
echo ""
echo "◦ Topics système disponibles :"
echo "  • \$SYS/broker/clients/connected    : Clients connectés"
echo "  • \$SYS/broker/messages/received   : Messages reçus"
echo "  • \$SYS/broker/messages/sent       : Messages envoyés"
echo "  • \$SYS/broker/uptime             : Temps de fonctionnement"
echo "  • \$SYS/broker/load/+             : Charge du broker"
echo ""
echo "◦ Commandes utiles :"
echo "  • État : systemctl status mosquitto"
echo "  • Logs : journalctl -u mosquitto -f"
echo "  • Test : mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t '#' -v"
echo "  • Stats: mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t '\$SYS/#' -v"
echo ""
echo "◦ Prochaine étape : Installer les widgets avec mqtt_wgs_install.sh"
echo ""

log_success "Installation MQTT Broker terminée avec statistiques système activées"
log_info "Configuration: $MQTT_USER/$MQTT_PASS sur ports $MQTT_PORT et $MQTT_WEBSOCKET_PORT"

echo ""
echo "  ↦ Redémarrage du système prévu dans 15 secondes..."
echo ""

log_info "Redémarrage du système prévu dans 15 secondes"

# Pause de 30 secondes
sleep 15

# Redémarrer
log_info "Redémarrage du système"
reboot