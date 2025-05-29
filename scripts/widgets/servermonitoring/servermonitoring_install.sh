#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - SCRIPT D'INSTALLATION
# Version avec système de logging unifié
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIDGET_DIR="$SCRIPT_DIR"
WIDGETS_DIR="$(dirname "$WIDGET_DIR")"
SCRIPTS_DIR="$(dirname "$WIDGETS_DIR")"
BASE_DIR="$(dirname "$SCRIPTS_DIR")"

# Source des variables et du logging unifié
source "$BASE_DIR/scripts/common/variables.sh"
source "$BASE_DIR/scripts/common/logging.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging - catégorie "widgets" car c'est un widget
init_logging "Installation widget Server Monitoring" "widgets"

# Informations du widget
WIDGET_ID="servermonitoring"
WIDGET_NAME="Server Monitoring"
WIDGET_VERSION="1.0.0"

# Fichiers et chemins
CONFIG_FILE="$WIDGET_DIR/servermonitoring_widget.json"
COLLECTOR_SCRIPT="$WIDGET_DIR/servermonitoring_collector.py"
SERVICE_NAME="maxlink-widget-servermonitoring"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Fichier de tracking
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"
mkdir -p "$(dirname "$WIDGETS_TRACKING")"

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Vérifier si MQTT est installé et actif
check_mqtt_broker() {
    log_info "Vérification du broker MQTT"
    
    # Vérifier si Mosquitto est installé
    if ! dpkg -l mosquitto >/dev/null 2>&1; then
        log_error "Mosquitto n'est pas installé"
        return 1
    fi
    
    # Vérifier si le service est actif
    if ! systemctl is-active --quiet mosquitto; then
        log_warn "Mosquitto n'est pas actif, tentative de démarrage"
        if systemctl start mosquitto; then
            log_success "Mosquitto démarré"
        else
            log_error "Impossible de démarrer Mosquitto"
            return 1
        fi
    else
        log_success "Mosquitto est actif"
    fi
    
    # Tester la connexion
    if command -v mosquitto_pub >/dev/null 2>&1; then
        if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/widget/install" -m "test" 2>/dev/null; then
            log_success "Connexion MQTT fonctionnelle"
            return 0
        else
            log_error "Impossible de se connecter au broker MQTT"
            return 1
        fi
    else
        log_warn "mosquitto_pub non disponible, impossible de tester la connexion"
        return 0
    fi
}

# Vérifier les dépendances Python
check_python_dependencies() {
    log_info "Vérification des dépendances Python"
    
    # Vérifier Python3
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "Python3 n'est pas installé"
        return 1
    fi
    
    local python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    log_info "Python version: $python_version"
    
    # Vérifier les modules
    local missing_modules=()
    
    if ! python3 -c "import psutil" 2>/dev/null; then
        missing_modules+=("psutil")
    fi
    
    if ! python3 -c "import paho.mqtt.client" 2>/dev/null; then
        missing_modules+=("paho-mqtt")
    fi
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log_warn "Modules Python manquants: ${missing_modules[*]}"
        return 1
    else
        log_success "Toutes les dépendances Python sont présentes"
        return 0
    fi
}

