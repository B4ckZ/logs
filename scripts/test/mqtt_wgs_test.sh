#!/bin/bash

# ===============================================================================
# MAXLINK - TEST MQTT WIDGETS (WGS)
# Test et diagnostic de l'installation des widgets MQTT
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables
source "$SCRIPT_DIR/../common/variables.sh"

# Configuration
WIDGETS_DIR="$BASE_DIR/scripts/widgets"
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===============================================================================
# FONCTIONS
# ===============================================================================

print_header() {
    echo ""
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
    echo ""
}

print_status() {
    local test_name=$1
    local status=$2
    local message=${3:-""}
    
    printf "%-50s" "$test_name"
    
    case "$status" in
        "OK")
            echo -e "${GREEN}✓ OK${NC} $message"
            ;;
        "FAIL")
            echo -e "${RED}✗ FAIL${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}⚠ WARN${NC} $message"
            ;;
        "INFO")
            echo -e "${BLUE}ℹ INFO${NC} $message"
            ;;
    esac
}

# Test de la structure des widgets
test_widgets_structure() {
    print_header "TEST 1: STRUCTURE DES WIDGETS"
    
    local errors=0
    local widgets_found=0
    
    # Vérifier le répertoire
    if [ ! -d "$WIDGETS_DIR" ]; then
        print_status "Répertoire des widgets" "FAIL" "$WIDGETS_DIR non trouvé"
        return 1
    else
        print_status "Répertoire des widgets" "OK" "$WIDGETS_DIR"
    fi
    
    # Scanner les widgets
    for widget_dir in "$WIDGETS_DIR"/*; do
        if [ -d "$widget_dir" ]; then
            local widget_name=$(basename "$widget_dir")
            ((widgets_found++))
            
            echo ""
            echo "Widget: $widget_name"
            echo "------------------------"
            
            # Vérifier les fichiers requis
            local files_ok=true
            
            # widget.json
            if [ -f "$widget_dir/widget.json" ]; then
                print_status "  widget.json" "OK"
            else
                print_status "  widget.json" "FAIL" "Manquant"
                files_ok=false
                ((errors++))
            fi
            
            # Scripts
            for script in "install" "test" "uninstall"; do
                if [ -f "$widget_dir/${widget_name}_${script}.sh" ]; then
                    if [ -x "$widget_dir/${widget_name}_${script}.sh" ]; then
                        print_status "  ${widget_name}_${script}.sh" "OK" "Exécutable"
                    else
                        print_status "  ${widget_name}_${script}.sh" "WARN" "Non exécutable"
                    fi
                else
                    print_status "  ${widget_name}_${script}.sh" "FAIL" "Manquant"
                    files_ok=false
                    ((errors++))
                fi
            done
            
            if [ "$files_ok" = true ]; then
                echo "  → Widget structure: ✓ Complète"
            else
                echo "  → Widget structure: ✗ Incomplète"
            fi
        fi
    done
    
    echo ""
    print_status "Total widgets trouvés" "INFO" "$widgets_found"
    
    return $errors
}

# Test du tracking des widgets
test_widgets_tracking() {
    print_header "TEST 2: TRACKING DES WIDGETS"
    
    # Vérifier le fichier de tracking
    if [ ! -f "$WIDGETS_TRACKING" ]; then
        print_status "Fichier de tracking" "WARN" "Non trouvé"
        return 1
    else
        print_status "Fichier de tracking" "OK" "$WIDGETS_TRACKING"
    fi
    
    # Analyser le contenu
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
try:
    with open('$WIDGETS_TRACKING', 'r') as f:
        data = json.load(f)
    
    print('\nWidgets installés:')
    print('-----------------')
    
    if not data:
        print('  Aucun widget installé')
    else:
        for widget_id, info in data.items():
            print(f\"  • {widget_id}:\")
            print(f\"    - Version: {info.get('version', 'N/A')}\")
            print(f\"    - Date: {info.get('installed_date', 'N/A')}\")
            print(f\"    - Status: {info.get('status', 'N/A')}\")
            print(f\"    - Service: {info.get('service', 'N/A')}\")
            
except Exception as e:
    print(f'Erreur: {e}')
"
    fi
    
    return 0
}

# Test des services systemd
test_widgets_services() {
    print_header "TEST 3: SERVICES SYSTEMD"
    
    local active_count=0
    local total_count=0
    
    # Lister tous les services maxlink-widget-*
    local services=$(systemctl list-units --all --no-pager | grep "maxlink-widget-" | awk '{print $1}')
    
    if [ -z "$services" ]; then
        print_status "Services trouvés" "WARN" "Aucun service maxlink-widget-* trouvé"
        return 1
    fi
    
    # Tester chaque service
    while IFS= read -r service; do
        if [ -n "$service" ]; then
            ((total_count++))
            
            # État du service
            if systemctl is-active --quiet "$service"; then
                print_status "$service" "OK" "Actif"
                ((active_count++))
                
                # Afficher quelques infos supplémentaires
                local mem=$(systemctl show -p MemoryCurrent "$service" | cut -d= -f2)
                if [ "$mem" != "[not set]" ] && [ -n "$mem" ]; then
                    local mem_mb=$((mem / 1024 / 1024))
                    echo "    → Mémoire: ${mem_mb}MB"
                fi
                
                local restarts=$(systemctl show -p NRestarts "$service" | cut -d= -f2)
                if [ "$restarts" -gt 0 ]; then
                    echo "    → Redémarrages: $restarts"
                fi
            else
                print_status "$service" "FAIL" "Inactif"
                
                # Raison de l'échec
                local exit_code=$(systemctl show -p ExecMainCode "$service" | cut -d= -f2)
                if [ "$exit_code" != "0" ]; then
                    echo "    → Code de sortie: $exit_code"
                fi
            fi
        fi
    done <<< "$services"
    
    echo ""
    print_status "Services actifs" "INFO" "$active_count/$total_count"
    
    return 0
}

# Test MQTT
test_mqtt_data() {
    print_header "TEST 4: DONNÉES MQTT"
    
    # Vérifier mosquitto_sub
    if ! command -v mosquitto_sub >/dev/null 2>&1; then
        print_status "Client mosquitto_sub" "FAIL" "Non disponible"
        return 1
    fi
    
    print_status "Client mosquitto_sub" "OK"
    
    # Test de connexion au broker
    echo ""
    echo "Test de connexion au broker..."
    if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/wgs" -m "test" 2>/dev/null; then
        print_status "Connexion au broker" "OK"
    else
        print_status "Connexion au broker" "FAIL"
        return 1
    fi
    
    # Collecter des données pendant 5 secondes
    echo ""
    echo "Collecte des données MQTT (5 secondes)..."
    
    local temp_file="/tmp/mqtt_wgs_test_$$"
    timeout 5 mosquitto_sub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "rpi/+/+/+" -v > "$temp_file" 2>/dev/null
    
    if [ -s "$temp_file" ]; then
        local msg_count=$(wc -l < "$temp_file")
        print_status "Messages reçus" "OK" "$msg_count messages en 5s"
        
        echo ""
        echo "Topics détectés:"
        echo "---------------"
        cut -d' ' -f1 "$temp_file" | sort | uniq -c | sort -rn
        
        echo ""
        echo "Échantillon de données:"
        echo "----------------------"
        head -10 "$temp_file"
        
    else
        print_status "Messages reçus" "FAIL" "Aucun message"
    fi
    
    rm -f "$temp_file"
    
    return 0
}

# Test des logs
test_widgets_logs() {
    print_header "TEST 5: ANALYSE DES LOGS"
    
    local log_dir="/var/log/maxlink/widgets"
    
    if [ ! -d "$log_dir" ]; then
        print_status "Répertoire de logs" "WARN" "Non trouvé"
        return 1
    else
        print_status "Répertoire de logs" "OK" "$log_dir"
    fi
    
    # Analyser chaque fichier de log
    echo ""
    echo "Fichiers de log trouvés:"
    echo "-----------------------"
    
    for log_file in "$log_dir"/*.log; do
        if [ -f "$log_file" ]; then
            local filename=$(basename "$log_file")
            local size=$(du -h "$log_file" | cut -f1)
            local lines=$(wc -l < "$log_file")
            local errors=$(grep -c "ERROR" "$log_file" 2>/dev/null || echo "0")
            
            echo ""
            echo "• $filename"
            echo "  - Taille: $size"
            echo "  - Lignes: $lines"
            
            if [ $errors -gt 0 ]; then
                echo "  - Erreurs: $errors ⚠"
                echo "  - Dernière erreur:"
                grep "ERROR" "$log_file" | tail -1 | sed 's/^/    /'
            else
                echo "  - Erreurs: 0 ✓"
            fi
        fi
    done
    
    return 0
}

# Diagnostic rapide
run_quick_diagnostic() {
    print_header "DIAGNOSTIC RAPIDE"
    
    echo "1. Processus Python actifs:"
    ps aux | grep -E "python3.*collector\.py" | grep -v grep || echo "  Aucun processus collecteur trouvé"
    
    echo ""
    echo "2. Utilisation mémoire totale des widgets:"
    local total_mem=0
    for pid in $(pgrep -f "python3.*collector\.py"); do
        if [ -f "/proc/$pid/status" ]; then
            local mem_kb=$(grep VmRSS /proc/$pid/status | awk '{print $2}')
            total_mem=$((total_mem + mem_kb))
        fi
    done
    echo "  Total: $((total_mem / 1024)) MB"
    
    echo ""
    echo "3. Ports MQTT:"
    netstat -tlnp 2>/dev/null | grep -E "(1883|9001)" || ss -tlnp | grep -E "(1883|9001)"
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              TEST MQTT WIDGETS (WGS)                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Date: $(date)"
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
    "test_widgets_structure"
    "test_widgets_tracking"
    "test_widgets_services"
    "test_mqtt_data"
    "test_widgets_logs"
)

for test in "${tests[@]}"; do
    if $test; then
        test_results+=("$test: OK")
    else
        errors=$?
        total_errors=$((total_errors + errors))
        test_results+=("$test: FAIL")
    fi
done

# Diagnostic si demandé
if [ "$1" = "--diag" ] || [ "$1" = "-d" ]; then
    run_quick_diagnostic
fi

# Résumé
print_header "RÉSUMÉ"

for result in "${test_results[@]}"; do
    echo "• $result"
done

echo ""
if [ $total_errors -eq 0 ]; then
    echo -e "${GREEN}✓ Tous les tests sont passés !${NC}"
    echo "Le système MQTT Widgets fonctionne correctement."
else
    echo -e "${RED}✗ $total_errors problème(s) détecté(s)${NC}"
fi

echo ""
echo "Pour plus de détails, utilisez:"
echo "  • $0 --diag    pour un diagnostic complet"
echo "  • journalctl -u 'maxlink-widget-*' -f    pour voir les logs en temps réel"
echo ""

exit $total_errors