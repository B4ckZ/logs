#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - SCRIPT DE TEST
# Test complet du widget et diagnostic des problèmes
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

# Fichiers
CONFIG_FILE="$WIDGET_DIR/widget.json"
COLLECTOR_LOG="/var/log/maxlink/widgets/servermonitoring_collector.log"

# Logs
LOG_DIR="$BASE_DIR/logs"
TEST_LOG="$LOG_DIR/widgets/${WIDGET_ID}_test_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/widgets"

# Test config
TEST_TIMEOUT=30
TOPICS_TO_TEST=(
    "rpi/system/cpu/core1"
    "rpi/system/temperature/cpu"
    "rpi/system/memory/ram"
    "rpi/system/frequency/cpu"
    "rpi/system/uptime"
)

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Double sortie : console et fichier
exec 1> >(tee -a "$TEST_LOG")
exec 2>&1

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

print_status() {
    local test_name=$1
    local status=$2
    local message=${3:-""}
    
    printf "%-50s" "$test_name"
    
    case "$status" in
        "OK")
            echo -e "${GREEN}✓ OK${NC} $message"
            log "SUCCESS" "$test_name: OK $message"
            ;;
        "FAIL")
            echo -e "${RED}✗ FAIL${NC} $message"
            log "ERROR" "$test_name: FAIL $message"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠ WARN${NC} $message"
            log "WARNING" "$test_name: WARN $message"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ INFO${NC} $message"
            log "INFO" "$test_name: $message"
            ;;
    esac
}

# ===============================================================================
# FONCTIONS DE TEST
# ===============================================================================

# Test 1: Vérification de l'installation
test_installation() {
    print_header "TEST 1: VÉRIFICATION DE L'INSTALLATION"
    
    local errors=0
    
    # Vérifier widget.json
    if [ -f "$CONFIG_FILE" ]; then
        print_status "Fichier widget.json" "OK"
    else
        print_status "Fichier widget.json" "FAIL" "Non trouvé"
        ((errors++))
    fi
    
    # Vérifier le script collecteur
    if [ -f "$WIDGET_DIR/collector.py" ]; then
        print_status "Script collector.py" "OK"
        
        # Vérifier qu'il est exécutable
        if [ -x "$WIDGET_DIR/collector.py" ]; then
            print_status "Permissions collector.py" "OK" "Exécutable"
        else
            print_status "Permissions collector.py" "WARN" "Non exécutable"
        fi
    else
        print_status "Script collector.py" "FAIL" "Non trouvé"
        ((errors++))
    fi
    
    # Vérifier le service systemd
    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        print_status "Fichier service systemd" "OK"
    else
        print_status "Fichier service systemd" "FAIL" "Non trouvé"
        ((errors++))
    fi
    
    # Vérifier le tracking
    if [ -f "/etc/maxlink/widgets_installed.json" ]; then
        if grep -q "\"$WIDGET_ID\"" "/etc/maxlink/widgets_installed.json"; then
            print_status "Enregistrement du widget" "OK" "Présent dans le tracking"
        else
            print_status "Enregistrement du widget" "WARN" "Non trouvé dans le tracking"
        fi
    else
        print_status "Enregistrement du widget" "WARN" "Fichier tracking non trouvé"
    fi
    
    return $errors
}