# Installer les dépendances manquantes
install_dependencies() {
    log_info "Installation des dépendances"
    
    # Se connecter au WiFi si nécessaire
    local wifi_connected=false
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "◦ Connexion au réseau WiFi pour télécharger les dépendances..."
        log_info "Connexion WiFi nécessaire pour les dépendances"
        
        # Désactiver le mode AP temporairement
        if nmcli con show --active | grep -q "$AP_SSID"; then
            log_command "nmcli con down '$AP_SSID' >/dev/null 2>&1" "Désactivation AP"
            log_info "Mode AP désactivé temporairement"
        fi
        
        # Se connecter au WiFi
        if log_command "nmcli device wifi connect '$WIFI_SSID' password '$WIFI_PASSWORD' >/dev/null 2>&1" "Connexion WiFi"; then
            wifi_connected=true
            log_success "Connecté au WiFi"
            sleep 5
        else
            log_error "Impossible de se connecter au WiFi"
            return 1
        fi
    fi
    
    # Installer les paquets Python
    echo "◦ Installation des paquets Python..."
    log_info "Installation python3-psutil et python3-paho-mqtt"
    
    if log_command "apt-get update -qq" "Mise à jour des dépôts" && \
       log_command "apt-get install -y python3-psutil python3-paho-mqtt" "Installation paquets Python"; then
        log_success "Paquets Python installés"
    else
        log_error "Erreur lors de l'installation des paquets"
        return 1
    fi
    
    # Se déconnecter du WiFi si on s'est connecté
    if [ "$wifi_connected" = true ]; then
        log_command "nmcli connection down '$WIFI_SSID' >/dev/null 2>&1" "Déconnexion WiFi"
        log_command "nmcli connection delete '$WIFI_SSID' >/dev/null 2>&1" "Suppression profil WiFi"
        log_info "Déconnecté du WiFi"
        
        # Réactiver le mode AP
        log_command "nmcli con up '$AP_SSID' >/dev/null 2>&1" "Réactivation AP"
        log_info "Mode AP réactivé"
    fi
    
    return 0
}

# Créer le service systemd
create_systemd_service() {
    log_info "Création du service systemd"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=MaxLink Server Monitoring Widget Collector
After=mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $COLLECTOR_SCRIPT
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

# Environnement
Environment="PYTHONUNBUFFERED=1"

# Limites
LimitNOFILE=4096

# Sécurité
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    log_success "Service systemd créé: $SERVICE_FILE"
}

