#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT MODULAIRE
# Version de base - Installe Mosquitto et gère les modules
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
init_logging "Installation MQTT et modules"

# Variables MQTT
MQTT_USER="${MQTT_USER:-maxlink}"
MQTT_PASS="${MQTT_PASS:-mqtt}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_WEBSOCKET_PORT="${MQTT_WEBSOCKET_PORT:-9001}"
MQTT_CONFIG_DIR="/etc/mosquitto"
MAXLINK_CONFIG_DIR="/etc/maxlink"

# Fichier de tracking des modules
MODULES_FILE="$MAXLINK_CONFIG_DIR/installed_modules.json"

# Variables pour la connexion WiFi
AP_WAS_ACTIVE=false

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
}

# Attente simple
wait_silently() {
    sleep "$1"
}

# Créer le fichier de tracking des modules
init_modules_tracking() {
    mkdir -p "$MAXLINK_CONFIG_DIR"
    if [ ! -f "$MODULES_FILE" ]; then
        echo "{}" > "$MODULES_FILE"
        log_info "Fichier de tracking des modules créé"
    fi
}

# Enregistrer un module installé
register_module() {
    local module_name=$1
    local module_version=$2
    local status=${3:-"active"}
    
    # Utiliser Python pour manipuler le JSON
    python3 -c "
import json
from datetime import datetime

with open('$MODULES_FILE', 'r') as f:
    modules = json.load(f)

modules['$module_name'] = {
    'version': '$module_version',
    'installed_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'status': '$status'
}

with open('$MODULES_FILE', 'w') as f:
    json.dump(modules, f, indent=2)
"
    log_info "Module $module_name enregistré"
}

# Vérifier si un module est installé
is_module_installed() {
    local module_name=$1
    python3 -c "
import json
import sys

try:
    with open('$MODULES_FILE', 'r') as f:
        modules = json.load(f)
    sys.exit(0 if '$module_name' in modules else 1)
except:
    sys.exit(1)
"
}

# ===============================================================================
# INSTALLATION DE BASE MOSQUITTO
# ===============================================================================

install_mosquitto_base() {
    echo "========================================================================"
    echo "INSTALLATION DU BROKER MQTT"
    echo "========================================================================"
    echo ""
    
    send_progress 20 "Installation de Mosquitto..."
    
    echo "◦ Vérification de Mosquitto..."
    if dpkg -l mosquitto >/dev/null 2>&1; then
        echo "  ↦ Mosquitto déjà installé ✓"
        log_info "Mosquitto déjà présent"
    else
        echo "  ↦ Installation de Mosquitto..."
        if apt-get update -qq && apt-get install -y mosquitto mosquitto-clients; then
            echo "  ↦ Mosquitto installé ✓"
            log_info "Mosquitto installé avec succès"
        else
            echo "  ↦ Erreur lors de l'installation ✗"
            log_error "Échec installation Mosquitto"
            return 1
        fi
    fi
    
    # Configuration de base
    echo ""
    echo "◦ Configuration de Mosquitto..."
    
    # Arrêter le service pour configuration
    systemctl stop mosquitto >/dev/null 2>&1
    
    # Créer le fichier de mots de passe
    rm -f "$MQTT_CONFIG_DIR/passwords"
    /usr/bin/mosquitto_passwd -b -c "$MQTT_CONFIG_DIR/passwords" "$MQTT_USER" "$MQTT_PASS"
    chmod 600 "$MQTT_CONFIG_DIR/passwords"
    chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
    echo "  ↦ Authentification configurée ✓"
    
    # Configuration principale
    cat > "$MQTT_CONFIG_DIR/mosquitto.conf" << EOF
# Configuration Mosquitto pour MaxLink
pid_file /var/run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log

# Authentification
allow_anonymous false
password_file $MQTT_CONFIG_DIR/passwords

# Listener standard
listener $MQTT_PORT
protocol mqtt

# Listener WebSocket pour le dashboard
listener $MQTT_WEBSOCKET_PORT
protocol websockets

# Logs
log_type error
log_type warning
log_type notice
log_type information
EOF
    
    echo "  ↦ Configuration créée ✓"
    
    # Démarrer Mosquitto
    echo ""
    echo "◦ Démarrage de Mosquitto..."
    systemctl enable mosquitto >/dev/null 2>&1
    if systemctl start mosquitto; then
        echo "  ↦ Mosquitto démarré ✓"
        register_module "mqtt_broker" "2.0.11" "active"
        return 0
    else
        echo "  ↦ Erreur au démarrage ✗"
        log_error "Mosquitto n'a pas pu démarrer"
        return 1
    fi
}

# ===============================================================================
# SÉLECTION ET INSTALLATION DES MODULES
# ===============================================================================