# Test 2: Vérification des dépendances
test_dependencies() {
    print_header "TEST 2: VÉRIFICATION DES DÉPENDANCES"
    
    local errors=0
    
    # Python3
    if command -v python3 >/dev/null 2>&1; then
        local python_version=$(python3 --version 2>&1 | awk '{print $2}')
        print_status "Python3" "OK" "Version $python_version"
    else
        print_status "Python3" "FAIL" "Non installé"
        ((errors++))
    fi
    
    # Module psutil
    if python3 -c "import psutil; print(psutil.__version__)" >/dev/null 2>&1; then
        local psutil_version=$(python3 -c "import psutil; print(psutil.__version__)" 2>/dev/null)
        print_status "Module psutil" "OK" "Version $psutil_version"
    else
        print_status "Module psutil" "FAIL" "Non installé"
        ((errors++))
    fi
    
    # Module paho-mqtt
    if python3 -c "import paho.mqtt; print(paho.mqtt.__version__)" >/dev/null 2>&1; then
        local paho_version=$(python3 -c "import paho.mqtt; print(paho.mqtt.__version__)" 2>/dev/null)
        print_status "Module paho-mqtt" "OK" "Version $paho_version"
    else
        print_status "Module paho-mqtt" "FAIL" "Non installé"
        ((errors++))
    fi
    
    # Mosquitto (broker)
    if systemctl is-active --quiet mosquitto; then
        print_status "Service mosquitto" "OK" "Actif"
    else
        print_status "Service mosquitto" "FAIL" "Non actif"
        ((errors++))
    fi
    
    # mosquitto_sub (pour les tests)
    if command -v mosquitto_sub >/dev/null 2>&1; then
        print_status "Client mosquitto_sub" "OK"
    else
        print_status "Client mosquitto_sub" "WARN" "Non disponible (tests limités)"
    fi
    
    return $errors
}

# Test 3: État du service
test_service_status() {
    print_header "TEST 3: ÉTAT DU SERVICE"
    
    local errors=0
    
    # Service activé
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_status "Service activé au démarrage" "OK"
    else
        print_status "Service activé au démarrage" "FAIL"
        ((errors++))
    fi
    
    # Service actif
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "Service en cours d'exécution" "OK"
        
        # Uptime du service
        local uptime=$(systemctl show -p ActiveEnterTimestamp "$SERVICE_NAME" | cut -d= -f2-)
        if [ -n "$uptime" ]; then
            print_status "Démarré depuis" "INFO" "$uptime"
        fi
        
        # PID du processus
        local pid=$(systemctl show -p MainPID "$SERVICE_NAME" | cut -d= -f2)
        if [ "$pid" != "0" ]; then
            print_status "PID du processus" "INFO" "$pid"
            
            # Utilisation mémoire
            if [ -f "/proc/$pid/status" ]; then
                local mem_kb=$(grep VmRSS /proc/$pid/status | awk '{print $2}')
                local mem_mb=$((mem_kb / 1024))
                print_status "Utilisation mémoire" "INFO" "${mem_mb} MB"
            fi
        fi
    else
        print_status "Service en cours d'exécution" "FAIL"
        ((errors++))
        
        # Afficher les dernières lignes du journal
        echo ""
        echo "Dernières entrées du journal du service:"
        journalctl -u "$SERVICE_NAME" -n 10 --no-pager
    fi
    
    # Vérifier les redémarrages
    local restart_count=$(systemctl show -p NRestarts "$SERVICE_NAME" | cut -d= -f2)
    if [ "$restart_count" -gt 0 ]; then
        print_status "Nombre de redémarrages" "WARN" "$restart_count"
    else
        print_status "Nombre de redémarrages" "OK" "0"
    fi
    
    return $errors
}

