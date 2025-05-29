#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - SCRIPT D'INSTALLATION
# Widget pour collecter et envoyer les métriques système via MQTT
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIDGET_DIR="$SCRIPT_DIR"
WIDGETS_DIR="$(dirname "$WIDGET_DIR")"
SCRIPTS_DIR="$(dirname "$WIDGETS_DIR")"
BASE_DIR="$(dirname "$SCRIPTS_DIR")"

# Source des variables centralisées
source "$BASE_DIR/scripts/common/variables.sh"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Informations du widget
WIDGET_ID="servermonitoring"
WIDGET_NAME="Server Monitoring"
WIDGET_VERSION="1.0.0"

# Fichiers et chemins - MISE À JOUR AVEC LE NOUVEAU NOMMAGE
CONFIG_FILE="$WIDGET_DIR/servermonitoring_widget.json"
COLLECTOR_SCRIPT="$WIDGET_DIR/servermonitoring_collector.py"
SERVICE_NAME="maxlink-widget-servermonitoring"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Logs - Nouveau système simplifié
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/servermonitoring_install.log"
mkdir -p "$LOG_DIR"

# Fichier de tracking
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"
mkdir -p "$(dirname "$WIDGETS_TRACKING")"

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Logger dans le fichier seulement
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Logger et afficher
log_and_show() {
    local level=$1
    local message=$2
    echo "$message"
    log "$level" "$message"
}

log_info() { log_and_show "INFO" "$1"; }
log_error() { log_and_show "ERROR" "$1"; }
log_success() { log_and_show "SUCCESS" "$1"; }
log_warning() { log_and_show "WARNING" "$1"; }

# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Vérifier si MQTT est installé et actif
check_mqtt_broker() {
    log "INFO" "Vérification du broker MQTT..."
    
    # Vérifier si Mosquitto est installé
    if ! dpkg -l mosquitto >/dev/null 2>&1; then
        log_error "Mosquitto n'est pas installé"
        return 1
    fi
    
    # Vérifier si le service est actif
    if ! systemctl is-active --quiet mosquitto; then
        log_warning "Mosquitto n'est pas actif, tentative de démarrage..."
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
        log_warning "mosquitto_pub non disponible, impossible de tester la connexion"
        return 0
    fi
}

# Vérifier les dépendances Python
check_python_dependencies() {
    log "INFO" "Vérification des dépendances Python..."
    
    # Vérifier Python3
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "Python3 n'est pas installé"
        return 1
    fi
    
    local python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    log "INFO" "Python version: $python_version"
    
    # Vérifier les modules
    local missing_modules=()
    
    if ! python3 -c "import psutil" 2>/dev/null; then
        missing_modules+=("psutil")
    fi
    
    if ! python3 -c "import paho.mqtt.client" 2>/dev/null; then
        missing_modules+=("paho-mqtt")
    fi
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log_warning "Modules Python manquants: ${missing_modules[*]}"
        return 1
    else
        log_success "Toutes les dépendances Python sont présentes"
        return 0
    fi
}

# Installer les dépendances manquantes
install_dependencies() {
    log "INFO" "Installation des dépendances..."
    
    # Se connecter au WiFi si nécessaire
    local wifi_connected=false
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_info "Connexion au réseau WiFi pour télécharger les dépendances..."
        
        # Désactiver le mode AP temporairement
        if nmcli con show --active | grep -q "$AP_SSID"; then
            nmcli con down "$AP_SSID" >/dev/null 2>&1
            log "INFO" "Mode AP désactivé temporairement"
        fi
        
        # Se connecter au WiFi
        if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
            wifi_connected=true
            log_success "Connecté au WiFi"
            sleep 5
        else
            log_error "Impossible de se connecter au WiFi"
            return 1
        fi
    fi
    
    # Installer les paquets Python
    log_info "Installation des paquets Python..."
    
    if apt-get update -qq && apt-get install -y python3-psutil python3-paho-mqtt; then
        log_success "Paquets Python installés"
    else
        log_error "Erreur lors de l'installation des paquets"
        return 1
    fi
    
    # Se déconnecter du WiFi si on s'est connecté
    if [ "$wifi_connected" = true ]; then
        nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
        nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
        log "INFO" "Déconnecté du WiFi"
        
        # Réactiver le mode AP
        nmcli con up "$AP_SSID" >/dev/null 2>&1
        log "INFO" "Mode AP réactivé"
    fi
    
    return 0
}

# Créer le service systemd
create_systemd_service() {
    log "INFO" "Création du service systemd..."
    
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

    log_success "Service systemd créé"
}

