#!/bin/bash

# ===============================================================================
# SYSTÈME DE LOGGING MAXLINK - VERSION OPTIMISÉE
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

# Création du répertoire de logs
mkdir -p "$LOG_DIR"

# Configuration
LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-true}
LOG_TO_FILE=${LOG_TO_FILE:-true}
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10 MB

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Rotation des logs
rotate_logs() {
    for logfile in "$SCRIPT_LOG" "$SYSTEM_LOG"; do
        if [ -f "$logfile" ] && [ $(stat -c%s "$logfile" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]; then
            mv "$logfile" "$LOG_DIR/archived/$(basename "$logfile").$(date +%Y%m%d_%H%M%S)"
            touch "$logfile"
        fi
    done
}

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
    
    # Fichiers
    if [ "$LOG_TO_FILE" = true ]; then
        echo "$log_entry" >> "$SCRIPT_LOG"
        echo "$log_entry" >> "$SYSTEM_LOG"
    fi
}

# Fonctions spécialisées
log_info() { log "INFO" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_warn() { log "WARN" "$1" "${2:-$LOG_TO_CONSOLE}"; }
log_error() { log "ERROR" "$1" "${2:-$LOG_TO_CONSOLE}"; }

# ===============================================================================
# FONCTIONS D'INITIALISATION
# ===============================================================================

# Capture d'état système (optimisée)
capture_system_state() {
    local state_file="$LOG_DIR/state_$(date +%Y%m%d_%H%M%S).log"
    
    {
        echo "=== ÉTAT SYSTÈME MAXLINK ==="
        echo "Date: $(date)"
        echo "Script: $SCRIPT_NAME"
        echo "Utilisateur: $(whoami)"
        echo ""
        echo "=== RÉSEAU ==="
        echo "WiFi: $(nmcli -t -f DEVICE,STATE device | grep wlan0 || echo "wlan0:non disponible")"
        echo "IP: $(ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}' || echo "Aucune")"
        echo ""
        echo "=== SYSTÈME ==="
        echo "Charge: $(uptime | awk -F'load average:' '{print $2}')"
        echo "Mémoire: $(free -h | grep Mem | awk '{print "Total: "$2", Utilisé: "$3", Libre: "$4}')"
        echo "Disque: $(df -h / | tail -1 | awk '{print "Total: "$2", Utilisé: "$3", Libre: "$4}')"
    } > "$state_file"
    
    log_info "État système capturé: $state_file"
}

# Initialisation
init_logging() {
    local script_description="$1"
    
    # Rotation des logs si nécessaire
    rotate_logs
    
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