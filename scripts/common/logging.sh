#!/bin/bash

# ===============================================================================
# SYSTÈME DE LOGGING UNIFIÉ MAXLINK - VERSION SIMPLIFIÉE
# Logs centralisés sur clé USB pour analyse externe
# ===============================================================================

# Détection automatique du répertoire de base
if [ -z "$BASE_DIR" ]; then
    CALLING_SCRIPT="${BASH_SOURCE[1]:-$0}"
    SCRIPT_DIR="$(cd "$(dirname "$CALLING_SCRIPT")" && pwd)"
    
    # Remonter jusqu'à trouver config.sh
    TEMP_DIR="$SCRIPT_DIR"
    while [ ! -f "$TEMP_DIR/config.sh" ] && [ "$TEMP_DIR" != "/" ]; do
        TEMP_DIR="$(dirname "$TEMP_DIR")"
    done
    
    if [ -f "$TEMP_DIR/config.sh" ]; then
        BASE_DIR="$TEMP_DIR"
    else
        BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
    fi
fi

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Structure des logs sur la clé USB
LOG_ROOT="$BASE_DIR/logs"
LOG_INSTALL="$LOG_ROOT/install"
LOG_WIDGETS="$LOG_ROOT/widgets"
LOG_SYSTEM="$LOG_ROOT/system"
LOG_PYTHON="$LOG_ROOT/python"

# Créer les répertoires
mkdir -p "$LOG_INSTALL" "$LOG_WIDGETS" "$LOG_SYSTEM" "$LOG_PYTHON"

# Variables pour le script courant
SCRIPT_NAME=""
SCRIPT_LOG=""
LOG_CATEGORY="system"

# Configuration d'affichage
LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-true}
LOG_TO_FILE=${LOG_TO_FILE:-true}

# ===============================================================================
# FONCTIONS PRINCIPALES
# ===============================================================================

# Fonction de logging principale
log() {
    local level="$1"
    local message="$2"
    local show_console="${3:-$LOG_TO_CONSOLE}"
    
    # Format unifié : [YYYY-MM-DD HH:MM:SS] [NIVEAU] [SCRIPT] Message
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] [$SCRIPT_NAME] $message"
    
    # Console (si demandé)
    if [ "$show_console" = true ]; then
        echo "[$level] $message"
    fi
    
    # Fichier
    if [ "$LOG_TO_FILE" = true ] && [ -n "$SCRIPT_LOG" ]; then
        echo "$log_entry" >> "$SCRIPT_LOG"
    fi
}

# Fonctions spécialisées
log_info() { log "INFO" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_warn() { log "WARN" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_error() { log "ERROR" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_success() { log "SUCCESS" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_debug() { log "DEBUG" "$1" "${2:-false}"; }

# Logger une commande et son résultat
log_command() {
    local cmd="$1"
    local desc="$2"
    
    log "CMD" "Exécution: $desc"
    log "CMD" "Commande: $cmd"
    
    # Exécuter et capturer
    local output
    local exit_code
    
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    
    # Logger la sortie ligne par ligne
    if [ -n "$output" ]; then
        echo "$output" | while IFS= read -r line; do
            log "OUT" "$line"
        done
    fi
    
    log "CMD" "Code de sortie: $exit_code"
    return $exit_code
}

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging pour un script
init_logging() {
    local script_description="$1"
    local category="${2:-system}"  # install, widgets, system, python
    
    # Déterminer le nom du script
    SCRIPT_NAME=$(basename "${BASH_SOURCE[1]:-$0}" .sh)
    LOG_CATEGORY="$category"
    
    # Déterminer le fichier de log selon la catégorie
    case "$category" in
        install)
            SCRIPT_LOG="$LOG_INSTALL/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"
            ;;
        widgets)
            SCRIPT_LOG="$LOG_WIDGETS/${SCRIPT_NAME}.log"
            ;;
        python)
            SCRIPT_LOG="$LOG_PYTHON/${SCRIPT_NAME}.log"
            ;;
        *)
            SCRIPT_LOG="$LOG_SYSTEM/${SCRIPT_NAME}.log"
            ;;
    esac
    
    # Header dans le log
    {
        echo ""
        echo "================================================================================"
        echo "DÉMARRAGE: $SCRIPT_NAME"
        [ -n "$script_description" ] && echo "Description: $script_description"
        echo "Date: $(date)"
        echo "Utilisateur: $(whoami)"
        echo "Répertoire: $(pwd)"
        echo "================================================================================"
        echo ""
    } >> "$SCRIPT_LOG"
    
    log_info "Script $SCRIPT_NAME initialisé"
}

# Finaliser le logging
finalize_logging() {
    local exit_code="${1:-0}"
    
    log_info "Script $SCRIPT_NAME terminé avec le code $exit_code"
    
    # Footer
    {
        echo ""
        echo "================================================================================"
        echo "FIN: $SCRIPT_NAME"
        echo "Code de sortie: $exit_code"
        echo "Durée: $SECONDS secondes"
        echo "================================================================================"
        echo ""
    } >> "$SCRIPT_LOG"
}

# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Obtenir le chemin du log actuel
get_current_log_path() {
    echo "$SCRIPT_LOG"
}

# Lister tous les logs d'une catégorie
list_logs() {
    local category="${1:-all}"
    
    case "$category" in
        install) ls -la "$LOG_INSTALL" 2>/dev/null ;;
        widgets) ls -la "$LOG_WIDGETS" 2>/dev/null ;;
        system)  ls -la "$LOG_SYSTEM" 2>/dev/null ;;
        python)  ls -la "$LOG_PYTHON" 2>/dev/null ;;
        all)     ls -la "$LOG_ROOT"/*/ 2>/dev/null ;;
    esac
}

# Créer un fichier de log unifié pour Python
create_python_logger_config() {
    local module_name="$1"
    local log_file="$LOG_PYTHON/${module_name}.log"
    
    cat > /tmp/maxlink_logger_config.py << EOF
import logging
import os

# Configuration du logger pour $module_name
log_file = "$log_file"
os.makedirs(os.path.dirname(log_file), exist_ok=True)

# Format identique aux scripts bash
formatter = logging.Formatter(
    '[%(asctime)s] [%(levelname)s] [$module_name] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# Handler fichier
file_handler = logging.FileHandler(log_file, mode='a')
file_handler.setFormatter(formatter)

# Handler console
console_handler = logging.StreamHandler()
console_handler.setFormatter(logging.Formatter('[%(levelname)s] %(message)s'))

# Configuration du logger
logger = logging.getLogger('$module_name')
logger.setLevel(logging.INFO)
logger.addHandler(file_handler)
logger.addHandler(console_handler)
EOF
}

# ===============================================================================
# EXPORT DES VARIABLES ET FONCTIONS
# ===============================================================================

# Export des variables
export LOG_ROOT LOG_INSTALL LOG_WIDGETS LOG_SYSTEM LOG_PYTHON

# Export de TOUTES les fonctions pour qu'elles soient disponibles dans les scripts
export -f log log_info log_warn log_error log_success log_debug
export -f log_command
export -f init_logging finalize_logging 
export -f get_current_log_path list_logs create_python_logger_config

# ===============================================================================
# AUTO-FINALISATION
# ===============================================================================

# Trap pour capturer la fin du script automatiquement
trap 'finalize_logging $?' EXIT