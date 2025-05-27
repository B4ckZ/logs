#!/bin/bash

# ===============================================================================
# MAXLINK - TEST ET DIAGNOSTIC MQTT
# Script pour vérifier l'installation et diagnostiquer les problèmes
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des variables
source "$SCRIPT_DIR/../common/variables.sh"

# Variables MQTT
MQTT_USER="maxlink"
MQTT_PASS="mqtt"
MQTT_PORT="1883"
MQTT_WEBSOCKET_PORT="9001"

# ===============================================================================
# FONCTIONS DE TEST
# ===============================================================================

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fonction pour afficher le statut
print_status() {
    local test_name=$1
    local status=$2
    
    if [ "$status" = "OK" ]; then
        echo -e "${test_name}: ${GREEN}✓ OK${NC}"
    elif [ "$status" = "WARN" ]; then
        echo -e "${test_name}: ${YELLOW}⚠ ATTENTION${NC}"
    else
        echo -e "${test_name}: ${RED}✗ ERREUR${NC}"
    fi
}

# ===============================================================================
# TESTS
# ===============================================================================

echo "========================================================================"
echo "TEST ET DIAGNOSTIC MQTT MAXLINK"
echo "========================================================================"
echo ""

# Test 1 : Mosquitto installé
echo "1. Vérification de l'installation..."
if dpkg -l mosquitto >/dev/null 2>&1; then
    print_status "  Mosquitto installé" "OK"
else
    print_status "  Mosquitto installé" "FAIL"
    echo "    → Installer avec: sudo apt-get install mosquitto mosquitto-clients"
fi

# Test 2 : Fichiers de configuration
echo ""
echo "2. Vérification des fichiers de configuration..."

if [ -f "/etc/mosquitto/mosquitto.conf" ]; then
    print_status "  Fichier mosquitto.conf" "OK"
else
    print_status "  Fichier mosquitto.conf" "FAIL"
fi

if [ -f "/etc/mosquitto/passwords" ]; then
    print_status "  Fichier passwords" "OK"
    # Vérifier les permissions
    PERMS=$(stat -c %a /etc/mosquitto/passwords)
    OWNER=$(stat -c %U:%G /etc/mosquitto/passwords)
    if [ "$PERMS" = "600" ]; then
        print_status "  Permissions passwords (600)" "OK"
    else
        print_status "  Permissions passwords ($PERMS)" "WARN"
        echo "    → Corriger avec: sudo chmod 600 /etc/mosquitto/passwords"
    fi
    if [[ "$OWNER" == *"mosquitto"* ]]; then
        print_status "  Propriétaire passwords ($OWNER)" "OK"
    else
        print_status "  Propriétaire passwords ($OWNER)" "WARN"
        echo "    → Corriger avec: sudo chown mosquitto:mosquitto /etc/mosquitto/passwords"
    fi
else
    print_status "  Fichier passwords" "FAIL"
    echo "    → Le fichier d'authentification est manquant !"
fi

# Test 3 : Service Mosquitto
echo ""
echo "3. Vérification du service Mosquitto..."
if systemctl is-active --quiet mosquitto; then
    print_status "  Service mosquitto" "OK"
else
    print_status "  Service mosquitto" "FAIL"
    echo "    → Démarrer avec: sudo systemctl start mosquitto"
    echo "    → Voir les logs: sudo journalctl -u mosquitto -n 50"
fi

# Test 4 : Ports
echo ""
echo "4. Vérification des ports..."
if netstat -tlnp 2>/dev/null | grep -q ":$MQTT_PORT "; then
    print_status "  Port MQTT ($MQTT_PORT)" "OK"
else
    print_status "  Port MQTT ($MQTT_PORT)" "FAIL"
fi

if netstat -tlnp 2>/dev/null | grep -q ":$MQTT_WEBSOCKET_PORT "; then
    print_status "  Port WebSocket ($MQTT_WEBSOCKET_PORT)" "OK"
else
    print_status "  Port WebSocket ($MQTT_WEBSOCKET_PORT)" "FAIL"
fi

# Test 5 : Connexion MQTT
echo ""
echo "5. Test de connexion MQTT..."
if mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/connection" -m "test" 2>/dev/null; then
    print_status "  Connexion avec authentification" "OK"
