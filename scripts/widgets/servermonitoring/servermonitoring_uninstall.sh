#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - SCRIPT DE DÉSINSTALLATION
# Suppression complète et propre du widget
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
SERVICE_NAME="maxlink-widget-servermonitoring"

# Fichiers à supprimer
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COLLECTOR_LOG="/var/log/maxlink/widgets/servermonitoring_collector.log"
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"

# Logs
LOG_DIR="$BASE_DIR/logs"
UNINSTALL_LOG="$LOG_DIR/widgets/${WIDGET_ID}_uninstall_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/widgets"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Double sortie : console et fichier
exec 1> >(tee -a "$UNINSTALL_LOG")
exec 2>&1

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

log_info() {
    log "INFO" "$1"
}

log_error() {
    log "ERROR" "$1"
}

log_success() {
    log "SUCCESS" "$1"
}

log_warning() {
    log "WARNING" "$1"
}

print_status() {
    local message=$1
    local status=$2
    
    case "$status" in
        "success")
            echo -e "${GREEN}✓${NC} $message"
            log_success "$message"
            ;;
        "error")
            echo -e "${RED}✗${NC} $message"
            log_error "$message"
            ;;
        "warning")
            echo -e "${YELLOW}⚠${NC} $message"
            log_warning "$message"
            ;;
        "info")
            echo "  $message"
            log_info "$message"
            ;;
    esac
}

# ===============================================================================
# FONCTIONS DE DÉSINSTALLATION
# ===============================================================================

# Arrêter et désactiver le service
stop_and_disable_service() {
    log_info "Arrêt et désactivation du service..."
    
    # Vérifier si le service existe
    if systemctl list-unit-files | grep -q "^$SERVICE_NAME.service"; then
        # Arrêter le service
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            if systemctl stop "$SERVICE_NAME"; then
                print_status "Service arrêté" "success"
            else
                print_status "Erreur lors de l'arrêt du service" "error"
                return 1
            fi
        else
            print_status "Service déjà arrêté" "info"
        fi
        
        # Désactiver le service
        if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            if systemctl disable "$SERVICE_NAME"; then
                print_status "Service désactivé" "success"
            else
                print_status "Erreur lors de la désactivation du service" "warning"
            fi
        else
            print_status "Service déjà désactivé" "info"
        fi
    else
        print_status "Service non trouvé" "info"
    fi
    
    return 0
}

# Supprimer le fichier de service
remove_service_file() {
    log_info "Suppression du fichier de service..."
    
    if [ -f "$SERVICE_FILE" ]; then
        if rm -f "$SERVICE_FILE"; then
            print_status "Fichier de service supprimé" "success"
            
            # Recharger systemd
            systemctl daemon-reload
            print_status "Configuration systemd rechargée" "success"
        else
            print_status "Erreur lors de la suppression du fichier de service" "error"
            return 1
        fi
    else
        print_status "Fichier de service non trouvé" "info"
    fi
    
    return 0
}

# Supprimer les logs
remove_logs() {
    log_info "Suppression des logs du widget..."
    
    local logs_removed=0
    
    # Log du collecteur
    if [ -f "$COLLECTOR_LOG" ]; then
        if rm -f "$COLLECTOR_LOG"; then
            print_status "Log du collecteur supprimé" "success"
            ((logs_removed++))
        else
            print_status "Erreur lors de la suppression du log collecteur" "warning"
        fi
    fi
    
    # Logs d'installation précédents
    local install_logs=$(find "$LOG_DIR/widgets" -name "${WIDGET_ID}_install_*.log" 2>/dev/null)
    if [ -n "$install_logs" ]; then
        local count=$(echo "$install_logs" | wc -l)
        if rm -f $install_logs; then
            print_status "$count log(s) d'installation supprimé(s)" "success"
            ((logs_removed+=$count))
        fi
    fi
    
    # Logs de test précédents
    local test_logs=$(find "$LOG_DIR/widgets" -name "${WIDGET_ID}_test_*.log" 2>/dev/null)
    if [ -n "$test_logs" ]; then
        local count=$(echo "$test_logs" | wc -l)
        if rm -f $test_logs; then
            print_status "$count log(s) de test supprimé(s)" "success"
            ((logs_removed+=$count))
        fi
    fi
    
    if [ $logs_removed -eq 0 ]; then
        print_status "Aucun log à supprimer" "info"
    else
        print_status "Total: $logs_removed fichier(s) de log supprimé(s)" "info"
    fi
    
    return 0
}

# Retirer du tracking
remove_from_tracking() {
    log_info "Mise à jour du tracking des widgets..."
    
    if [ -f "$WIDGETS_TRACKING" ]; then
        # Utiliser Python pour retirer l'entrée
        python3 -c "
import json

try:
    with open('$WIDGETS_TRACKING', 'r') as f:
        widgets = json.load(f)
    
    if '$WIDGET_ID' in widgets:
        del widgets['$WIDGET_ID']
        
        with open('$WIDGETS_TRACKING', 'w') as f:
            json.dump(widgets, f, indent=2)
        
        print('removed')
    else:
        print('not_found')
except Exception as e:
    print(f'error:{e}')
" > /tmp/tracking_result

        local result=$(cat /tmp/tracking_result)
        rm -f /tmp/tracking_result
        
        case "$result" in
            "removed")
                print_status "Widget retiré du tracking" "success"
                ;;
            "not_found")
                print_status "Widget non trouvé dans le tracking" "info"
                ;;
            error:*)
                print_status "Erreur lors de la mise à jour du tracking: ${result#error:}" "warning"
                ;;
        esac
    else
        print_status "Fichier de tracking non trouvé" "info"
    fi
    
    return 0
}

