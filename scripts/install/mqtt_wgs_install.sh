#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT WIDGETS (VERSION OPTIMISÉE)
# Utilise le cache local - Installation rapide et fiable !
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des modules
source "$SCRIPT_DIR/../common/variables.sh"
source "$SCRIPT_DIR/../common/logging.sh"
source "$SCRIPT_DIR/../common/packages.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation MQTT Widgets (cache local)" "install"

# Répertoire des widgets
WIDGETS_DIR="$BASE_DIR/scripts/widgets"
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"

# Statistiques
TOTAL_WIDGETS=0
INSTALLED_WIDGETS=0
FAILED_WIDGETS=0
SKIPPED_WIDGETS=0

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Envoyer la progression
send_progress() {
    echo "PROGRESS:$1:$2"
    log_info "Progression: $1% - $2" false
}

# Attente simple
wait_silently() {
    sleep "$1"
}

# Vérifier si MQTT Broker est installé
check_mqtt_broker() {
    log_info "Vérification du broker MQTT"
    
    if ! systemctl is-active --quiet mosquitto; then
        log_error "Le broker MQTT (mosquitto) n'est pas actif"
        echo "  ↦ Le broker MQTT doit être installé et actif ✗"
        echo ""
        echo "Veuillez d'abord exécuter l'installation MQTT BKR"
        return 1
    fi
    
    # Test de connexion
    if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/wgs/check" -m "test" 2>/dev/null; then
        log_success "Connexion MQTT fonctionnelle"
        return 0
    else
        log_error "Impossible de se connecter au broker MQTT"
        echo "  ↦ Connexion au broker MQTT impossible ✗"
        return 1
    fi
}