else
    print_status "  Connexion avec authentification" "FAIL"
    echo "    → Vérifier le fichier passwords et les logs"
fi

# Test 6 : Collecteur système
echo ""
echo "6. Vérification du collecteur système..."

if [ -f "$BASE_DIR/scripts/collectors/system-metrics.py" ]; then
    print_status "  Script collecteur présent" "OK"
else
    print_status "  Script collecteur présent" "FAIL"
fi

if systemctl is-active --quiet maxlink-system-metrics; then
    print_status "  Service collecteur actif" "OK"
else
    print_status "  Service collecteur actif" "FAIL"
    echo "    → Démarrer avec: sudo systemctl start maxlink-system-metrics"
fi

# Test 7 : Réception des métriques
echo ""
echo "7. Test de réception des métriques..."
echo "   Attente de 5 secondes pour recevoir des données..."

RECEIVED=false
if timeout 5 mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "rpi/system/cpu/+" -C 1 >/dev/null 2>&1; then
    RECEIVED=true
fi

if [ "$RECEIVED" = true ]; then
    print_status "  Réception des métriques CPU" "OK"
    
    # Afficher un échantillon
    echo ""
    echo "   Échantillon de métriques reçues :"
    mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "rpi/system/+/+" -C 5 -W 2 2>/dev/null | while read topic message; do
        echo "     → $topic : $message"
    done
else
    print_status "  Réception des métriques CPU" "FAIL"
    echo "    → Vérifier que le collecteur est actif"
    echo "    → Voir les logs: sudo journalctl -u maxlink-system-metrics -n 20"
fi

# Test 8 : Configuration
echo ""
echo "8. Vérification de la configuration..."
if [ -f "/etc/maxlink/collectors.conf" ]; then
    print_status "  Fichier collectors.conf" "OK"
else
    print_status "  Fichier collectors.conf" "FAIL"
fi

# Résumé
echo ""
echo "========================================================================"
echo "RÉSUMÉ"
echo "========================================================================"
echo ""
echo "Commandes utiles :"
echo ""
echo "• Voir les logs Mosquitto :"
echo "  sudo journalctl -u mosquitto -f"
echo ""
echo "• Voir les logs du collecteur :"
echo "  sudo journalctl -u maxlink-system-metrics -f"
echo "  tail -f $LOG_DIR/collectors.log"
echo ""
echo "• Redémarrer les services :"
echo "  sudo systemctl restart mosquitto"
echo "  sudo systemctl restart maxlink-system-metrics"
echo ""
echo "• Écouter tous les topics MQTT :"
echo "  mosquitto_sub -h localhost -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PASS -t '#'"
echo ""
echo "• Publier un message test :"
echo "  mosquitto_pub -h localhost -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PASS -t 'test' -m 'Hello'"
echo ""

# Si des erreurs, proposer une réparation
if systemctl is-active --quiet mosquitto && systemctl is-active --quiet maxlink-system-metrics; then
    echo -e "${GREEN}✓ Tout semble fonctionnel !${NC}"
else
    echo -e "${YELLOW}⚠ Des problèmes ont été détectés.${NC}"
    echo ""
    echo "Voulez-vous tenter une réparation automatique ? (o/n)"
    read -r response
    if [[ "$response" =~ ^[Oo]$ ]]; then
        echo ""
        echo "Tentative de réparation..."
        
        # Créer le fichier passwords si manquant
        if [ ! -f "/etc/mosquitto/passwords" ]; then
            echo "• Création du fichier passwords..."
            sudo mosquitto_passwd -b -c /etc/mosquitto/passwords "$MQTT_USER" "$MQTT_PASS"
            sudo chmod 600 /etc/mosquitto/passwords
            sudo chown mosquitto:mosquitto /etc/mosquitto/passwords
        fi
        
        # Redémarrer les services
        echo "• Redémarrage des services..."
        sudo systemctl restart mosquitto
        sleep 2
        sudo systemctl restart maxlink-system-metrics
        
        echo ""
        echo "Réparation terminée. Relancez ce script pour vérifier."
    fi
fi