# Nettoyer les processus orphelins
cleanup_processes() {
    log_info "Recherche de processus orphelins..."
    
    # Chercher les processus collector.py
    local pids=$(pgrep -f "python3.*$WIDGET_DIR/collector.py" 2>/dev/null)
    
    if [ -n "$pids" ]; then
        print_status "Processus orphelin(s) trouvé(s): $pids" "warning"
        
        for pid in $pids; do
            if kill -TERM "$pid" 2>/dev/null; then
                print_status "Processus $pid arrêté" "success"
            else
                if kill -KILL "$pid" 2>/dev/null; then
                    print_status "Processus $pid forcé à s'arrêter" "success"
                else
                    print_status "Impossible d'arrêter le processus $pid" "error"
                fi
            fi
        done
    else
        print_status "Aucun processus orphelin trouvé" "info"
    fi
    
    return 0
}

# Nettoyer les entrées journal systemd
cleanup_journal() {
    log_info "Nettoyage du journal systemd..."
    
    if command -v journalctl >/dev/null 2>&1; then
        # Vacuum les logs du service (garder seulement les 24 dernières heures)
        if journalctl --vacuum-time=1d --unit="$SERVICE_NAME" 2>/dev/null; then
            print_status "Journal systemd nettoyé" "success"
        else
            print_status "Journal déjà propre ou non accessible" "info"
        fi
    else
        print_status "journalctl non disponible" "info"
    fi
    
    return 0
}

# Demander confirmation
ask_confirmation() {
    echo ""
    echo -e "${YELLOW}⚠ ATTENTION${NC}"
    echo "Cette action va désinstaller complètement le widget $WIDGET_NAME."
    echo "Les éléments suivants seront supprimés :"
    echo "  - Le service systemd"
    echo "  - Les fichiers de log"
    echo "  - L'entrée dans le tracking des widgets"
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

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "=========================================="
log_info "Désinstallation du widget: $WIDGET_NAME"
log_info "=========================================="
log_info "Heure de début: $(date)"
log_info "Fichier de log: $UNINSTALL_LOG"

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    print_status "Ce script doit être exécuté avec des privilèges root" "error"
    exit 1
fi

# Demander confirmation
if ! ask_confirmation; then
    print_status "Désinstallation annulée par l'utilisateur" "warning"
    exit 0
fi

echo ""
log_info "Début de la désinstallation..."
echo ""

# Variables pour le résumé
errors=0
warnings=0

# Étape 1: Arrêt du service
echo "ÉTAPE 1: Arrêt du service"
echo "------------------------"
if ! stop_and_disable_service; then
    ((errors++))
fi
echo ""

# Étape 2: Suppression du service
echo "ÉTAPE 2: Suppression du service systemd"
echo "---------------------------------------"
if ! remove_service_file; then
    ((errors++))
fi
echo ""

# Étape 3: Nettoyage des processus
echo "ÉTAPE 3: Nettoyage des processus"
echo "--------------------------------"
cleanup_processes
echo ""

# Étape 4: Suppression des logs
echo "ÉTAPE 4: Suppression des logs"
echo "-----------------------------"
remove_logs
echo ""

# Étape 5: Mise à jour du tracking
echo "ÉTAPE 5: Mise à jour du tracking"
echo "--------------------------------"
remove_from_tracking
echo ""

# Étape 6: Nettoyage du journal
echo "ÉTAPE 6: Nettoyage du journal systemd"
echo "-------------------------------------"
cleanup_journal
echo ""

# Note sur les fichiers du widget
echo "NOTE: Les fichiers du widget dans $WIDGET_DIR"
echo "      n'ont PAS été supprimés. Vous pouvez les supprimer"
echo "      manuellement si vous ne souhaitez pas les conserver."
echo ""

# Résumé
log_info "=========================================="
echo ""
if [ $errors -eq 0 ]; then
    print_status "Désinstallation terminée avec succès !" "success"
    log_success "Widget $WIDGET_NAME désinstallé complètement"
else
    print_status "Désinstallation terminée avec $errors erreur(s)" "error"
    log_error "Désinstallation incomplète: $errors erreur(s)"
fi

echo ""
log_info "Heure de fin: $(date)"
echo ""

# Commandes utiles après désinstallation
echo "Commandes utiles:"
echo "  - Vérifier les processus restants: ps aux | grep collector.py"
echo "  - Supprimer les fichiers du widget: rm -rf $WIDGET_DIR"
echo "  - Voir ce log: cat $UNINSTALL_LOG"
echo ""

exit $errors