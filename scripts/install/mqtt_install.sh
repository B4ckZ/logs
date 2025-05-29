#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT BROKER (VERSION OPTIMISÉE)
# Utilise le cache local de paquets - Installation ultra rapide !
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des modules
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"
source "$SCRIPT_DIR/../common/packages.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation MQTT Broker (cache local)" "install"

# Variables MQTT
MQTT_USER="${MQTT_USER:-maxlink}"
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

log_info "========== DÉBUT DE L'INSTALLATION MQTT BROKER (OPTIMISÉE) =========="

echo ""
echo "========================================================================"
echo "INSTALLATION DU BROKER MQTT (MOSQUITTO)"
echo "========================================================================"
echo ""

send_progress 5 "Initialisation..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
log_info "Privilèges root confirmés"

# ÉTAPE 1 : Vérifications
echo "ÉTAPE 1 : VÉRIFICATIONS"
echo "========================================================================"
echo ""

send_progress 10 "Vérifications..."

# Vérifier le cache des paquets
echo "◦ Vérification du cache des paquets..."
if [ ! -d "$PACKAGE_CACHE_DIR" ] || [ ! -f "$PACKAGE_METADATA_FILE" ]; then
    echo "  ↦ Cache des paquets non trouvé ✗"
    echo ""
    echo "Veuillez d'abord exécuter update_install.sh pour télécharger les paquets"
    log_error "Cache des paquets non trouvé"
    exit 1
fi
echo "  ↦ Cache des paquets disponible ✓"
log_info "Cache des paquets trouvé"

# Vérifier si Mosquitto est déjà installé
echo ""
echo "◦ Vérification de Mosquitto..."
if dpkg -l mosquitto >/dev/null 2>&1; then
    echo "  ↦ Mosquitto déjà installé ✓"
    log_info "Mosquitto déjà présent"
    
    # Arrêter le service pour reconfiguration
    log_command "systemctl stop mosquitto >/dev/null 2>&1" "Arrêt Mosquitto"
    echo "  ↦ Service arrêté pour reconfiguration"
else
    echo "  ↦ Mosquitto non installé"
    log_info "Installation de Mosquitto nécessaire"
fi

send_progress 20 "Vérifications terminées"

# ÉTAPE 2 : Installation depuis le cache
echo ""
echo "ÉTAPE 2 : INSTALLATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 30 "Installation de Mosquitto..."

echo "◦ Installation de Mosquitto depuis le cache local..."
log_info "Installation des paquets MQTT depuis le cache"

# Installer les paquets MQTT depuis le cache
if install_packages_by_category "mqtt"; then
    echo "  ↦ Mosquitto installé avec succès ✓"
    log_success "Mosquitto installé depuis le cache"
else
    echo "  ↦ Erreur lors de l'installation depuis le cache ⚠"
    log_warn "Installation depuis le cache échouée"
    
    # Tentative de fallback
    echo ""
    echo "◦ Tentative d'installation alternative..."
    if apt-get install -y mosquitto mosquitto-clients >/dev/null 2>&1; then
        echo "  ↦ Mosquitto installé via apt ✓"
        log_success "Mosquitto installé via apt (fallback)"
    else
        echo "  ↦ Installation impossible ✗"
        log_error "Impossible d'installer Mosquitto"
        exit 1
    fi
fi

send_progress 50 "Mosquitto installé"

# ÉTAPE 3 : Configuration
echo ""
echo "ÉTAPE 3 : CONFIGURATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 60 "Configuration de Mosquitto..."

echo "◦ Configuration de l'authentification..."
log_info "Configuration de l'authentification MQTT"

# Créer le fichier de mots de passe
rm -f "$MQTT_CONFIG_DIR/passwords"
log_command "/usr/bin/mosquitto_passwd -b -c '$MQTT_CONFIG_DIR/passwords' '$MQTT_USER' '$MQTT_PASS'" "Création utilisateur MQTT"
chmod 600 "$MQTT_CONFIG_DIR/passwords"
chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
echo "  ↦ Utilisateur '$MQTT_USER' créé ✓"
log_info "Utilisateur MQTT créé: $MQTT_USER"

# Configuration principale
echo ""
echo "◦ Création de la configuration..."
log_info "Création de la configuration Mosquitto"

cat > "$MQTT_CONFIG_DIR/mosquitto.conf" << EOF
# Configuration Mosquitto pour MaxLink
# Généré le $(date)

# Fichiers système
pid_file /var/run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log

