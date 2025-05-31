#!/bin/bash

# ===============================================================================
# WIDGET WIFI STATS - INSTALLATION
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
init_logging "Installation widget WiFi Stats" "widgets"

WIDGET_NAME="wifistats"

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION WIDGET WIFI STATS =========="

echo ""
echo "========================================================================"
echo "Installation du widget WiFi Statistics"
echo "========================================================================"
echo ""

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Ce script doit être exécuté avec des privilèges root ✗"
    log_error "Privilèges root requis"
    exit 1
fi

# Vérifier que l'AP est configuré
echo "◦ Vérification du mode AP..."
if ! nmcli con show | grep -q "$AP_SSID"; then
    echo "  ↦ Le mode AP n'est pas configuré ⚠"
    echo "  ↦ Ce widget fonctionnera quand l'AP sera installé"
    log_warn "Mode AP non configuré"
else
    echo "  ↦ Mode AP trouvé ✓"
fi

# Vérifier les outils système
echo ""
echo "◦ Vérification des outils système..."
if ! command -v iw >/dev/null 2>&1; then
    echo "  ↦ Installation de iw..."
    apt-get install -y iw >/dev/null 2>&1
fi
echo "  ↦ Outils système disponibles ✓"

# Utiliser l'installation standard
if widget_standard_install "$WIDGET_NAME"; then
    echo ""
    echo "========================================================================"
    echo "Installation terminée avec succès !"
    echo "========================================================================"
    echo ""
    echo "Le widget collecte les statistiques WiFi :"
    echo "  • Clients connectés : rpi/network/wifi/clients"
    echo "  • État de l'AP      : rpi/network/wifi/status"
    echo ""
    echo "Mise à jour toutes les 30 secondes"
    echo ""
    
    log_success "Installation widget WiFi Stats terminée"
    exit 0
else
    echo ""
    echo "✗ Échec de l'installation"
    log_error "Installation échouée"
    exit 1
fi