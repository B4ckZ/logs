#!/bin/bash

# ===============================================================================
# SYSTÈME DE LOGGING MAXLINK - VERSION ULTRA-MINIMALISTE
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
SYSTEM_LOG="$LOG_DIR/system.log"
ERROR_LOG="$LOG_DIR/errors.log"

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
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    local log_entry="[$timestamp] [$level] [$SCRIPT_NAME] $message"
    
    # Console (seulement si demandé)
    if [ "$show_console" = true ]; then
        printf "[%s] %s\n" "$level" "$message"
    fi
    
    # Fichiers
    if [ "$LOG_TO_FILE" = true ]; then
        echo "$log_entry" >> "$SCRIPT_LOG"
        echo "$log_entry" >> "$SYSTEM_LOG"
        
        # Erreurs dans fichier séparé
        if [[ "$level" == "ERROR" ]]; then
            echo "$log_entry" >> "$ERROR_LOG"
        fi
    fi
}

# Fonctions spécialisées (seulement celles utilisées)
log_info() { log "INFO" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_warn() { log "WARN" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_error() { log "ERROR" "$1" "${2:-$LOG_TO_CONSOLE}"; }

# ===============================================================================
# FONCTIONS D'INITIALISATION
# ===============================================================================

# Capture d'état système (minimaliste)
capture_system_state() {
    local state_file="$LOG_DIR/system_state_$(date +%Y%m%d_%H%M%S).log"
    
    {
        echo "=== ÉTAT SYSTÈME MAXLINK ==="
        echo "Date: $(date)"
        echo "Script: $SCRIPT_NAME"
        echo "Utilisateur: $(whoami)"
        echo "PWD: $(pwd)"
        echo ""
        
        echo "=== SERVICES RÉSEAU ==="
        systemctl status NetworkManager 2>/dev/null || true
        echo ""
        
        echo "=== INTERFACES RÉSEAU ==="
        ip addr show
        echo ""
        
        echo "=== CONNEXIONS ACTIVES ==="
        nmcli connection show --active 2>/dev/null || echo "NetworkManager non disponible"
        echo ""
        
        echo "=== RÉSEAUX WIFI ==="
        nmcli device wifi list 2>/dev/null || echo "Scan WiFi impossible"
        echo ""
        
    } > "$state_file"
    
    log_info "État système capturé: $state_file"
}

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
        echo "Utilisateur: $(whoami)"
        echo "PID: $$"
        echo "$(printf '=%.0s' {1..80})"
        echo ""
    } >> "$SCRIPT_LOG"
    
    log_info "Script $SCRIPT_NAME démarré"
    capture_system_state
}

# Finalisation
finalize_logging() {
    local exit_code="${1:-0}"
    
    log_info "Script $SCRIPT_NAME terminé avec le code $exit_code"
    
    # Footer de fin
    {
        echo ""
        echo "$(printf '=%.0s' {1..80})"
        echo "FIN: $SCRIPT_NAME"
        echo "Code de sortie: $exit_code"
        echo "Date: $(date)"
        echo "$(printf '=%.0s' {1..80})"
        echo ""
    } >> "$SCRIPT_LOG"
    
    # État final si erreur
    [ "$exit_code" -ne 0 ] && capture_system_state
}

# ===============================================================================
# INITIALISATION AUTOMATIQUE
# ===============================================================================

# Trap pour capturer la fin du script
trap 'finalize_logging $?' EXIT