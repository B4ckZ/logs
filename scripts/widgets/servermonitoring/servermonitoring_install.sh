#!/bin/bash

# ===============================================================================
# WIDGET SERVER MONITORING - SCRIPT D'INSTALLATION
# Widget pour collecter et envoyer les métriques système via MQTT
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
WIDGET_VERSION="1.0.0"

# Fichiers et chemins
CONFIG_FILE="$WIDGET_DIR/widget.json"
COLLECTOR_SCRIPT="$WIDGET_DIR/collector.py"
SERVICE_NAME="maxlink-widget-servermonitoring"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Logs
LOG_DIR="$BASE_DIR/logs"
INSTALL_LOG="$LOG_DIR/widgets/${WIDGET_ID}_install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR/widgets"

# Fichier de tracking
WIDGETS_TRACKING="/etc/maxlink/widgets_installed.json"
mkdir -p "$(dirname "$WIDGETS_TRACKING")"

# ===============================================================================
# FONCTIONS DE LOGGING
# ===============================================================================

# Initialiser le log
exec 1> >(tee -a "$INSTALL_LOG")
exec 2>&1

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

log_info() {
    log "INFO" "$1"
}

log_error() {
    log "ERROR" "$1"
}

log_success() {
    log "SUCCESS" "$1"
}

log_warning() {
    log "WARNING" "$1"
}

# ===============================================================================
# FONCTIONS UTILITAIRES
# ===============================================================================

# Vérifier si MQTT est installé et actif
check_mqtt_broker() {
    log_info "Vérification du broker MQTT..."
    
    # Vérifier si Mosquitto est installé
    if ! dpkg -l mosquitto >/dev/null 2>&1; then
        log_error "Mosquitto n'est pas installé"
        return 1
    fi
    
    # Vérifier si le service est actif
    if ! systemctl is-active --quiet mosquitto; then
        log_warning "Mosquitto n'est pas actif, tentative de démarrage..."
        if systemctl start mosquitto; then
            log_success "Mosquitto démarré"
        else
            log_error "Impossible de démarrer Mosquitto"
            return 1
        fi
    else
        log_success "Mosquitto est actif"
    fi
    
    # Tester la connexion
    if command -v mosquitto_pub >/dev/null 2>&1; then
        if mosquitto_pub -h localhost -p 1883 -u "maxlink" -P "mqtt" -t "test/widget/install" -m "test" 2>/dev/null; then
            log_success "Connexion MQTT fonctionnelle"
            return 0
        else
            log_error "Impossible de se connecter au broker MQTT"
            return 1
        fi
    else
        log_warning "mosquitto_pub non disponible, impossible de tester la connexion"
        return 0
    fi
}

