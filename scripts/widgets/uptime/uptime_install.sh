#!/bin/bash

# ===============================================================================
# WIDGET UPTIME - INSTALLATION
# Widget passif qui utilise les données de servermonitoring
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
init_logging "Installation widget Uptime" "widgets"

WIDGET_NAME="uptime"

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION WIDGET UPTIME =========="

echo ""
echo "========================================================================"
echo "Installation du widget Uptime"
echo "========================================================================"
echo ""

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Ce script doit être exécuté avec des privilèges root ✗"
    log_error "Privilèges root requis"
    exit 1
fi

# Vérifier que servermonitoring est installé
echo "◦ Vérification des dépendances..."
if [ "$(widget_is_installed "servermonitoring")" != "yes" ]; then
    echo "  ↦ Le widget servermonitoring doit être installé ✗"
    echo ""
    echo "Ce widget dépend des données du collecteur servermonitoring"
    log_error "Widget servermonitoring requis mais non installé"
    exit 1
fi
echo "  ↦ Widget servermonitoring trouvé ✓"

# Charger la config
config_file=$(widget_load_config "$WIDGET_NAME")
version=$(widget_get_value "$config_file" "widget.version")

# Enregistrer l'installation (pas de service pour ce widget)
widget_register "$WIDGET_NAME" "none" "$version"

echo ""
echo "========================================================================"
echo "Installation terminée avec succès !"
echo "========================================================================"
echo ""
echo "Le widget Uptime utilise les données publiées par servermonitoring"
echo "Topic MQTT : rpi/system/uptime"
echo ""
echo "Note : Ce widget est passif et n'a pas de collecteur propre"
echo ""

log_success "Installation widget Uptime terminée"
exit 0