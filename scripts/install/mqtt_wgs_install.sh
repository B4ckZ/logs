#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT WIDGETS (WGS)
# Script pour installer et connecter les widgets du dashboard au système MQTT
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
init_logging "Installation MQTT Widgets"

# Répertoire des widgets
WIDGETS_DIR="$BASE_DIR/scripts/widgets"
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"

# Variables pour la connexion WiFi
AP_WAS_ACTIVE=false
WIFI_NEEDED=false

# Statistiques
TOTAL_WIDGETS=0
INSTALLED_WIDGETS=0
FAILED_WIDGETS=0
SKIPPED_WIDGETS=0

# Temps de pause (suivre la même logique que les autres scripts)
PAUSE_COURT=2
PAUSE_MOYEN=5
PAUSE_LONG=10

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
}

# Pause avec message simple (même logique que update_install.sh)
pause_system() {
    local seconds=$1
    local message=$2
    [ -n "$message" ] && log_info "  ↦ $message..."
    sleep $seconds
}

# Vérifier si MQTT Broker est installé
check_mqtt_broker() {
    log_info "Vérification du broker MQTT..."
    
    if ! systemctl is-active --quiet mosquitto; then
        log_error "Le broker MQTT (mosquitto) n'est pas actif"
        echo "  ↦ Le broker MQTT doit être installé et actif ✗"
        echo ""
        echo "Veuillez d'abord exécuter l'installation MQTT BKR"
        return 1
    fi
    
    # Test de connexion
    if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/wgs/check" -m "test" 2>/dev/null; then
        log_info "Connexion MQTT fonctionnelle"
        return 0
    else
        log_error "Impossible de se connecter au broker MQTT"
        echo "  ↦ Connexion au broker MQTT impossible ✗"
        return 1
    fi
}