# Vérifier les dépendances Python
check_python_dependencies() {
    log_info "Vérification des dépendances Python..."
    
    # Vérifier Python3
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "Python3 n'est pas installé"
        return 1
    fi
    
    local python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    log_info "Python version: $python_version"
    
    # Vérifier les modules
    local missing_modules=()
    
    if ! python3 -c "import psutil" 2>/dev/null; then
        missing_modules+=("psutil")
    fi
    
    if ! python3 -c "import paho.mqtt.client" 2>/dev/null; then
        missing_modules+=("paho-mqtt")
    fi
    
    if [ ${#missing_modules[@]} -gt 0 ]; then
        log_warning "Modules Python manquants: ${missing_modules[*]}"
        return 1
    else
        log_success "Toutes les dépendances Python sont présentes"
        return 0
    fi
}

# Installer les dépendances manquantes
install_dependencies() {
    log_info "Installation des dépendances..."
    
    # Se connecter au WiFi si nécessaire
    local wifi_connected=false
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_info "Connexion au réseau WiFi pour télécharger les dépendances..."
        
        # Désactiver le mode AP temporairement
        if nmcli con show --active | grep -q "$AP_SSID"; then
            nmcli con down "$AP_SSID" >/dev/null 2>&1
            log_info "Mode AP désactivé temporairement"
        fi
        
        # Se connecter au WiFi
        if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
            wifi_connected=true
            log_success "Connecté au WiFi"
            sleep 5
        else
            log_error "Impossible de se connecter au WiFi"
            return 1
        fi
    fi
    
    # Installer les paquets Python
    log_info "Installation des paquets Python..."
    
    if apt-get update -qq && apt-get install -y python3-psutil python3-paho-mqtt; then
        log_success "Paquets Python installés"
    else
        log_error "Erreur lors de l'installation des paquets"
        return 1
    fi
    
    # Se déconnecter du WiFi si on s'est connecté
    if [ "$wifi_connected" = true ]; then
        nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
        nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
        log_info "Déconnecté du WiFi"
        
        # Réactiver le mode AP
        nmcli con up "$AP_SSID" >/dev/null 2>&1
        log_info "Mode AP réactivé"
    fi
    
    return 0
}

# Créer le script collecteur
create_collector_script() {
    log_info "Création du script collecteur..."
    
    cat > "$COLLECTOR_SCRIPT" << 'EOF'
#!/usr/bin/env python3
"""
Collecteur de métriques système pour le widget Server Monitoring
Envoie les données via MQTT au dashboard MaxLink
"""

import os
import sys
import time
import json
import logging
import psutil
from datetime import datetime
from pathlib import Path

# Configuration du logging
log_file = "/var/log/maxlink/widgets/servermonitoring_collector.log"
Path(log_file).parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

try:
    import paho.mqtt.client as mqtt
except ImportError:
    logger.error("Module paho-mqtt non installé")
    sys.exit(1)

class SystemMetricsCollector:
    def __init__(self, config_file):
        """Initialise le collecteur avec la configuration du widget"""
        self.config = self.load_config(config_file)
        self.mqtt_client = None
        self.connected = False
        
        # Intervalles de mise à jour
        self.intervals = self.config['collector']['update_intervals']
        self.last_update = {
            'fast': 0,
            'normal': 0,
            'slow': 0
        }
        
    def load_config(self, config_file):
        """Charge la configuration depuis widget.json"""
        try:
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Erreur chargement config: {e}")
            sys.exit(1)
    
    def connect_mqtt(self):
        """Connexion au broker MQTT"""
        try:
            broker = self.config['mqtt']['broker']
            self.mqtt_client = mqtt.Client()
            
            # Callbacks
            self.mqtt_client.on_connect = self.on_connect
            self.mqtt_client.on_disconnect = self.on_disconnect
            
            # Authentification
            self.mqtt_client.username_pw_set(
                broker['username'],
                broker['password']
            )
            
            # Connexion
            logger.info(f"Connexion à {broker['host']}:{broker['port']}")
            self.mqtt_client.connect(broker['host'], broker['port'], 60)
            self.mqtt_client.loop_start()
            
            # Attendre la connexion
            timeout = 10
            while not self.connected and timeout > 0:
                time.sleep(0.5)
                timeout -= 0.5
            
            if not self.connected:
                logger.error("Timeout de connexion MQTT")
                return False
                
            return True
            
        except Exception as e:
            logger.error(f"Erreur connexion MQTT: {e}")
            return False
    
    def on_connect(self, client, userdata, flags, rc):
        """Callback de connexion"""
        if rc == 0:
            logger.info("Connecté au broker MQTT")
            self.connected = True
        else:
            logger.error(f"Échec connexion MQTT, code: {rc}")
            self.connected = False
    
    def on_disconnect(self, client, userdata, rc):
        """Callback de déconnexion"""
        logger.warning("Déconnecté du broker MQTT")
        self.connected = False
    
    def publish_metric(self, topic, value, unit=None):
        """Publie une métrique sur MQTT"""
        if not self.connected:
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "value": value
            }
            
            if unit:
                payload["unit"] = unit
            
            result = self.mqtt_client.publish(topic, json.dumps(payload))
            return result.rc == 0
            
        except Exception as e:
            logger.error(f"Erreur publication: {e}")
            return False
    
    def collect_cpu_metrics(self):
        """Collecte les métriques CPU"""
        try:
            # Usage par core
            cpu_percents = psutil.cpu_percent(interval=0.1, percpu=True)
            for i, percent in enumerate(cpu_percents, 1):
                topic = f"rpi/system/cpu/core{i}"
                self.publish_metric(topic, round(percent, 1), "%")
                logger.debug(f"CPU Core {i}: {percent:.1f}%")
                
        except Exception as e:
            logger.error(f"Erreur collecte CPU: {e}")
    
    def collect_temperature_metrics(self):
        """Collecte les températures"""
        try:
            # Température CPU (Raspberry Pi)
            temp_file = "/sys/class/thermal/thermal_zone0/temp"
            if os.path.exists(temp_file):
                with open(temp_file, 'r') as f:
                    temp_c = float(f.read().strip()) / 1000.0
                    
                self.publish_metric("rpi/system/temperature/cpu", round(temp_c, 1), "°C")
                # GPU = CPU sur Raspberry Pi
                self.publish_metric("rpi/system/temperature/gpu", round(temp_c, 1), "°C")
                logger.debug(f"Température: {temp_c:.1f}°C")
                
        except Exception as e:
            logger.error(f"Erreur collecte température: {e}")
    
    def collect_frequency_metrics(self):
        """Collecte les fréquences"""
        try:
            # Fréquence CPU
            cpu_freq = psutil.cpu_freq()
            if cpu_freq:
                freq_ghz = round(cpu_freq.current / 1000, 2)
                self.publish_metric("rpi/system/frequency/cpu", freq_ghz, "GHz")
                logger.debug(f"CPU Freq: {freq_ghz} GHz")
            
            # Fréquence GPU (spécifique Raspberry Pi)
            gpu_freq_file = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if os.path.exists(gpu_freq_file):
                with open(gpu_freq_file, 'r') as f:
                    freq_khz = float(f.read().strip())
                    freq_mhz = round(freq_khz / 1000, 0)
                    self.publish_metric("rpi/system/frequency/gpu", freq_mhz, "MHz")
                    
        except Exception as e:
            logger.error(f"Erreur collecte fréquences: {e}")
    
    def collect_memory_metrics(self):
        """Collecte les métriques mémoire"""
        try:
            # RAM
            ram = psutil.virtual_memory()
            self.publish_metric("rpi/system/memory/ram", round(ram.percent, 1), "%")
            logger.debug(f"RAM: {ram.percent:.1f}%")
            
            # SWAP
            swap = psutil.swap_memory()
            self.publish_metric("rpi/system/memory/swap", round(swap.percent, 1), "%")
            
            # Disque
            disk = psutil.disk_usage('/')
            self.publish_metric("rpi/system/memory/disk", round(disk.percent, 1), "%")
            logger.debug(f"Disk: {disk.percent:.1f}%")
            
        except Exception as e:
            logger.error(f"Erreur collecte mémoire: {e}")
    
    def collect_uptime_metrics(self):
        """Collecte l'uptime"""
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = int(float(f.readline().split()[0]))
                self.publish_metric("rpi/system/uptime", uptime_seconds, "seconds")
                logger.debug(f"Uptime: {uptime_seconds}s")
                
        except Exception as e:
            logger.error(f"Erreur collecte uptime: {e}")
    
    def run(self):
        """Boucle principale du collecteur"""
        logger.info("Démarrage du collecteur Server Monitoring")
        
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT")
            return
        
        logger.info("Collecteur démarré avec succès")
        
        try:
            while True:
                current_time = time.time()
                
                # Groupe rapide (CPU, RAM)
                if current_time - self.last_update['fast'] >= self.intervals['fast']:
                    self.collect_cpu_metrics()
                    self.collect_memory_metrics()  # RAM seulement
                    self.last_update['fast'] = current_time
                
                # Groupe normal (Températures, Fréquences)
                if current_time - self.last_update['normal'] >= self.intervals['normal']:
                    self.collect_temperature_metrics()
                    self.collect_frequency_metrics()
                    self.last_update['normal'] = current_time
                
                # Groupe lent (SWAP, Disk, Uptime)
                if current_time - self.last_update['slow'] >= self.intervals['slow']:
                    self.collect_memory_metrics()  # Toutes les métriques
                    self.collect_uptime_metrics()
                    self.last_update['slow'] = current_time
                
                # Pause pour éviter la surcharge CPU
                time.sleep(0.1)
                
        except KeyboardInterrupt:
            logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            logger.error(f"Erreur dans la boucle principale: {e}")
        finally:
            if self.mqtt_client:
                self.mqtt_client.loop_stop()
                self.mqtt_client.disconnect()
            logger.info("Collecteur arrêté")

if __name__ == "__main__":
    # Chemin vers widget.json
    widget_dir = os.path.dirname(os.path.abspath(__file__))
    config_file = os.path.join(widget_dir, "widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    # Lancer le collecteur
    collector = SystemMetricsCollector(config_file)
    collector.run()
EOF

    chmod +x "$COLLECTOR_SCRIPT"
    log_success "Script collecteur créé"
}

# Créer le service systemd
create_systemd_service() {
    log_info "Création du service systemd..."
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=MaxLink Server Monitoring Widget Collector
After=mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $COLLECTOR_SCRIPT
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

# Environnement
Environment="PYTHONUNBUFFERED=1"

# Limites
LimitNOFILE=4096

# Sécurité
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    log_success "Service systemd créé"
}

# Enregistrer le widget comme installé
register_widget_installation() {
    log_info "Enregistrement du widget..."
    
    # Créer le fichier s'il n'existe pas
    if [ ! -f "$WIDGETS_TRACKING" ]; then
        echo "{}" > "$WIDGETS_TRACKING"
    fi
    
    # Ajouter l'entrée via Python
    python3 -c "
import json
from datetime import datetime

with open('$WIDGETS_TRACKING', 'r') as f:
    widgets = json.load(f)

widgets['$WIDGET_ID'] = {
    'name': '$WIDGET_NAME',
    'version': '$WIDGET_VERSION',
    'installed_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'status': 'active',
    'service': '$SERVICE_NAME',
    'config_file': '$CONFIG_FILE'
}

with open('$WIDGETS_TRACKING', 'w') as f:
    json.dump(widgets, f, indent=2)
"
    
    log_success "Widget enregistré dans le tracking"
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

log_info "=========================================="
log_info "Installation du widget: $WIDGET_NAME v$WIDGET_VERSION"
log_info "=========================================="
log_info "Heure de début: $(date)"
log_info "Répertoire du widget: $WIDGET_DIR"
log_info "Fichier de log: $INSTALL_LOG"

# Étape 1: Vérifications préalables
log_info ""
log_info "=== ÉTAPE 1: VÉRIFICATIONS PRÉALABLES ==="

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    log_error "Ce script doit être exécuté avec des privilèges root"
    exit 1
fi
log_success "Privilèges root confirmés"

# Vérifier l'existence de widget.json
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Fichier de configuration widget.json non trouvé"
    exit 1
fi
log_success "Fichier widget.json trouvé"

# Vérifier MQTT
if ! check_mqtt_broker; then
    log_error "Le broker MQTT doit être installé et actif avant d'installer ce widget"
    exit 1
fi

# Étape 2: Dépendances
log_info ""
log_info "=== ÉTAPE 2: GESTION DES DÉPENDANCES ==="

if ! check_python_dependencies; then
    log_info "Installation des dépendances nécessaires..."
    if ! install_dependencies; then
        log_error "Impossible d'installer les dépendances"
        exit 1
    fi
    
    # Revérifier après installation
    if ! check_python_dependencies; then
        log_error "Les dépendances n'ont pas pu être installées correctement"
        exit 1
    fi
fi

# Étape 3: Création des composants
log_info ""
log_info "=== ÉTAPE 3: CRÉATION DES COMPOSANTS ==="

# Créer le répertoire de logs pour le widget
mkdir -p "/var/log/maxlink/widgets"
log_success "Répertoire de logs créé"

# Créer le script collecteur
create_collector_script

# Créer le service systemd
create_systemd_service

# Étape 4: Activation du service
log_info ""
log_info "=== ÉTAPE 4: ACTIVATION DU SERVICE ==="

# Recharger systemd
systemctl daemon-reload
log_success "Configuration systemd rechargée"

# Activer le service
if systemctl enable "$SERVICE_NAME"; then
    log_success "Service activé au démarrage"
else
    log_error "Impossible d'activer le service"
    exit 1
fi

# Démarrer le service
if systemctl start "$SERVICE_NAME"; then
    log_success "Service démarré"
else
    log_error "Impossible de démarrer le service"
    exit 1
fi

# Vérifier le statut
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    log_success "Service actif et fonctionnel"
else
    log_error "Le service ne fonctionne pas correctement"
    log_info "Voir les logs: journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi

# Étape 5: Finalisation
log_info ""
log_info "=== ÉTAPE 5: FINALISATION ==="

# Enregistrer l'installation
register_widget_installation

# Test rapide
log_info "Test de publication MQTT..."
if mosquitto_sub -h localhost -p 1883 -u maxlink -P mqtt -t "rpi/system/cpu/+" -C 1 -W 5 >/dev/null 2>&1; then
    log_success "Messages MQTT reçus correctement"
else
    log_warning "Aucun message reçu, le collecteur peut prendre quelques secondes pour démarrer"
fi

# Résumé
log_info ""
log_info "=========================================="
log_success "Installation terminée avec succès !"
log_info "=========================================="
log_info "Widget: $WIDGET_NAME v$WIDGET_VERSION"
log_info "Service: $SERVICE_NAME"
log_info "Status: $(systemctl is-active $SERVICE_NAME)"
log_info ""
log_info "Commandes utiles:"
log_info "  - Voir les logs: journalctl -u $SERVICE_NAME -f"
log_info "  - Voir les logs du collecteur: tail -f /var/log/maxlink/widgets/servermonitoring_collector.log"
log_info "  - Tester: mosquitto_sub -h localhost -u maxlink -P mqtt -t 'rpi/system/+/+' -v"
log_info "  - Arrêter: systemctl stop $SERVICE_NAME"
log_info "  - Redémarrer: systemctl restart $SERVICE_NAME"
log_info ""
log_info "Le widget devrait maintenant envoyer des données au dashboard !"

exit 0