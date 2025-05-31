#!/bin/bash

# ===============================================================================
# WIDGET MQTT STATS - INSTALLATION
# Collecte et affiche les statistiques du broker MQTT
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
init_logging "Installation widget MQTT Stats" "widgets"

WIDGET_NAME="mqttstats"

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

check_sys_topics() {
    log_info "Vérification des topics système"
    
    # Vérifier que les topics $SYS sont accessibles
    if timeout 2 mosquitto_sub -h localhost -p 1883 -u "$MQTT_USER" -P "$MQTT_PASS" -t '$SYS/broker/version' -C 1 2>/dev/null; then
        log_success "Topics système accessibles"
        return 0
    else
        log_warn "Topics système non accessibles - vérifier la configuration MQTT"
        return 1
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION WIDGET MQTT STATS =========="

echo ""
echo "========================================================================"
echo "Installation du widget MQTT Statistics"
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

# Vérifier les topics système
echo ""
echo "◦ Vérification des topics système ($SYS)..."
if ! check_sys_topics; then
    echo "  ↦ Topics système non accessibles ⚠"
    echo ""
    echo "Le widget fonctionnera mais sans les statistiques système."
    echo "Pour activer les statistiques système, réinstallez MQTT avec :"
    echo "  sudo ./scripts/install/mqtt_install.sh"
    echo ""
    echo "Voulez-vous continuer quand même ? (o/N)"
    read -r response
    if [[ ! "$response" =~ ^[Oo]$ ]]; then
        echo "Installation annulée"
        log_info "Installation annulée par l'utilisateur"
        exit 0
    fi
else
    echo "  ↦ Topics système accessibles ✓"
fi

# Remplacer le collecteur par la nouvelle version si nécessaire
echo ""
echo "◦ Mise à jour du collecteur pour utiliser les topics système..."

# Sauvegarder l'ancien collecteur s'il existe
if [ -f "$WIDGET_DIR/mqttstats_collector.py" ]; then
    cp "$WIDGET_DIR/mqttstats_collector.py" "$WIDGET_DIR/mqttstats_collector.py.backup_$(date +%Y%m%d_%H%M%S)"
    log_info "Sauvegarde de l'ancien collecteur"
fi

# Le nouveau collecteur devrait déjà être en place via l'artifact précédent
# Vérifier qu'il utilise bien les topics système
if grep -q '\$SYS' "$WIDGET_DIR/mqttstats_collector.py" 2>/dev/null; then
    echo "  ↦ Collecteur déjà configuré pour les topics système ✓"
else
    echo "  ↦ Mise à jour du collecteur nécessaire ⚠"
    log_warn "Le collecteur doit être mis à jour pour utiliser les topics système"
fi

# Utiliser l'installation standard du core
if widget_standard_install "$WIDGET_NAME"; then
    echo ""
    echo "========================================================================"
    echo "Installation terminée avec succès !"
    echo "========================================================================"
    echo ""
    echo "Le widget collecte les statistiques MQTT :"
    echo "  • Messages reçus/envoyés  : depuis \$SYS/broker/messages/*"
    echo "  • Clients connectés       : depuis \$SYS/broker/clients/connected"
    echo "  • Uptime du broker        : depuis \$SYS/broker/uptime"
    echo "  • Topics actifs           : surveillance en temps réel"
    echo ""
    echo "Les statistiques sont publiées sur :"
    echo "  • rpi/network/mqtt/stats  : Statistiques principales"
    echo "  • rpi/network/mqtt/topics : Liste des topics actifs"
    echo ""
    echo "Commandes utiles :"
    echo "  • Logs : journalctl -u maxlink-widget-mqttstats -f"
    echo "  • Stats système : mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t '\$SYS/#' -v"
    echo "  • Stats widget : mosquitto_sub -h localhost -u $MQTT_USER -P $MQTT_PASS -t 'rpi/network/mqtt/#' -v"
    echo ""
    
    log_success "Installation widget MQTT Stats terminée"
    exit 0
else
    echo ""
    echo "✗ Échec de l'installation"
    log_error "Installation échouée"
    exit 1
fi