# Test 4: Logs du collecteur
test_collector_logs() {
    print_header "TEST 4: ANALYSE DES LOGS"
    
    local errors=0
    
    # Vérifier l'existence du fichier de log
    if [ -f "$COLLECTOR_LOG" ]; then
        print_status "Fichier de log collecteur" "OK" "$COLLECTOR_LOG"
        
        # Taille du fichier
        local size=$(du -h "$COLLECTOR_LOG" | cut -f1)
        print_status "Taille du fichier de log" "INFO" "$size"
        
        # Compter les types de messages
        local info_count=$(grep -c "\[INFO\]" "$COLLECTOR_LOG" 2>/dev/null || echo "0")
        local error_count=$(grep -c "\[ERROR\]" "$COLLECTOR_LOG" 2>/dev/null || echo "0")
        local warn_count=$(grep -c "\[WARNING\]" "$COLLECTOR_LOG" 2>/dev/null || echo "0")
        
        print_status "Messages INFO" "INFO" "$info_count"
        
        if [ "$error_count" -gt 0 ]; then
            print_status "Messages ERROR" "WARN" "$error_count erreurs détectées"
            echo ""
            echo "Dernières erreurs:"
            grep "\[ERROR\]" "$COLLECTOR_LOG" | tail -5
            echo ""
        else
            print_status "Messages ERROR" "OK" "Aucune erreur"
        fi
        
        if [ "$warn_count" -gt 0 ]; then
            print_status "Messages WARNING" "INFO" "$warn_count avertissements"
        else
            print_status "Messages WARNING" "OK" "Aucun avertissement"
        fi
        
        # Dernière ligne du log
        local last_log=$(tail -1 "$COLLECTOR_LOG" 2>/dev/null)
        if [ -n "$last_log" ]; then
            print_status "Dernière activité" "INFO" "$(echo "$last_log" | cut -d' ' -f1-2)"
        fi
        
    else
        print_status "Fichier de log collecteur" "FAIL" "Non trouvé"
        ((errors++))
    fi
    
    return $errors
}

# Test 5: Connexion MQTT
test_mqtt_connection() {
    print_header "TEST 5: CONNEXION MQTT"
    
    local errors=0
    
    # Test de connexion basique
    if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/widget/$WIDGET_ID" -m "test_connection" 2>/dev/null; then
        print_status "Connexion au broker MQTT" "OK"
    else
        print_status "Connexion au broker MQTT" "FAIL"
        ((errors++))
        return $errors
    fi
    
    # Test de réception des messages
    print_status "Test de réception des données" "INFO" "Attente de ${TEST_TIMEOUT}s..."
    
    local temp_file="/tmp/mqtt_test_$$"
    local topics_received=0
    
    # Lancer mosquitto_sub en arrière-plan
    timeout $TEST_TIMEOUT mosquitto_sub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "rpi/system/+/+" -v > "$temp_file" 2>/dev/null &
    local sub_pid=$!
    
    # Attendre et analyser
    sleep 5
    
    if [ -s "$temp_file" ]; then
        topics_received=$(wc -l < "$temp_file")
        print_status "Messages MQTT reçus" "OK" "$topics_received messages en 5s"
        
        # Analyser les topics reçus
        echo ""
        echo "Topics détectés:"
        cut -d' ' -f1 "$temp_file" | sort | uniq -c | sort -rn | head -10
        echo ""
        
        # Vérifier les topics spécifiques
        for topic in "${TOPICS_TO_TEST[@]}"; do
            if grep -q "^$topic " "$temp_file"; then
                local last_value=$(grep "^$topic " "$temp_file" | tail -1 | cut -d' ' -f2-)
                print_status "Topic $topic" "OK" "Dernière valeur: $last_value"
            else
                print_status "Topic $topic" "WARN" "Aucune donnée reçue"
            fi
        done
    else
        print_status "Messages MQTT reçus" "FAIL" "Aucun message reçu"
        ((errors++))
    fi
    
    # Nettoyer
    kill $sub_pid 2>/dev/null
    wait $sub_pid 2>/dev/null
    rm -f "$temp_file"
    
    return $errors
}