# Afficher la sélection des modules dans l'interface Python
select_modules() {
    echo "MODULE_SELECTION_REQUEST"
    
    # Attendre la réponse de l'interface Python
    local selection_file="/tmp/maxlink_mqtt_modules_selection"
    rm -f "$selection_file"
    
    # Attendre jusqu'à 60 secondes
    local count=0
    while [ ! -f "$selection_file" ] && [ $count -lt 60 ]; do
        sleep 1
        ((count++))
    done
    
    if [ -f "$selection_file" ]; then
        # Lire les modules sélectionnés
        selected_modules=$(cat "$selection_file")
        rm -f "$selection_file"
        echo "$selected_modules"
    else
        echo ""
    fi
}

# Installer un module spécifique
install_module() {
    local module_name=$1
    local module_script="$SCRIPT_DIR/modules/${module_name}/${module_name}_install.sh"
    
    echo ""
    echo "◦ Installation du module: $module_name"
    
    if [ ! -f "$module_script" ]; then
        echo "  ↦ Script d'installation non trouvé ✗"
        log_error "Script manquant pour $module_name: $module_script"
        return 1
    fi
    
    # Exécuter le script d'installation du module
    if bash "$module_script"; then
        echo "  ↦ Module installé ✓"
        return 0
    else
        echo "  ↦ Erreur d'installation ✗"
        return 1
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    exit 1
fi

echo ""
echo "========================================================================"
echo "INSTALLATION MQTT MAXLINK - VERSION MODULAIRE"
echo "========================================================================"
echo ""

# Initialiser le tracking des modules
init_modules_tracking

# ÉTAPE 1 : Préparer le système (WiFi, etc.)
echo "◦ Préparation du système..."
echo "  ↦ Initialisation..."
wait_silently 2

# Vérifier et désactiver le mode AP si actif
if nmcli con show --active | grep -q "$AP_SSID"; then
    AP_WAS_ACTIVE=true
    nmcli con down "$AP_SSID" >/dev/null 2>&1
    echo "  ↦ Mode AP désactivé temporairement ✓"
fi

send_progress 10 "Système préparé"

# ÉTAPE 2 : Installer Mosquitto de base
if ! is_module_installed "mqtt_broker"; then
    # Connexion WiFi pour télécharger
    echo ""
    echo "◦ Connexion au réseau WiFi..."
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1
    wait_silently 5
    
    if ! install_mosquitto_base; then
        echo ""
        echo "⚠ ERREUR CRITIQUE : Impossible d'installer Mosquitto"
        echo "L'installation ne peut pas continuer."
        
        # Réactiver l'AP si nécessaire
        if [ "$AP_WAS_ACTIVE" = true ]; then
            nmcli con up "$AP_SSID" >/dev/null 2>&1
        fi
        exit 1
    fi
    
    # Déconnexion WiFi
    nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
    nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
else
    echo "◦ Mosquitto déjà installé ✓"
    send_progress 30 "Mosquitto présent"
fi

# ÉTAPE 3 : Sélection des modules
echo ""
echo "========================================================================"
echo "SÉLECTION DES MODULES"
echo "========================================================================"
echo ""

send_progress 40 "Sélection des modules..."

# Demander la sélection à l'interface Python
selected_modules=$(select_modules)

if [ -z "$selected_modules" ]; then
    echo "◦ Aucun module sélectionné"
    echo ""
    echo "Installation de base terminée."
else
    echo "◦ Modules sélectionnés : $selected_modules"
    
    # ÉTAPE 4 : Installation des modules
    echo ""
    echo "========================================================================"
    echo "INSTALLATION DES MODULES"
    echo "========================================================================"
    
    # Connexion WiFi si des modules sont à installer
    echo ""
    echo "◦ Connexion au réseau WiFi..."
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1
    wait_silently 5
    
    # Installer chaque module
    IFS=',' read -ra MODULES <<< "$selected_modules"
    total_modules=${#MODULES[@]}
    current=0
    success=0
    failed=0
    
    for module in "${MODULES[@]}"; do
        ((current++))
        progress=$((40 + (current * 40 / total_modules)))
        send_progress $progress "Installation: $module"
        
        if install_module "$module"; then
            ((success++))
        else
            ((failed++))
        fi
    done
    
    # Déconnexion WiFi
    nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
    nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
    
    # Résumé
    echo ""
    echo "========================================================================"
    echo "RÉSUMÉ DE L'INSTALLATION"
    echo "========================================================================"
    echo "◦ Modules installés : $success"
    echo "◦ Échecs : $failed"
fi

# Réactiver le mode AP si nécessaire
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    nmcli con up "$AP_SSID" >/dev/null 2>&1
    echo "  ↦ Mode AP réactivé ✓"
fi

send_progress 100 "Installation terminée"

echo ""
echo "◦ Installation terminée !"
echo "  ↦ Logs : $LOG_DIR/"
echo ""

# Redémarrage
echo "  ↦ Redémarrage dans 10 secondes..."
sleep 10
reboot