# Scanner le répertoire des widgets (VERSION CORRIGÉE)
scan_widgets_directory() {
    log_info "Scan du répertoire des widgets: $WIDGETS_DIR"
    
    if [ ! -d "$WIDGETS_DIR" ]; then
        log_error "Répertoire des widgets non trouvé: $WIDGETS_DIR"
        echo "  ↦ Répertoire des widgets non trouvé ✗"
        return 1
    fi
    
    # Trouver tous les widgets valides
    local widgets=()
    
    # Utiliser find pour une recherche plus robuste
    while IFS= read -r widget_dir; do
        local widget_name=$(basename "$widget_dir")
        
        # Ignorer les fichiers qui ne sont pas des dossiers
        [ ! -d "$widget_dir" ] && continue
        
        # Chercher les fichiers requis
        local widget_json="$widget_dir/${widget_name}_widget.json"
        local install_script="$widget_dir/${widget_name}_install.sh"
        local test_script="$widget_dir/${widget_name}_test.sh"
        local uninstall_script="$widget_dir/${widget_name}_uninstall.sh"
        
        # Vérifier la structure complète
        if [ -f "$widget_json" ] && [ -f "$install_script" ] && [ -f "$test_script" ] && [ -f "$uninstall_script" ]; then
            widgets+=("$widget_name")
            log_info "Widget trouvé: $widget_name"
        else
            log_warn "Widget incomplet ignoré: $widget_name"
            if [ ! -f "$widget_json" ]; then
                log_warn "  - ${widget_name}_widget.json manquant"
            fi
            if [ ! -f "$install_script" ]; then
                log_warn "  - ${widget_name}_install.sh manquant"
            fi
            if [ ! -f "$test_script" ]; then
                log_warn "  - ${widget_name}_test.sh manquant"
            fi
            if [ ! -f "$uninstall_script" ]; then
                log_warn "  - ${widget_name}_uninstall.sh manquant"
            fi
        fi
    done < <(find "$WIDGETS_DIR" -maxdepth 1 -type d | grep -v "^$WIDGETS_DIR$")
    
    TOTAL_WIDGETS=${#widgets[@]}
    
    if [ $TOTAL_WIDGETS -eq 0 ]; then
        log_warn "Aucun widget valide trouvé"
        echo "  ↦ Aucun widget valide trouvé ⚠"
        return 1
    fi
    
    # Retourner la liste des widgets
    printf '%s\n' "${widgets[@]}"
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
    
    # Rendre le script exécutable
    chmod +x "$install_script"
    
    # Exécuter le script d'installation
    log_info "Exécution du script d'installation pour $widget_name"
    
    # Exécuter avec capture de la sortie
    if bash "$install_script"; then
        echo "  ↦ Widget $widget_name installé ✓"
        log_success "Widget $widget_name installé avec succès"
        ((INSTALLED_WIDGETS++))
        return 0
    else
        echo "  ↦ Erreur lors de l'installation ✗"
        log_error "Échec de l'installation du widget $widget_name"
        ((FAILED_WIDGETS++))
        return 1
    fi
}

# Installer les dépendances Python depuis le cache
install_python_dependencies() {
    log_info "Installation des dépendances Python depuis le cache"
    
    echo ""
    echo "◦ Installation des paquets Python..."
    
    # Installer les paquets Python depuis le cache
    if install_packages_by_category "python"; then
        echo "  ↦ Dépendances Python installées ✓"
        log_success "Dépendances Python installées depuis le cache"
        return 0
    else
        echo "  ↦ Certaines dépendances Python n'ont pas pu être installées ⚠"
        log_warn "Installation partielle des dépendances Python"
        
        # Essayer avec apt en fallback
        echo ""
        echo "◦ Tentative d'installation alternative..."
        if apt-get install -y python3-psutil python3-paho-mqtt >/dev/null 2>&1; then
            echo "  ↦ Dépendances installées via apt ✓"
            log_success "Dépendances Python installées via apt"
            return 0
        else
            log_error "Impossible d'installer les dépendances Python"
            return 1
        fi
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "========== DÉBUT DE L'INSTALLATION MQTT WIDGETS (OPTIMISÉE) =========="

echo ""
echo "========================================================================"
echo "INSTALLATION MQTT WIDGETS (WGS)"
echo "========================================================================"
echo ""

send_progress 5 "Initialisation..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    log_error "Privilèges root requis - EUID: $EUID"
    exit 1
fi
log_info "Privilèges root confirmés"

# Stabilisation initiale
echo "◦ Stabilisation du système..."
wait_silently 2
log_info "Stabilisation du système"

# ÉTAPE 1 : Vérifications
echo ""
echo "========================================================================"
echo "ÉTAPE 1 : VÉRIFICATIONS PRÉALABLES"
echo "========================================================================"
echo ""

send_progress 10 "Vérifications..."

# Vérifier le cache des paquets
echo "◦ Vérification du cache des paquets..."
if [ ! -d "$PACKAGE_CACHE_DIR" ] || [ ! -f "$PACKAGE_METADATA_FILE" ]; then
    echo "  ↦ Cache des paquets non trouvé ✗"
    echo ""
    echo "Veuillez d'abord exécuter update_install.sh pour télécharger les paquets"
    log_error "Cache des paquets non trouvé"
    exit 1
fi
echo "  ↦ Cache des paquets disponible ✓"
log_info "Cache des paquets trouvé"

# Vérifier le broker MQTT
echo ""
echo "◦ Vérification du broker MQTT..."
if ! check_mqtt_broker; then
    exit 1
fi
echo "  ↦ Broker MQTT actif et fonctionnel ✓"

echo ""
sleep 2

# ÉTAPE 2 : Scan des widgets
echo "========================================================================"
echo "ÉTAPE 2 : SCAN DES WIDGETS"
echo "========================================================================"
echo ""

send_progress 20 "Scan des widgets..."

echo "◦ Recherche des widgets disponibles..."

# Capturer la sortie de scan_widgets_directory dans un tableau
mapfile -t widgets_array < <(scan_widgets_directory)

if [ ${#widgets_array[@]} -eq 0 ]; then
    echo ""
    echo "Aucun widget à installer."
    log_warn "Aucun widget trouvé"
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

log_info "Widgets trouvés: ${widgets_array[*]}"

echo ""
sleep 2

# ÉTAPE 3 : Installation des dépendances Python
echo "========================================================================"
echo "ÉTAPE 3 : INSTALLATION DES DÉPENDANCES"
echo "========================================================================"
echo ""

send_progress 30 "Installation des dépendances..."

echo "◦ Installation des dépendances Python depuis le cache..."
install_python_dependencies

echo ""
sleep 2

# ÉTAPE 4 : Installation des widgets
echo "========================================================================"
echo "ÉTAPE 4 : INSTALLATION DES WIDGETS"
echo "========================================================================"

send_progress 40 "Installation des widgets..."

# Créer le répertoire de tracking si nécessaire
mkdir -p "$(dirname "$WIDGETS_TRACKING")"
[ ! -f "$WIDGETS_TRACKING" ] && echo "{}" > "$WIDGETS_TRACKING"

# Calculer la progression par widget
progress_per_widget=$((50 / TOTAL_WIDGETS))
current_progress=40

# Installer chaque widget
for widget in "${widgets_array[@]}"; do
    install_widget "$widget"
    
    # Mettre à jour la progression
    current_progress=$((current_progress + progress_per_widget))
    send_progress $current_progress "Installation: $widget"
    
    sleep 2
done

# ÉTAPE 5 : Tests post-installation
echo ""
echo "========================================================================"
echo "ÉTAPE 5 : TESTS POST-INSTALLATION"
echo "========================================================================"
echo ""

send_progress 90 "Tests des widgets..."

echo "◦ Vérification des services actifs..."
wait_silently 2

active_services=0
for widget in "${widgets_array[@]}"; do
    service_name="maxlink-widget-$widget"
    
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo "  ↦ $widget: ✓ actif"
        log_info "Service $service_name actif"
        ((active_services++))
    else
        echo "  ↦ $widget: ✗ inactif"
        log_warn "Service $service_name inactif"
    fi
done

echo ""
echo "Services actifs: $active_services/$TOTAL_WIDGETS"
log_info "Services actifs: $active_services/$TOTAL_WIDGETS"

# Test MQTT rapide
echo ""
echo "◦ Test de réception MQTT..."
if timeout 5 mosquitto_sub -h localhost -u maxlink -P mqtt -t "rpi/+/+/+" -C 1 >/dev/null 2>&1; then
    echo "  ↦ Messages MQTT reçus ✓"
    log_success "Messages MQTT reçus"
else
    echo "  ↦ Aucun message reçu (normal au démarrage) ⚠"
    log_info "Aucun message MQTT reçu immédiatement"
fi

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
    log_success "Installation MQTT WGS terminée avec succès"
else
    echo "⚠ Installation terminée avec $FAILED_WIDGETS erreur(s)"
    log_warn "Installation MQTT WGS terminée avec $FAILED_WIDGETS erreurs"
fi

echo ""
echo "Commandes utiles :"
echo "  • Tester un widget : bash $WIDGETS_DIR/<widget>/<widget>_test.sh"
echo "  • Voir les données MQTT : mosquitto_sub -h localhost -u maxlink -P mqtt -t 'rpi/+/+/+' -v"
echo "  • Voir les logs : journalctl -u 'maxlink-widget-*' -f"
echo "  • Désinstaller un widget : bash $WIDGETS_DIR/<widget>/<widget>_uninstall.sh"
echo ""

log_info "Résumé final - Installés: $INSTALLED_WIDGETS/$TOTAL_WIDGETS, Actifs: $active_services"

exit $FAILED_WIDGETS