# Test 6: Performance
test_performance() {
    print_header "TEST 6: ANALYSE DE PERFORMANCE"
    
    # CPU usage du collecteur
    local pid=$(systemctl show -p MainPID "$SERVICE_NAME" | cut -d= -f2)
    if [ "$pid" != "0" ] && [ -n "$pid" ]; then
        # Mesurer sur 5 secondes
        local cpu_before=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        sleep 5
        local cpu_after=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        
        if [ -n "$cpu_after" ]; then
            print_status "Utilisation CPU du collecteur" "INFO" "${cpu_after}%"
            
            # Alerte si > 10%
            if (( $(echo "$cpu_after > 10" | bc -l 2>/dev/null || echo "0") )); then
                print_status "Consommation CPU" "WARN" "Élevée (> 10%)"
            else
                print_status "Consommation CPU" "OK" "Normale"
            fi
        fi
    else
        print_status "Analyse CPU" "WARN" "Impossible (service non actif)"
    fi
    
    # Fréquence des messages
    if command -v mosquitto_sub >/dev/null 2>&1; then
        echo ""
        echo "Analyse de la fréquence des messages (10s)..."
        
        local count_file="/tmp/mqtt_count_$$"
        timeout 10 mosquitto_sub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "rpi/system/+/+" -v 2>/dev/null | wc -l > "$count_file" &
        
        sleep 11
        local msg_count=$(cat "$count_file" 2>/dev/null || echo "0")
        local msg_per_sec=$((msg_count / 10))
        
        print_status "Fréquence des messages" "INFO" "$msg_count messages en 10s (~$msg_per_sec/s)"
        
        rm -f "$count_file"
    fi
    
    return 0
}

# Test de diagnostic complet
run_diagnostic() {
    print_header "DIAGNOSTIC COMPLET"
    
    echo ""
    echo "1. État des processus liés:"
    ps aux | grep -E "(mosquitto|collector\.py)" | grep -v grep
    
    echo ""
    echo "2. Ports réseau:"
    netstat -tlnp 2>/dev/null | grep -E "(1883|9001)" || ss -tlnp | grep -E "(1883|9001)"
    
    echo ""
    echo "3. Espace disque:"
    df -h /var/log
    
    echo ""
    echo "4. Connexions MQTT actives:"
    if command -v mosquitto_sub >/dev/null 2>&1; then
        timeout 2 mosquitto_sub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t '$SYS/broker/clients/connected' -C 1 2>/dev/null || echo "Impossible de récupérer l'info"
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           TEST DU WIDGET: $WIDGET_NAME                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Date: $(date)"
echo "Fichier de log: $TEST_LOG"
echo ""

# Vérifier les privilèges
if [ "$EUID" -ne 0 ]; then
    print_status "Privilèges root" "WARN" "Certains tests peuvent échouer"
fi

# Variables pour le résumé
total_errors=0
test_results=()

# Exécuter les tests
tests=(
    "test_installation"
    "test_dependencies"
    "test_service_status"
    "test_collector_logs"
    "test_mqtt_connection"
    "test_performance"
)

for test in "${tests[@]}"; do
    if $test; then
        test_results+=("$test: OK")
    else
        errors=$?
        total_errors=$((total_errors + errors))
        test_results+=("$test: FAIL ($errors erreurs)")
    fi
    echo ""
done

# Diagnostic supplémentaire si erreurs
if [ $total_errors -gt 0 ]; then
    run_diagnostic
fi

# Résumé final
print_header "RÉSUMÉ DES TESTS"

for result in "${test_results[@]}"; do
    echo "• $result"
done

echo ""
if [ $total_errors -eq 0 ]; then
    echo -e "${GREEN}✓ Tous les tests sont passés avec succès !${NC}"
    echo "Le widget $WIDGET_NAME fonctionne correctement."
else
    echo -e "${RED}✗ $total_errors erreur(s) détectée(s)${NC}"
    echo ""
    echo "Actions recommandées:"
    echo "1. Vérifier les logs: journalctl -u $SERVICE_NAME -n 50"
    echo "2. Vérifier le fichier: $COLLECTOR_LOG"
    echo "3. Redémarrer le service: systemctl restart $SERVICE_NAME"
    echo "4. Réinstaller si nécessaire: ./servermonitoring_uninstall.sh && ./servermonitoring_install.sh"
fi

echo ""
echo "Test terminé: $(date)"

exit $total_errors