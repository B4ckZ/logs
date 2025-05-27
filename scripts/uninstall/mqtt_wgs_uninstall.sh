#!/bin/bash

# ===============================================================================
# MAXLINK - DÉSINSTALLATION MQTT WIDGETS (WGS)
# Désinstalle tous les widgets MQTT
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables et du logging
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Initialiser le logging
init_logging "Désinstallation MQTT Widgets"

# Répertoire des widgets
WIDGETS_DIR="$BASE_DIR/scripts/widgets"
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"

# Compteurs
TOTAL_WIDGETS=0
UNINSTALLED_WIDGETS=0
FAILED_WIDGETS=0

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
}

# Demander confirmation
ask_confirmation() {
    echo ""
    echo -e "${YELLOW}⚠ ATTENTION${NC}"
    echo "Cette action va désinstaller TOUS les widgets MQTT installés."
    echo ""
    echo "Les éléments suivants seront supprimés :"
    echo "  - Tous les services systemd des widgets"
    echo "  - Tous les logs des widgets"
    echo "  - Le tracking des widgets"
    echo ""
    echo "Le broker MQTT (Mosquitto) ne sera PAS désinstallé."
    echo ""
    echo -n "Êtes-vous sûr de vouloir continuer ? (o/N) "
    
    read -r response
    case "$response" in
        [oO][uU][iI]|[oO])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Lister les widgets installés