# Enregistrer le widget comme installé
register_widget_installation() {
    log_info "Enregistrement du widget dans le tracking"
    
    # Créer le fichier s'il n'existe pas
    if [ ! -f "$WIDGETS_TRACKING" ]; then
        echo "{}" > "$WIDGETS_TRACKING"
    fi
    
    # Ajouter l'entrée via Python
    python3 -c "
import json
from datetime import datetime

with open('$WIDGETS_TRACKING', 'r') as f:
    widgets = json.load(f)

widgets['$WIDGET_ID'] = {
    'name': '$WIDGET_NAME',
    'version': '$WIDGET_VERSION',
    'installed_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'status': 'active',
    'service': '$SERVICE_NAME',
    'config_file': '$CONFIG_FILE'
}

with open('$WIDGETS_TRACKING', 'w') as f:
    json.dump(widgets, f, indent=2)
"
    
    log_success "Widget enregistré dans le tracking"
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION WIDGET SERVER MONITORING =========="
log_info "Version: $WIDGET_VERSION"
log_info "Répertoire: $WIDGET_DIR"

echo ""
echo "=== ÉTAPE 1: VÉRIFICATIONS PRÉALABLES ==="
echo ""

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Ce script doit être exécuté avec des privilèges root ✗"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
echo "  ↦ Privilèges root confirmés ✓"
log_info "Privilèges root confirmés"

# Vérifier l'existence de servermonitoring_widget.json
if [ ! -f "$CONFIG_FILE" ]; then
    echo "  ↦ Fichier de configuration non trouvé ✗"
    log_error "Fichier manquant: $CONFIG_FILE"
    exit 1
fi
echo "  ↦ Fichier servermonitoring_widget.json trouvé ✓"
log_info "Fichier de configuration trouvé"

# Vérifier MQTT
echo ""
echo "◦ Vérification du broker MQTT..."
if ! check_mqtt_broker; then
    echo "  ↦ Le broker MQTT doit être installé et actif ✗"
    echo ""
    echo "Veuillez d'abord installer MQTT avec le script mqtt_install.sh"
    exit 1
fi
echo "  ↦ Broker MQTT fonctionnel ✓"

echo ""
echo "=== ÉTAPE 2: GESTION DES DÉPENDANCES ==="
echo ""

echo "◦ Vérification des dépendances Python..."
if ! check_python_dependencies; then
    echo "  ↦ Installation des dépendances nécessaires..."
    if ! install_dependencies; then
        echo "  ↦ Impossible d'installer les dépendances ✗"
        log_error "Échec de l'installation des dépendances"
        exit 1
    fi
    
    # Revérifier après installation
    if ! check_python_dependencies; then
        echo "  ↦ Les dépendances n'ont pas pu être installées correctement ✗"
        log_error "Dépendances toujours manquantes après installation"
        exit 1
    fi
fi
echo "  ↦ Dépendances Python OK ✓"

echo ""
echo "=== ÉTAPE 3: CRÉATION DES COMPOSANTS ==="
echo ""

# Le script collecteur existe déjà
if [ ! -f "$COLLECTOR_SCRIPT" ]; then
    echo "  ↦ Script collecteur manquant ✗"
    log_error "Script manquant: $COLLECTOR_SCRIPT"
    exit 1
fi
chmod +x "$COLLECTOR_SCRIPT"
echo "  ↦ Script collecteur configuré ✓"
log_info "Script collecteur: $COLLECTOR_SCRIPT"

# Créer le service systemd
echo "◦ Création du service systemd..."
create_systemd_service
echo "  ↦ Service systemd créé ✓"

echo ""
echo "=== ÉTAPE 4: ACTIVATION DU SERVICE ==="
echo ""

# Recharger systemd
log_command "systemctl daemon-reload" "Rechargement systemd"
echo "  ↦ Configuration systemd rechargée ✓"

# Activer le service
echo "◦ Activation du service..."
if log_command "systemctl enable '$SERVICE_NAME'" "Activation au démarrage"; then
    echo "  ↦ Service activé au démarrage ✓"
else
    echo "  ↦ Impossible d'activer le service ✗"
    log_error "Échec de l'activation du service"
    exit 1
fi

# Démarrer le service
echo "◦ Démarrage du service..."
if log_command "systemctl start '$SERVICE_NAME'" "Démarrage du service"; then
    echo "  ↦ Service démarré ✓"
    log_success "Service démarré avec succès"
else
    echo "  ↦ Impossible de démarrer le service ✗"
    log_error "Échec du démarrage du service"
    exit 1
fi

# Vérifier le statut
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "  ↦ Service actif et fonctionnel ✓"
    log_success "Service actif et fonctionnel"
else
    echo "  ↦ Le service ne fonctionne pas correctement ✗"
    log_error "Service non fonctionnel"
    echo ""
    echo "Voir les logs avec: journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi

echo ""
echo "=== ÉTAPE 5: FINALISATION ==="
echo ""

# Enregistrer l'installation
register_widget_installation

# Test rapide
echo "◦ Test de publication MQTT..."
if mosquitto_sub -h localhost -p 1883 -u maxlink -P mqtt -t "rpi/system/cpu/+" -C 1 -W 5 >/dev/null 2>&1; then
    echo "  ↦ Messages MQTT reçus correctement ✓"
    log_success "Test MQTT réussi"
else
    echo "  ↦ Aucun message reçu (le collecteur peut prendre quelques secondes) ⚠"
    log_warn "Aucun message MQTT reçu immédiatement"
fi

# Résumé
echo ""
echo "=========================================="
echo "Installation terminée avec succès !"
echo "=========================================="
echo ""
echo "Widget: $WIDGET_NAME v$WIDGET_VERSION"
echo "Service: $SERVICE_NAME"
echo "Status: $(systemctl is-active $SERVICE_NAME)"
echo ""
echo "Commandes utiles:"
echo "  • Logs du service : journalctl -u $SERVICE_NAME -f"
echo "  • Logs du collecteur : tail -f $LOG_WIDGETS/servermonitoring_collector.log"
echo "  • Test MQTT : mosquitto_sub -h localhost -u maxlink -P mqtt -t 'rpi/system/+/+' -v"
echo "  • Arrêter : systemctl stop $SERVICE_NAME"
echo "  • Redémarrer : systemctl restart $SERVICE_NAME"
echo ""
echo "Le widget envoie maintenant des données au dashboard !"
echo ""

log_success "Installation widget Server Monitoring terminée avec succès"
log_info "Service: $SERVICE_NAME actif"

exit 0