# Scanner le répertoire des widgets
scan_widgets_directory() {
    log_info "Scan du répertoire des widgets: $WIDGETS_DIR"
    
    if [ ! -d "$WIDGETS_DIR" ]; then
        log_error "Répertoire des widgets non trouvé: $WIDGETS_DIR"
        echo "  ↦ Répertoire des widgets non trouvé ✗"
        return 1
    fi
    
    # Trouver tous les widgets valides
    local widgets=()
    
    for widget_dir in "$WIDGETS_DIR"/*; do
        if [ -d "$widget_dir" ]; then
            local widget_name=$(basename "$widget_dir")
            local widget_json="$widget_dir/widget.json"
            local install_script="$widget_dir/${widget_name}_install.sh"
            local test_script="$widget_dir/${widget_name}_test.sh"
            local uninstall_script="$widget_dir/${widget_name}_uninstall.sh"
            
            # Vérifier la structure complète
            if [ -f "$widget_json" ] && [ -f "$install_script" ] && [ -f "$test_script" ] && [ -f "$uninstall_script" ]; then
                widgets+=("$widget_name")
                log_info "Widget trouvé: $widget_name"
            else
                log_warning "Widget incomplet ignoré: $widget_name"
                if [ ! -f "$widget_json" ]; then
                    log_warning "  - widget.json manquant"
                fi
                if [ ! -f "$install_script" ]; then
                    log_warning "  - ${widget_name}_install.sh manquant"
                fi
                if [ ! -f "$test_script" ]; then
                    log_warning "  - ${widget_name}_test.sh manquant"
                fi
                if [ ! -f "$uninstall_script" ]; then
                    log_warning "  - ${widget_name}_uninstall.sh manquant"
                fi
            fi
        fi
    done
    
    TOTAL_WIDGETS=${#widgets[@]}
    
    if [ $TOTAL_WIDGETS -eq 0 ]; then
        log_warning "Aucun widget valide trouvé"
        echo "  ↦ Aucun widget valide trouvé ⚠"
        return 1
    fi
    
    echo "${widgets[@]}"
    return 0
}

# Vérifier si un widget est déjà installé
is_widget_installed() {
    local widget_name=$1
    
    if [ -f "$WIDGETS_TRACKING" ]; then
        if grep -q "\"$widget_name\"" "$WIDGETS_TRACKING" 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Vérifier si des widgets nécessitent une connexion internet
check_dependencies_need_internet() {
    local widgets=("$@")
    
    for widget in "${widgets[@]}"; do
        local widget_json="$WIDGETS_DIR/$widget/widget.json"
        
        # Vérifier si le widget a des dépendances Python
        if grep -q "python_packages" "$widget_json" 2>/dev/null; then
            # Vérifier si les packages sont déjà installés
            local needs_install=false
            
            # Extraire les packages Python du JSON
            local packages=$(python3 -c "
import json
with open('$widget_json', 'r') as f:
    data = json.load(f)
    packages = data.get('dependencies', {}).get('python_packages', [])
    for pkg in packages:
        # Extraire le nom du package sans la version
        pkg_name = pkg.split('>=')[0].split('==')[0]
        print(pkg_name)
")
            
            # Vérifier chaque package
            while IFS= read -r package; do
                if [ -n "$package" ]; then
                    # Convertir le nom du package pour l'import Python
                    local python_module=$(echo "$package" | sed 's/-/_/g' | sed 's/paho.mqtt/paho.mqtt.client/')
                    
                    if ! python3 -c "import $python_module" 2>/dev/null; then
                        needs_install=true
                        log_info "Package Python manquant pour $widget: $package"
                        break
                    fi
                fi
            done <<< "$packages"
            
            if [ "$needs_install" = true ]; then
                return 0  # Internet nécessaire
            fi
        fi
    done
    
    return 1  # Pas besoin d'internet
}

# Installer un widget
install_widget() {
    local widget_name=$1
    local widget_dir="$WIDGETS_DIR/$widget_name"
    local install_script="$widget_dir/${widget_name}_install.sh"
    
    echo ""
    echo "Installation du widget: $widget_name"
    echo "------------------------------------"
    
    # Vérifier si déjà installé
    if is_widget_installed "$widget_name"; then
        echo "  ↦ Widget déjà installé, mise à jour..."
        log_info "Widget $widget_name déjà installé, mise à jour"
    fi
    
    # Exécuter le script d'installation
    if [ -x "$install_script" ]; then
        log_info "Exécution du script d'installation pour $widget_name"
        
        # Exécuter avec capture de la sortie
        if bash "$install_script"; then
            echo "  ↦ Widget $widget_name installé ✓"
            log_info "Widget $widget_name installé avec succès"
            ((INSTALLED_WIDGETS++))
            return 0
        else
            echo "  ↦ Erreur lors de l'installation ✗"
            log_error "Échec de l'installation du widget $widget_name"
            ((FAILED_WIDGETS++))
            return 1
        fi
    else
        echo "  ↦ Script d'installation non exécutable ✗"
        log_error "Script non exécutable: $install_script"
        ((FAILED_WIDGETS++))
        return 1
    fi
}

# Connecter au WiFi si nécessaire (suivre exactement la logique des autres scripts)
connect_wifi_if_needed() {
    # Vérifier la connectivité internet
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_info "Connectivité internet déjà disponible"
        return 0
    fi
    
    echo ""
    echo "◦ Connexion au réseau WiFi pour télécharger les dépendances..."
    
    # Désactiver le mode AP temporairement
    if nmcli con show --active | grep -q "$AP_SSID"; then
        AP_WAS_ACTIVE=true
        nmcli con down "$AP_SSID" >/dev/null 2>&1
        pause_system $PAUSE_COURT
        echo "  ↦ Mode AP désactivé temporairement ✓"
    fi
    
    # Scanner les réseaux
    echo "  ↦ Scan des réseaux disponibles..."
    nmcli device wifi rescan >/dev/null 2>&1
    pause_system $PAUSE_MOYEN
    
    # Vérifier la présence du réseau
    NETWORK_INFO=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
    if [ -n "$NETWORK_INFO" ]; then
        SIGNAL=$(echo "$NETWORK_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
        echo "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A} dBm) ✓"
    else
        echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
        log_error "Réseau $WIFI_SSID non trouvé"
        
        # Réactiver l'AP si nécessaire
        if [ "$AP_WAS_ACTIVE" = true ]; then
            nmcli con up "$AP_SSID" >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Supprimer l'ancienne connexion si elle existe
    nmcli connection delete "$WIFI_SSID" 2>/dev/null || true
    
    # Se connecter
    echo "  ↦ Connexion en cours..."
    if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
        echo "  ↦ Connexion initiée ✓"
        pause_system $PAUSE_MOYEN "Obtention de l'adresse IP"
        
        # Récupérer l'IP
        IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$IP" ]; then
            echo "  ↦ Connexion établie (IP: $IP) ✓"
            log_info "IP obtenue: $IP"
        else
            echo "  ↦ Connexion établie mais pas d'IP ⚠"
            log_warning "Pas d'IP obtenue"
        fi
        
        # Test de connectivité
        echo "  ↦ Test de connectivité..."
        pause_system $PAUSE_COURT "Stabilisation de la connexion"
        
        if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "  ↦ Connectivité Internet confirmée ✓"
            WIFI_NEEDED=true
            return 0
        else
            echo "  ↦ Pas de connectivité Internet ✗"
            log_error "Pas de connectivité Internet"
            
            # Déconnexion
            nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
            nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
            
            # Réactiver l'AP si nécessaire
            if [ "$AP_WAS_ACTIVE" = true ]; then
                nmcli con up "$AP_SSID" >/dev/null 2>&1
            fi
            return 1
        fi
    else
        echo "  ↦ Échec de la connexion ✗"
        log_error "Échec de la connexion WiFi"
        
        # Réactiver l'AP si nécessaire
        if [ "$AP_WAS_ACTIVE" = true ]; then
            nmcli con up "$AP_SSID" >/dev/null 2>&1
        fi
        
        return 1
    fi
}

# Déconnecter du WiFi et restaurer l'AP
disconnect_wifi_and_restore() {
    if [ "$WIFI_NEEDED" = true ]; then
        echo ""
        echo "◦ Déconnexion du WiFi..."
        
        nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
        pause_system $PAUSE_COURT
        nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
        echo "  ↦ WiFi déconnecté ✓"
    fi
    
    # Réactiver le mode AP si nécessaire
    if [ "$AP_WAS_ACTIVE" = true ]; then
        echo ""
        echo "◦ Réactivation du mode point d'accès..."
        nmcli con up "$AP_SSID" >/dev/null 2>&1
        pause_system $PAUSE_MOYEN
        echo "  ↦ Mode AP réactivé ✓"
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

echo ""
echo "========================================================================"
echo "INSTALLATION MQTT WIDGETS (WGS)"
echo "========================================================================"
echo ""

send_progress 5 "Initialisation..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    exit 1
fi

# Stabilisation initiale
echo "◦ Stabilisation du système..."
pause_system $PAUSE_MOYEN "Initialisation des services"

# ÉTAPE 1 : Vérification du broker MQTT
echo ""
echo "========================================================================"
echo "ÉTAPE 1 : VÉRIFICATION DU BROKER MQTT"
echo "========================================================================"
echo ""

send_progress 10 "Vérification du broker MQTT..."

echo "◦ Vérification du broker MQTT..."
if ! check_mqtt_broker; then
    exit 1
fi
echo "  ↦ Broker MQTT actif et fonctionnel ✓"

echo ""
sleep $PAUSE_COURT

# ÉTAPE 2 : Scan des widgets disponibles
echo "========================================================================"
echo "ÉTAPE 2 : SCAN DES WIDGETS"
echo "========================================================================"
echo ""

send_progress 20 "Scan des widgets..."

echo "◦ Recherche des widgets disponibles..."
widgets_array=($(scan_widgets_directory))

if [ ${#widgets_array[@]} -eq 0 ]; then
    echo ""
    echo "Aucun widget à installer."
    exit 0
fi

echo "  ↦ $TOTAL_WIDGETS widget(s) trouvé(s) ✓"
echo ""
echo "Widgets disponibles :"
for widget in "${widgets_array[@]}"; do
    if is_widget_installed "$widget"; then
        echo "  • $widget (installé)"
    else
        echo "  • $widget"
    fi
done

echo ""
sleep $PAUSE_COURT

# ÉTAPE 3 : Vérification des dépendances
echo "========================================================================"
echo "ÉTAPE 3 : ANALYSE DES DÉPENDANCES"
echo "========================================================================"
echo ""

send_progress 30 "Analyse des dépendances..."

echo "◦ Vérification des dépendances..."
if check_dependencies_need_internet "${widgets_array[@]}"; then
    echo "  ↦ Des dépendances doivent être téléchargées"
    
    # Se connecter au WiFi
    if ! connect_wifi_if_needed; then
        echo ""
        echo "Impossible de télécharger les dépendances sans connexion internet."
        exit 1
    fi
else
    echo "  ↦ Toutes les dépendances sont déjà installées ✓"
fi

echo ""
sleep $PAUSE_COURT

# ÉTAPE 4 : Installation des widgets
echo "========================================================================"
echo "ÉTAPE 4 : INSTALLATION DES WIDGETS"
echo "========================================================================"

send_progress 40 "Installation des widgets..."

# Calculer la progression par widget
progress_per_widget=$((50 / TOTAL_WIDGETS))
current_progress=40

# Installer chaque widget
for widget in "${widgets_array[@]}"; do
    install_widget "$widget"
    
    # Mettre à jour la progression
    current_progress=$((current_progress + progress_per_widget))
    send_progress $current_progress "Installation: $widget"
    
    sleep $PAUSE_COURT
done

# ÉTAPE 5 : Tests post-installation
echo ""
echo "========================================================================"
echo "ÉTAPE 5 : TESTS POST-INSTALLATION"
echo "========================================================================"
echo ""

send_progress 90 "Tests des widgets..."

echo "◦ Vérification des services actifs..."
pause_system $PAUSE_COURT

active_services=0
for widget in "${widgets_array[@]}"; do
    service_name="maxlink-widget-$widget"
    
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo "  ↦ $widget: ✓ actif"
        ((active_services++))
    else
        echo "  ↦ $widget: ✗ inactif"
    fi
done

echo ""
echo "Services actifs: $active_services/$TOTAL_WIDGETS"

# Déconnexion WiFi si nécessaire
disconnect_wifi_and_restore

send_progress 100 "Installation terminée"

# RÉSUMÉ
echo ""
echo "========================================================================"
echo "RÉSUMÉ DE L'INSTALLATION"
echo "========================================================================"
echo ""
echo "◦ Widgets trouvés    : $TOTAL_WIDGETS"
echo "◦ Widgets installés  : $INSTALLED_WIDGETS"
echo "◦ Widgets échoués    : $FAILED_WIDGETS"
echo "◦ Services actifs    : $active_services"
echo ""

if [ $FAILED_WIDGETS -eq 0 ]; then
    echo "✓ Installation terminée avec succès !"
else
    echo "⚠ Installation terminée avec $FAILED_WIDGETS erreur(s)"
    echo ""
    echo "Consultez les logs pour plus de détails :"
    echo "  $LOG_DIR/widgets/"
fi

echo ""
echo "Commandes utiles :"
echo "  • Tester tous les widgets : for w in ${widgets_array[@]}; do $WIDGETS_DIR/\$w/\${w}_test.sh; done"
echo "  • Voir les données MQTT : mosquitto_sub -h localhost -u maxlink -P mqtt -t 'rpi/+/+/+' -v"
echo "  • Voir les logs : journalctl -u 'maxlink-widget-*' -f"
echo ""

log_info "Installation MQTT WGS terminée - Widgets installés: $INSTALLED_WIDGETS/$TOTAL_WIDGETS"

exit $FAILED_WIDGETS