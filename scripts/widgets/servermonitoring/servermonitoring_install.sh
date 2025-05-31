#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - INSTALLATION
# Version simplifiée utilisant le core commun
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIDGET_DIR="$SCRIPT_DIR"
WIDGETS_DIR="$(dirname "$WIDGET_DIR")"
SCRIPTS_DIR="$(dirname "$WIDGETS_DIR")"
BASE_DIR="$(dirname "$SCRIPTS_DIR")"

# Source des modules
source "$BASE_DIR/scripts/common/variables.sh"
source "$BASE_DIR/scripts/common/logging.sh"
source "$BASE_DIR/scripts/widgets/_core/widget_common.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation widget Server Monitoring" "widgets"

WIDGET_NAME="servermonitoring"

# ===============================================================================
# VÉRIFICATIONS SPÉCIFIQUES
# ===============================================================================

check_mqtt_broker() {
    log_info "Vérification du broker MQTT"
    
    if ! systemctl is-active --quiet mosquitto; then
        log_error "Mosquitto n'est pas actif"
        return 1
    fi
    
    # Test de connexion avec les bonnes credentials
    if mosquitto_pub -h localhost -p 1883 -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/widget/install" -m "test" 2>/dev/null; then
        log_success "Connexion MQTT fonctionnelle"
        return 0
    else
        log_error "Impossible de se connecter au broker MQTT"
        return 1
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION WIDGET SERVER MONITORING =========="

echo ""
echo "========================================================================"
echo "Installation du widget Server Monitoring"
echo "========================================================================"
echo ""

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Ce script doit être exécuté avec des privilèges root ✗"
    log_error "Privilèges root requis"
    exit 1
fi

# Vérifier MQTT
echo "◦ Vérification du broker MQTT..."
if ! check_mqtt_broker; then
    echo "  ↦ Le broker MQTT doit être installé et actif ✗"
    echo ""
    echo "Veuillez d'abord installer MQTT avec mqtt_install.sh"
    exit 1
fi
echo "  ↦ Broker MQTT actif ✓"

# Utiliser l'installation standard du core
if widget_standard_install "$WIDGET_NAME"; then
    echo ""
    echo "========================================================================"
    echo "Installation terminée avec succès !"
    echo "========================================================================"
    echo ""
    echo "Le widget envoie maintenant des métriques système via MQTT :"
    echo "  • CPU (par core) : rpi/system/cpu/core{1-4}"
    echo "  • Température    : rpi/system/temperature/{cpu,gpu}"
    echo "  • Fréquence      : rpi/system/frequency/{cpu,gpu}"
    echo "  • Mémoire        : rpi/system/memory/{ram,swap,disk}"
    echo "  • Uptime         : rpi/system/uptime"
    echo ""
    echo "Commandes utiles :"
    echo "  • Logs : journalctl -u maxlink-widget-servermonitoring -f"
    echo "  • Test : mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t 'rpi/system/+/+' -v"
    echo ""
    
    log_success "Installation widget Server Monitoring terminée"
    exit 0
else
    echo ""
    echo "✗ Échec de l'installation"
    log_error "Installation échouée"
    exit 1
fi