# Enregistrer le widget comme installé
register_widget_installation() {
    log "INFO" "Enregistrement du widget..."
    
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

# Header de début
{
    echo ""
    echo "$(printf '=%.0s' {1..80})"
    echo "DÉMARRAGE: servermonitoring_install"
    echo "Date: $(date)"
    echo "$(printf '=%.0s' {1..80})"
    echo ""
} >> "$LOG_FILE"

log "INFO" "Installation du widget: $WIDGET_NAME v$WIDGET_VERSION"
log "INFO" "Répertoire du widget: $WIDGET_DIR"

# Étape 1: Vérifications préalables
log_info ""
log_info "=== ÉTAPE 1: VÉRIFICATIONS PRÉALABLES ==="

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    log_error "Ce script doit être exécuté avec des privilèges root"
    exit 1
fi
log_success "Privilèges root confirmés"

# Vérifier l'existence de servermonitoring_widget.json
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Fichier de configuration servermonitoring_widget.json non trouvé"
    exit 1
fi
log_success "Fichier servermonitoring_widget.json trouvé"

# Vérifier MQTT
if ! check_mqtt_broker; then
    log_error "Le broker MQTT doit être installé et actif avant d'installer ce widget"
    exit 1
fi

# Étape 2: Dépendances
log_info ""
log_info "=== ÉTAPE 2: GESTION DES DÉPENDANCES ==="

if ! check_python_dependencies; then
    log_info "Installation des dépendances nécessaires..."
    if ! install_dependencies; then
        log_error "Impossible d'installer les dépendances"
        exit 1
    fi
    
    # Revérifier après installation
    if ! check_python_dependencies; then
        log_error "Les dépendances n'ont pas pu être installées correctement"
        exit 1
    fi
fi

# Étape 3: Création des composants
log_info ""
log_info "=== ÉTAPE 3: CRÉATION DES COMPOSANTS ==="

# Le script collecteur existe déjà, pas besoin de le créer
if [ ! -f "$COLLECTOR_SCRIPT" ]; then
    log_error "Script collecteur manquant: $COLLECTOR_SCRIPT"
    exit 1
fi
chmod +x "$COLLECTOR_SCRIPT"
log_success "Script collecteur configuré"

# Créer le service systemd
create_systemd_service

# Étape 4: Activation du service
log_info ""
log_info "=== ÉTAPE 4: ACTIVATION DU SERVICE ==="

# Recharger systemd
systemctl daemon-reload
log_success "Configuration systemd rechargée"

# Activer le service
if systemctl enable "$SERVICE_NAME"; then
    log_success "Service activé au démarrage"
else
    log_error "Impossible d'activer le service"
    exit 1
fi

# Démarrer le service
if systemctl start "$SERVICE_NAME"; then
    log_success "Service démarré"
else
    log_error "Impossible de démarrer le service"
    exit 1
fi

# Vérifier le statut
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service actif et fonctionnel"
else
    log_error "Le service ne fonctionne pas correctement"
    log "INFO" "Voir les logs: journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi

# Étape 5: Finalisation
log_info ""
log_info "=== ÉTAPE 5: FINALISATION ==="

# Enregistrer l'installation
register_widget_installation

# Test rapide
log_info "Test de publication MQTT..."
if mosquitto_sub -h localhost -p 1883 -u maxlink -P mqtt -t "rpi/system/cpu/+" -C 1 -W 5 >/dev/null 2>&1; then
    log_success "Messages MQTT reçus correctement"
else
    log_warning "Aucun message reçu, le collecteur peut prendre quelques secondes pour démarrer"
fi

# Résumé
log_info ""
log "INFO" "=========================================="
log_success "Installation terminée avec succès !"
log "INFO" "=========================================="
log "INFO" "Widget: $WIDGET_NAME v$WIDGET_VERSION"
log "INFO" "Service: $SERVICE_NAME"
log "INFO" "Status: $(systemctl is-active $SERVICE_NAME)"
log "INFO" ""
log "INFO" "Commandes utiles:"
log "INFO" "  - Voir les logs: journalctl -u $SERVICE_NAME -f"
log "INFO" "  - Voir les logs du collecteur: tail -f $LOG_DIR/servermonitoring.log"
log "INFO" "  - Tester: mosquitto_sub -h localhost -u maxlink -P mqtt -t 'rpi/system/+/+' -v"
log "INFO" "  - Arrêter: systemctl stop $SERVICE_NAME"
log "INFO" "  - Redémarrer: systemctl restart $SERVICE_NAME"
log "INFO" ""
log "INFO" "Le widget devrait maintenant envoyer des données au dashboard !"

# Footer de fin
{
    echo ""
    echo "$(printf '=%.0s' {1..80})"
    echo "FIN: servermonitoring_install - Code: 0"
    echo "$(printf '=%.0s' {1..80})"
    echo ""
} >> "$LOG_FILE"

exit 0