list_installed_widgets() {
    local widgets=()
    
    if [ -f "$WIDGETS_TRACKING" ]; then
        # Extraire les IDs des widgets du JSON
        widgets=($(python3 -c "
import json
try:
    with open('$WIDGETS_TRACKING', 'r') as f:
        data = json.load(f)
    for widget_id in data.keys():
        print(widget_id)
except:
    pass
" 2>/dev/null))
    fi
    
    # Ajouter aussi les widgets détectés par leurs services
    for service in $(systemctl list-units --all --no-pager | grep "maxlink-widget-" | awk '{print $1}'); do
        local widget_name=$(echo "$service" | sed 's/maxlink-widget-//;s/\.service//')
        if [[ ! " ${widgets[@]} " =~ " ${widget_name} " ]]; then
            widgets+=("$widget_name")
        fi
    done
    
    echo "${widgets[@]}"
}

# Désinstaller un widget
uninstall_widget() {
    local widget_name=$1
    local widget_dir="$WIDGETS_DIR/$widget_name"
    local uninstall_script="$widget_dir/${widget_name}_uninstall.sh"
    
    echo ""
    echo "Désinstallation du widget: $widget_name"
    echo "----------------------------------------"
    
    # Vérifier si le script de désinstallation existe
    if [ -f "$uninstall_script" ] && [ -x "$uninstall_script" ]; then
        log_info "Exécution du script de désinstallation pour $widget_name"
        
        # Exécuter le script de désinstallation
        if bash "$uninstall_script" <<< "o"; then  # Auto-confirmer
            echo "  ↦ Widget $widget_name désinstallé ✓"
            log_info "Widget $widget_name désinstallé avec succès"
            ((UNINSTALLED_WIDGETS++))
            return 0
        else
            echo "  ↦ Erreur lors de la désinstallation ✗"
            log_error "Échec de la désinstallation du widget $widget_name"
            ((FAILED_WIDGETS++))
            return 1
        fi
    else
        # Désinstallation manuelle si pas de script
        echo "  ↦ Script de désinstallation non trouvé, désinstallation manuelle..."
        
        # Arrêter et désactiver le service
        local service_name="maxlink-widget-$widget_name"
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            systemctl stop "$service_name"
            echo "  ↦ Service arrêté"
        fi
        
        if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
            systemctl disable "$service_name"
            echo "  ↦ Service désactivé"
        fi
        
        # Supprimer le fichier de service
        if [ -f "/etc/systemd/system/$service_name.service" ]; then
            rm -f "/etc/systemd/system/$service_name.service"
            systemctl daemon-reload
            echo "  ↦ Fichier de service supprimé"
        fi
        
        ((UNINSTALLED_WIDGETS++))
        return 0
    fi
}

# Nettoyer le tracking
cleanup_tracking() {
    echo ""
    echo "◦ Nettoyage du tracking des widgets..."
    
    if [ -f "$WIDGETS_TRACKING" ]; then
        # Sauvegarder avant suppression
        cp "$WIDGETS_TRACKING" "$WIDGETS_TRACKING.bak.$(date +%Y%m%d_%H%M%S)"
        
        # Vider le fichier
        echo "{}" > "$WIDGETS_TRACKING"
        echo "  ↦ Tracking réinitialisé ✓"
        log_info "Fichier de tracking réinitialisé"
    else
        echo "  ↦ Fichier de tracking non trouvé"
    fi
}

# Nettoyer les logs
cleanup_logs() {
    echo ""
    echo "◦ Nettoyage des logs des widgets..."
    
    local log_dir="/var/log/maxlink/widgets"
    local logs_count=0
    
    if [ -d "$log_dir" ]; then
        # Compter et supprimer les logs
        logs_count=$(find "$log_dir" -name "*.log" 2>/dev/null | wc -l)
        
        if [ $logs_count -gt 0 ]; then
            rm -f "$log_dir"/*.log
            echo "  ↦ $logs_count fichier(s) de log supprimé(s) ✓"
            log_info "$logs_count fichiers de log supprimés"
        else
            echo "  ↦ Aucun log à supprimer"
        fi
    else
        echo "  ↦ Répertoire de logs non trouvé"
    fi
    
    # Nettoyer aussi les logs d'installation/test
    local widget_logs="$BASE_DIR/logs/widgets"
    if [ -d "$widget_logs" ]; then
        local count=$(find "$widget_logs" -name "*.log" 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            rm -f "$widget_logs"/*.log
            echo "  ↦ $count log(s) d'installation/test supprimé(s) ✓"
        fi
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

echo ""
echo "========================================================================"
echo "DÉSINSTALLATION MQTT WIDGETS (WGS)"
echo "========================================================================"
echo ""

send_progress 5 "Initialisation..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    exit 1
fi

# Lister les widgets installés
echo "◦ Recherche des widgets installés..."
installed_widgets=($(list_installed_widgets))
TOTAL_WIDGETS=${#installed_widgets[@]}

if [ $TOTAL_WIDGETS -eq 0 ]; then
    echo "  ↦ Aucun widget installé trouvé ✓"
    echo ""
    echo "Rien à désinstaller."
    exit 0
fi

echo "  ↦ $TOTAL_WIDGETS widget(s) installé(s) trouvé(s)"
echo ""
echo "Widgets à désinstaller :"
for widget in "${installed_widgets[@]}"; do
    echo "  • $widget"
done

# Demander confirmation
if ! ask_confirmation; then
    echo ""
    echo "Désinstallation annulée."
    exit 0
fi

send_progress 10 "Désinstallation des widgets..."

# ÉTAPE 1 : Désinstallation des widgets
echo ""
echo "ÉTAPE 1 : DÉSINSTALLATION DES WIDGETS"
echo "========================================================================"

# Calculer la progression par widget
progress_per_widget=$((70 / TOTAL_WIDGETS))
current_progress=10

# Désinstaller chaque widget
for widget in "${installed_widgets[@]}"; do
    uninstall_widget "$widget"
    
    # Mettre à jour la progression
    current_progress=$((current_progress + progress_per_widget))
    send_progress $current_progress "Désinstallation: $widget"
done

# ÉTAPE 2 : Nettoyage
echo ""
echo "ÉTAPE 2 : NETTOYAGE"
echo "========================================================================"

send_progress 85 "Nettoyage..."

# Nettoyer le tracking
cleanup_tracking

# Nettoyer les logs
cleanup_logs

# Vérifier les processus orphelins
echo ""
echo "◦ Recherche de processus orphelins..."
pids=$(pgrep -f "python3.*collector\.py" 2>/dev/null)
if [ -n "$pids" ]; then
    echo "  ↦ Processus orphelins trouvés: $pids"
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null && echo "  ↦ Processus $pid arrêté"
    done
else
    echo "  ↦ Aucun processus orphelin ✓"
fi

send_progress 100 "Désinstallation terminée"

# RÉSUMÉ
echo ""
echo "========================================================================"
echo "RÉSUMÉ DE LA DÉSINSTALLATION"
echo "========================================================================"
echo ""
echo "◦ Widgets trouvés      : $TOTAL_WIDGETS"
echo "◦ Widgets désinstallés : $UNINSTALLED_WIDGETS"
echo "◦ Échecs              : $FAILED_WIDGETS"
echo ""

if [ $FAILED_WIDGETS -eq 0 ]; then
    echo -e "${GREEN}✓ Désinstallation terminée avec succès !${NC}"
else
    echo -e "${YELLOW}⚠ Désinstallation terminée avec $FAILED_WIDGETS erreur(s)${NC}"
fi

echo ""
echo "Note: Le broker MQTT (Mosquitto) est toujours installé."
echo "      Pour le désinstaller, utilisez le script mqtt_uninstall.sh"
echo ""

log_info "Désinstallation MQTT WGS terminée - Widgets désinstallés: $UNINSTALLED_WIDGETS/$TOTAL_WIDGETS"

exit $FAILED_WIDGETS