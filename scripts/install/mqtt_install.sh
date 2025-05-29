#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT BROKER (BKR)
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
init_logging "Installation MQTT Broker (Mosquitto)" "install"

# Variables MQTT
MQTT_USER="${MQTT_USER:-maxlink}"
MQTT_PASS="${MQTT_PASS:-mqtt}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_WEBSOCKET_PORT="${MQTT_WEBSOCKET_PORT:-9001}"
MQTT_CONFIG_DIR="/etc/mosquitto"

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

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION MQTT BROKER =========="

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

# ÉTAPE 1 : Préparation
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 10 "Préparation du système..."

echo "◦ Préparation du système..."
echo "  ↦ Initialisation..."
log_info "Préparation du système - attente 2s"
wait_silently 2

# Vérifier et désactiver le mode AP si actif
if nmcli con show --active | grep -q "$AP_SSID"; then
    AP_WAS_ACTIVE=true
    log_info "Mode AP actif détecté - désactivation temporaire"
    log_command "nmcli con down '$AP_SSID' >/dev/null 2>&1" "Désactivation AP"
    echo "  ↦ Mode AP désactivé temporairement ✓"
fi

send_progress 15 "Système préparé"

# ÉTAPE 2 : Vérification de Mosquitto
echo ""
echo "ÉTAPE 2 : VÉRIFICATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 20 "Vérification de Mosquitto..."

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
    echo ""
    echo "◦ Connexion au réseau WiFi pour l'installation..."
    
    # Se connecter au WiFi
    if log_command "nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASSWORD' >/dev/null 2>&1" "Connexion WiFi"; then
        wait_silently 5
        
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "  ↦ Connecté au WiFi ✓"
            log_success "Connexion WiFi établie"
            
            send_progress 30 "Téléchargement de Mosquitto..."
            
            echo ""
            echo "◦ Installation de Mosquitto..."
            echo "  ↦ Mise à jour des paquets..."
            log_command "apt-get update -qq" "Mise à jour des dépôts"
            
            echo "  ↦ Installation en cours..."
            if log_command "apt-get install -y mosquitto mosquitto-clients >/dev/null 2>&1" "Installation Mosquitto"; then
                echo "  ↦ Mosquitto installé ✓"
                log_success "Mosquitto installé avec succès"
            else
                echo "  ↦ Erreur lors de l'installation ✗"
                log_error "Échec installation Mosquitto"
                
                # Déconnexion WiFi et réactivation AP
                nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
                nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
                if [ "$AP_WAS_ACTIVE" = true ]; then
                    nmcli con up "$AP_SSID" >/dev/null 2>&1
                fi
                exit 1
            fi
            
            # Déconnexion WiFi
            echo ""
            echo "◦ Déconnexion du WiFi..."
            log_command "nmcli connection down '$WIFI_SSID' >/dev/null 2>&1" "Déconnexion WiFi"
            log_command "nmcli connection delete '$WIFI_SSID' >/dev/null 2>&1" "Suppression profil WiFi"
            echo "  ↦ WiFi déconnecté ✓"
        else
            echo "  ↦ Impossible de se connecter au WiFi ✗"
            log_error "Pas de connectivité Internet"
            exit 1
        fi
    else
        echo "  ↦ Échec de la connexion WiFi ✗"
        log_error "Impossible de se connecter au WiFi"
        exit 1
    fi
fi

send_progress 50 "Mosquitto prêt"

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

# Réactiver le mode AP si nécessaire
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    log_info "Réactivation du mode AP"
    log_command "nmcli con up '$AP_SSID' >/dev/null 2>&1" "Activation AP"
    wait_silently 3
    echo "  ↦ Mode AP réactivé ✓"
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