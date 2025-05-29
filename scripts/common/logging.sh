#!/bin/bash

# ===============================================================================
# SYSTÈME DE LOGGING MAXLINK - VERSION SIMPLIFIÉE
# Un script = Un fichier log
# ===============================================================================

# Détection automatique des chemins
if [ -z "$BASE_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
fi

# Configuration des logs
LOG_DIR="$BASE_DIR/logs"
SCRIPT_NAME=$(basename "${BASH_SOURCE[1]}" .sh)
SCRIPT_LOG="$LOG_DIR/${SCRIPT_NAME}.log"

# Création du répertoire de logs
mkdir -p "$LOG_DIR"

# Configuration
LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-true}
LOG_TO_FILE=${LOG_TO_FILE:-true}

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Fonction de logging principale
log() {
    local level="$1"
    local message="$2"
    local show_console="${3:-$LOG_TO_CONSOLE}"
    
    # Timestamp
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] [$SCRIPT_NAME] $message"
    
    # Console (seulement si demandé)
    if [ "$show_console" = true ]; then
        case "$level" in
            ERROR) printf "\033[31m[%s] %s\033[0m\n" "$level" "$message" ;;
            WARN)  printf "\033[33m[%s] %s\033[0m\n" "$level" "$message" ;;
            *)     printf "[%s] %s\n" "$level" "$message" ;;
        esac
    fi
    
    # Fichier (append au fichier existant)
    if [ "$LOG_TO_FILE" = true ]; then
        echo "$log_entry" >> "$SCRIPT_LOG"
    fi
}

# Fonctions spécialisées
log_info() { log "INFO" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_warn() { log "WARN" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_error() { log "ERROR" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_success() { log "SUCCESS" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_warning() { log "WARNING" "$1" "${2:-$LOG_TO_CONSOLE}"; }

# ===============================================================================
# FONCTIONS D'INITIALISATION
# ===============================================================================

# Initialisation
init_logging() {
    local script_description="$1"
    
    # Header de début
    {
        echo ""
        echo "$(printf '=%.0s' {1..80})"
        echo "DÉMARRAGE: $SCRIPT_NAME"
        [ -n "$script_description" ] && echo "Description: $script_description"
        echo "Date: $(date)"
        echo "$(printf '=%.0s' {1..80})"
        echo ""
    } >> "$SCRIPT_LOG"
    
    log_info "Script $SCRIPT_NAME démarré"
}

# Finalisation
finalize_logging() {
    local exit_code="${1:-0}"
    
    log_info "Script $SCRIPT_NAME terminé avec le code $exit_code"
    
    # Footer de fin
    {
        echo ""
        echo "$(printf '=%.0s' {1..80})"
        echo "FIN: $SCRIPT_NAME - Code: $exit_code"
        echo "$(printf '=%.0s' {1..80})"
        echo ""
    } >> "$SCRIPT_LOG"
}

# ===============================================================================
# INITIALISATION AUTOMATIQUE
# ===============================================================================

# Trap pour capturer la fin du script
trap 'finalize_logging $?' EXIT