# Authentification
allow_anonymous false
password_file $MQTT_CONFIG_DIR/passwords

# Listener standard MQTT
listener $MQTT_PORT
protocol mqtt

# Listener WebSocket pour le dashboard
listener $MQTT_WEBSOCKET_PORT
protocol websockets

# Configuration des logs
log_type error
log_type warning
log_type notice
log_type information
connection_messages true
log_timestamp true

# Limites de connexion
max_connections -1
max_inflight_messages 20
max_queued_messages 100

# Keep alive
keepalive_interval 60
EOF

echo "  ↦ Configuration créée ✓"
echo "  ↦ Port MQTT: $MQTT_PORT"
echo "  ↦ Port WebSocket: $MQTT_WEBSOCKET_PORT"
log_success "Configuration Mosquitto créée"
log_info "Ports configurés - MQTT: $MQTT_PORT, WebSocket: $MQTT_WEBSOCKET_PORT"

send_progress 80 "Configuration terminée"

# ÉTAPE 4 : Démarrage du service
echo ""
echo "ÉTAPE 4 : DÉMARRAGE DU SERVICE"
echo "========================================================================"
echo ""

send_progress 85 "Démarrage du service..."

echo "◦ Activation du service..."
log_command "systemctl enable mosquitto >/dev/null 2>&1" "Activation au démarrage"
echo "  ↦ Service activé au démarrage ✓"

echo ""
echo "◦ Démarrage de Mosquitto..."
if log_command "systemctl start mosquitto" "Démarrage Mosquitto"; then
    echo "  ↦ Mosquitto démarré ✓"
    log_success "Mosquitto démarré avec succès"
else
    echo "  ↦ Erreur au démarrage ✗"
    log_error "Mosquitto n'a pas pu démarrer"
    
    # Afficher les logs pour debug
    echo ""
    echo "Dernières lignes du journal :"
    journalctl -u mosquitto -n 20 --no-pager
    log_command "journalctl -u mosquitto -n 20 --no-pager" "Journal Mosquitto"
    
    exit 1
fi

# Attendre que le service soit complètement démarré
wait_silently 3

# Test de connexion
echo ""
echo "◦ Test de connexion..."
if mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/broker/install" -m "Installation réussie" 2>/dev/null; then
    echo "  ↦ Connexion réussie ✓"
    log_success "Test de connexion MQTT réussi"
else
    echo "  ↦ Connexion échouée ✗"
    log_error "Test de connexion MQTT échoué"
fi

send_progress 95 "Tests terminés"

# ÉTAPE 5 : Test WebSocket
echo ""
echo "ÉTAPE 5 : VÉRIFICATION WEBSOCKET"
echo "========================================================================"
echo ""

echo "◦ Test du port WebSocket..."
if nc -z localhost $MQTT_WEBSOCKET_PORT 2>/dev/null; then
    echo "  ↦ Port WebSocket ($MQTT_WEBSOCKET_PORT) accessible ✓"
    log_success "Port WebSocket accessible"
else
    echo "  ↦ Port WebSocket non accessible ⚠"
    log_warn "Port WebSocket non accessible"
fi

send_progress 100 "Installation terminée"

# RÉSUMÉ
echo ""
echo "========================================================================"
echo "INSTALLATION TERMINÉE"
echo "========================================================================"
echo ""
echo "◦ Broker MQTT installé et configuré avec succès !"
echo ""
echo "Informations de connexion :"
echo "  • Hôte        : localhost (ou l'IP du Raspberry Pi)"
echo "  • Port MQTT   : $MQTT_PORT"
echo "  • Port WebSocket : $MQTT_WEBSOCKET_PORT"
echo "  • Utilisateur : $MQTT_USER"
echo "  • Mot de passe: $MQTT_PASS"
echo ""
echo "Commandes utiles :"
echo "  • État du service : systemctl status mosquitto"
echo "  • Logs : journalctl -u mosquitto -f"
echo "  • Test publication : mosquitto_pub -h localhost -u $MQTT_USER -P $MQTT_PASS -t 'test' -m 'Hello'"
echo "  • Test souscription : mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t '#' -v"
echo ""
echo "Prochaine étape : Installer les widgets avec MQTT WGS"
echo ""

log_success "Installation MQTT Broker terminée avec succès"
log_info "Configuration finale:"
log_info "  - Hôte: localhost"
log_info "  - Port MQTT: $MQTT_PORT"
log_info "  - Port WebSocket: $MQTT_WEBSOCKET_PORT"
log_info "  - Utilisateur: $MQTT_USER"

exit 0