#!/bin/bash

# ===============================================================================
# MAXLINK - INSTALLATION MQTT ET COLLECTEUR SYSTÈME
# Version intégrée avec gestion du mode AP
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
init_logging "Installation MQTT et collecteur système"

# Variables MQTT
MQTT_USER="maxlink"
MQTT_PASS="mqtt"
MQTT_PORT="1883"
MQTT_WEBSOCKET_PORT="9001"
MQTT_CONFIG_DIR="/etc/mosquitto"
MAXLINK_CONFIG_DIR="/etc/maxlink"

# Variables pour la connexion WiFi
AP_WAS_ACTIVE=false

# Fichier de log pour cette installation
INSTALL_LOG="$LOG_DIR/mqtt_install_$(date +%Y%m%d_%H%M%S).log"

# Fonction pour logger avec affichage et fichier
log_and_show() {
    local message=$1
    echo "$message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$INSTALL_LOG"
}

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

# Créer le fichier de configuration des collecteurs
create_collectors_config() {
    cat > "$MAXLINK_CONFIG_DIR/collectors.conf" << EOF
[broker]
host = localhost
port = $MQTT_PORT
websocket_port = $MQTT_WEBSOCKET_PORT
username = $MQTT_USER
password = $MQTT_PASS

[metrics_groups]
# Fréquences en secondes
fast = 1
normal = 5
slow = 30

[topics]
# Structure des topics - modifiable
prefix = rpi
system_cpu = {prefix}/system/cpu/core{n}
system_temp = {prefix}/system/temperature/{type}
system_freq = {prefix}/system/frequency/{type}
system_memory = {prefix}/system/memory/{type}
system_uptime = {prefix}/system/uptime

[logging]
level = INFO
file = $LOG_DIR/collectors.log
EOF
}

# Créer le collecteur système
create_system_metrics_collector() {
    # Créer le répertoire des collecteurs
    mkdir -p "$BASE_DIR/scripts/collectors/common"
    
    # Créer le module MQTT partagé
    cat > "$BASE_DIR/scripts/collectors/common/mqtt_client.py" << 'EOF'
#!/usr/bin/env python3
import paho.mqtt.client as mqtt
import json
import logging
from datetime import datetime

class MQTTClient:
    def __init__(self, config):
        self.config = config
        self.client = mqtt.Client()
        self.logger = logging.getLogger(__name__)
        self.connected = False
        
        # Configuration du client
        self.client.username_pw_set(
            config['broker']['username'],
            config['broker']['password']
        )
        
        # Callbacks
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        
    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.logger.info("Connecté au broker MQTT")
            self.connected = True
        else:
            self.logger.error(f"Échec de connexion MQTT, code: {rc}")
            self.connected = False
    
    def _on_disconnect(self, client, userdata, rc):
        self.logger.warning("Déconnecté du broker MQTT")
        self.connected = False
    
    def connect(self):
        try:
            self.client.connect(
                self.config['broker']['host'],
                int(self.config['broker']['port']),
                60
            )
            self.client.loop_start()
            return True
        except Exception as e:
            self.logger.error(f"Erreur de connexion: {e}")
            return False
    
    def publish(self, topic, value, unit=None):
        if not self.connected:
            return False
        
        payload = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "value": value
        }
        
        if unit:
            payload["unit"] = unit
        
        try:
            result = self.client.publish(topic, json.dumps(payload))
            return result.rc == 0
        except Exception as e:
            self.logger.error(f"Erreur de publication: {e}")
            return False
    
    def disconnect(self):
        self.client.loop_stop()
        self.client.disconnect()
EOF

    # Créer le collecteur système principal
    cat > "$BASE_DIR/scripts/collectors/system-metrics.py" << 'EOF'
#!/usr/bin/env python3
import os
import sys
import time
import psutil
import logging
import configparser
from pathlib import Path

# Ajouter le chemin pour les imports
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from common.mqtt_client import MQTTClient

class SystemMetricsCollector:
    def __init__(self, config_file="/etc/maxlink/collectors.conf"):
        # Charger la configuration
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        
        # Configuration du logging
        self.setup_logging()
        
        # Client MQTT
        self.mqtt = MQTTClient(self.config)
        
        # Timers pour les groupes
        self.last_fast = 0
        self.last_normal = 0
        self.last_slow = 0
        
        # Intervalles
        self.interval_fast = int(self.config['metrics_groups']['fast'])
        self.interval_normal = int(self.config['metrics_groups']['normal'])
        self.interval_slow = int(self.config['metrics_groups']['slow'])
        
        # Préfixe des topics
        self.topic_prefix = self.config['topics']['prefix']
        
    def setup_logging(self):
        log_level = self.config.get('logging', 'level', fallback='INFO')
        log_file = self.config.get('logging', 'file', fallback='/var/log/maxlink/collectors.log')
        
        # Créer le répertoire de logs
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        
        logging.basicConfig(
            level=getattr(logging, log_level),
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def get_cpu_usage(self):
        """Obtenir l'usage CPU par core"""
        return psutil.cpu_percent(interval=0.1, percpu=True)
    
    def get_temperatures(self):
        """Obtenir les températures CPU et GPU"""
        temps = {"cpu": None, "gpu": None}
        
        try:
            # Méthode pour Raspberry Pi
            temp_file = "/sys/class/thermal/thermal_zone0/temp"
            if os.path.exists(temp_file):
                with open(temp_file, 'r') as f:
                    temp_c = float(f.read().strip()) / 1000.0
                    temps["cpu"] = round(temp_c, 1)
            
            # GPU (même source sur Raspberry Pi)
            temps["gpu"] = temps["cpu"]
            
        except Exception as e:
            self.logger.error(f"Erreur lecture température: {e}")
        
        return temps
    
    def get_frequencies(self):
        """Obtenir les fréquences CPU et GPU"""
        freqs = {"cpu": None, "gpu": None}
        
        try:
            # CPU
            cpu_info = psutil.cpu_freq()
            if cpu_info:
                freqs["cpu"] = round(cpu_info.current / 1000, 2)  # Convertir en GHz
            
            # GPU pour Raspberry Pi
            gpu_freq_file = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if os.path.exists(gpu_freq_file):
                with open(gpu_freq_file, 'r') as f:
                    freq_khz = float(f.read().strip())
                    freqs["gpu"] = round(freq_khz / 1000, 0)  # Convertir en MHz
                    
        except Exception as e:
            self.logger.error(f"Erreur lecture fréquences: {e}")
        
        return freqs
    
    def get_memory_usage(self):
        """Obtenir l'usage mémoire"""
        memory = {}
        
        try:
            # RAM
            ram = psutil.virtual_memory()
            memory["ram"] = round(ram.percent, 1)
            
            # Swap
            swap = psutil.swap_memory()
            memory["swap"] = round(swap.percent, 1)
            
            # Disque
            disk = psutil.disk_usage('/')
            memory["disk"] = round(disk.percent, 1)
            
        except Exception as e:
            self.logger.error(f"Erreur lecture mémoire: {e}")
        
        return memory
    
    def get_uptime(self):
        """Obtenir l'uptime en secondes"""
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.readline().split()[0])
                return int(uptime_seconds)
        except:
            return 0
    
    def collect_fast_metrics(self):
        """Collecter les métriques rapides (1s)"""
        # CPU par core
        cpu_usage = self.get_cpu_usage()
        for i, usage in enumerate(cpu_usage, 1):
            topic = f"{self.topic_prefix}/system/cpu/core{i}"
            self.mqtt.publish(topic, round(usage, 1), "%")
        
        # Mémoire RAM
        memory = self.get_memory_usage()
        if "ram" in memory:
            topic = f"{self.topic_prefix}/system/memory/ram"
            self.mqtt.publish(topic, memory["ram"], "%")
    
    def collect_normal_metrics(self):
        """Collecter les métriques normales (5s)"""
        # Températures
        temps = self.get_temperatures()
        for temp_type, value in temps.items():
            if value is not None:
                topic = f"{self.topic_prefix}/system/temperature/{temp_type}"
                self.mqtt.publish(topic, value, "°C")
        
        # Fréquences
        freqs = self.get_frequencies()
        if freqs["cpu"] is not None:
            topic = f"{self.topic_prefix}/system/frequency/cpu"
            self.mqtt.publish(topic, freqs["cpu"], "GHz")
        
        if freqs["gpu"] is not None:
            topic = f"{self.topic_prefix}/system/frequency/gpu"
            self.mqtt.publish(topic, freqs["gpu"], "MHz")
    
    def collect_slow_metrics(self):
        """Collecter les métriques lentes (30s)"""
        # Mémoire Swap et Disque
        memory = self.get_memory_usage()
        
        if "swap" in memory:
            topic = f"{self.topic_prefix}/system/memory/swap"
            self.mqtt.publish(topic, memory["swap"], "%")
        
        if "disk" in memory:
            topic = f"{self.topic_prefix}/system/memory/disk"
            self.mqtt.publish(topic, memory["disk"], "%")
        
        # Uptime
        uptime = self.get_uptime()
        topic = f"{self.topic_prefix}/system/uptime"
        self.mqtt.publish(topic, uptime, "seconds")
    
    def run(self):
        """Boucle principale du collecteur"""
        self.logger.info("Démarrage du collecteur de métriques système")
        
        # Connexion MQTT
        if not self.mqtt.connect():
            self.logger.error("Impossible de se connecter au broker MQTT")
            return
        
        # Attendre la connexion
        time.sleep(2)
        
        self.logger.info("Collecteur démarré avec succès")
        
        try:
            while True:
                current_time = time.time()
                
                # Groupe rapide
                if current_time - self.last_fast >= self.interval_fast:
                    self.collect_fast_metrics()
                    self.last_fast = current_time
                
                # Groupe normal
                if current_time - self.last_normal >= self.interval_normal:
                    self.collect_normal_metrics()
                    self.last_normal = current_time
                
                # Groupe lent
                if current_time - self.last_slow >= self.interval_slow:
                    self.collect_slow_metrics()
                    self.last_slow = current_time
                
                # Petite pause pour éviter de surcharger le CPU
                time.sleep(0.1)
                
        except KeyboardInterrupt:
            self.logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            self.logger.error(f"Erreur dans la boucle principale: {e}")
        finally:
            self.mqtt.disconnect()
            self.logger.info("Collecteur arrêté")

if __name__ == "__main__":
    collector = SystemMetricsCollector()
    collector.run()
EOF

    # Rendre les scripts exécutables
    chmod +x "$BASE_DIR/scripts/collectors/system-metrics.py"
}

# Créer le service systemd
create_systemd_service() {
    cat > "/etc/systemd/system/maxlink-system-metrics.service" << EOF
[Unit]
Description=MaxLink System Metrics Collector
After=mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 $BASE_DIR/scripts/collectors/system-metrics.py
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

# ===============================================================================
# ÉTAPE 1 : PRÉPARATION ET VÉRIFICATION WIFI
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 1 : PRÉPARATION DU SYSTÈME"
echo "========================================================================"
echo ""

send_progress 5 "Préparation du système..."

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "  ↦ Privilèges root requis ✗"
    exit 1
fi

# Stabilisation initiale
echo "◦ Stabilisation du système après démarrage..."
echo "  ↦ Initialisation des services réseau..."
wait_silently 5

# Vérifier et désactiver le mode AP si actif
if nmcli con show --active | grep -q "$AP_SSID"; then
    echo ""
    echo "◦ Mode point d'accès détecté..."
    AP_WAS_ACTIVE=true
    nmcli con down "$AP_SSID" >/dev/null 2>&1
    wait_silently 2
    echo "  ↦ Mode AP désactivé temporairement ✓"
fi

# Vérifier l'interface WiFi
echo ""
echo "◦ Vérification de l'interface WiFi..."
if ip link show wlan0 >/dev/null 2>&1; then
    echo "  ↦ Interface WiFi détectée ✓"
    nmcli radio wifi on >/dev/null 2>&1
    wait_silently 2
    echo "  ↦ WiFi activé ✓"
else
    echo "  ↦ Interface WiFi non disponible ✗"
    exit 1
fi

send_progress 10 "WiFi préparé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 2 : CONNEXION RÉSEAU
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 2 : CONNEXION RÉSEAU"
echo "========================================================================"
echo ""

send_progress 15 "Recherche du réseau..."

# Scan et recherche du réseau
echo "◦ Recherche du réseau WiFi \"$WIFI_SSID\"..."
echo "  ↦ Scan des réseaux disponibles..."
nmcli device wifi rescan >/dev/null 2>&1
wait_silently 5

# Vérifier la présence du réseau
NETWORK_INFO=$(nmcli device wifi list | grep "$WIFI_SSID" | head -1)
if [ -n "$NETWORK_INFO" ]; then
    SIGNAL=$(echo "$NETWORK_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    echo "  ↦ Réseau trouvé (Signal: ${SIGNAL:-N/A} dBm) ✓"
else
    echo "  ↦ Réseau \"$WIFI_SSID\" non trouvé ✗"
    exit 1
fi

send_progress 20 "Connexion en cours..."

# Connexion au réseau
echo ""
echo "◦ Connexion au réseau \"$WIFI_SSID\"..."
nmcli connection delete "$WIFI_SSID" 2>/dev/null || true

if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
    echo "  ↦ Connexion initiée ✓"
    echo "  ↦ Obtention de l'adresse IP..."
    wait_silently 5
    
    IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
        echo "  ↦ Connexion établie (IP: $IP) ✓"
    else
        echo "  ↦ Connexion établie mais pas d'IP ⚠"
    fi
else
    echo "  ↦ Échec de la connexion ✗"
    exit 1
fi

# Test de connectivité
echo ""
echo "◦ Test de connectivité..."
echo "  ↦ Stabilisation de la connexion..."
wait_silently 2

log_info "Test de connectivité Internet"
if ping -c 3 -W 2 8.8.8.8 >> "$INSTALL_LOG" 2>&1; then
    echo "  ↦ Connectivité Internet confirmée ✓"
    log_info "Connectivité Internet OK"
else
    echo "  ↦ Pas de connectivité Internet ✗"
    log_error "Pas de connectivité Internet"
    
    # Essayer de diagnostiquer
    log_and_show "  ↦ Diagnostic réseau..."
    ip addr show wlan0 >> "$INSTALL_LOG" 2>&1
    ip route >> "$INSTALL_LOG" 2>&1
    cat /etc/resolv.conf >> "$INSTALL_LOG" 2>&1
    
    exit 1
fi

send_progress 30 "Connexion établie"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 3 : INSTALLATION DE MOSQUITTO
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 3 : INSTALLATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 35 "Installation de Mosquitto..."

echo "◦ Vérification de Mosquitto..."
if dpkg -l mosquitto >/dev/null 2>&1; then
    echo "  ↦ Mosquitto déjà installé ✓"
    log_info "Mosquitto déjà présent"
    # Arrêter le service pour reconfiguration
    systemctl stop mosquitto >> "$INSTALL_LOG" 2>&1
else
    echo "  ↦ Installation de Mosquitto..."
    log_info "Installation de Mosquitto"
    
    # Mise à jour des paquets
    log_and_show "  ↦ Mise à jour de la liste des paquets..."
    if apt-get update >> "$INSTALL_LOG" 2>&1; then
        log_and_show "  ↦ Liste mise à jour ✓"
    else
        log_and_show "  ↦ Erreur lors de la mise à jour ✗"
        log_error "Échec apt-get update"
    fi
    
    # Installation
    if apt-get install -y mosquitto mosquitto-clients >> "$INSTALL_LOG" 2>&1; then
        echo "  ↦ Mosquitto installé ✓"
        log_info "Mosquitto installé avec succès"
    else
        echo "  ↦ Erreur lors de l'installation ✗"
        log_error "Échec installation Mosquitto"
        exit 1
    fi
fi

# Installer les dépendances Python
echo ""
echo "◦ Installation des dépendances Python..."
log_and_show "  ↦ Installation de paho-mqtt et psutil..."

# Essayer pip3 d'abord
if command -v pip3 >/dev/null 2>&1; then
    if pip3 install paho-mqtt psutil >> "$INSTALL_LOG" 2>&1; then
        log_and_show "  ↦ Dépendances installées via pip3 ✓"
    else
        log_and_show "  ↦ Échec pip3, tentative avec apt-get..."
        if apt-get install -y python3-paho-mqtt python3-psutil >> "$INSTALL_LOG" 2>&1; then
            log_and_show "  ↦ Dépendances installées via apt-get ✓"
        else
            log_and_show "  ↦ Erreur installation dépendances Python ✗"
            log_error "Impossible d'installer paho-mqtt et psutil"
        fi
    fi
else
    # Pas de pip3, utiliser apt-get directement
    if apt-get install -y python3-paho-mqtt python3-psutil >> "$INSTALL_LOG" 2>&1; then
        log_and_show "  ↦ Dépendances installées via apt-get ✓"
    else
        log_and_show "  ↦ Erreur installation dépendances Python ✗"
        log_error "Impossible d'installer paho-mqtt et psutil"
    fi
fi

send_progress 45 "Mosquitto installé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 4 : CONFIGURATION DE MOSQUITTO
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 4 : CONFIGURATION DE MOSQUITTO"
echo "========================================================================"
echo ""

send_progress 50 "Configuration de Mosquitto..."

echo "◦ Création de la configuration Mosquitto..."

# Sauvegarder la config originale
if [ ! -f "$MQTT_CONFIG_DIR/mosquitto.conf.original" ]; then
    cp "$MQTT_CONFIG_DIR/mosquitto.conf" "$MQTT_CONFIG_DIR/mosquitto.conf.original"
fi

# Créer le fichier de mots de passe
echo "  ↦ Configuration de l'authentification..."
log_info "Création du fichier de mots de passe"

# S'assurer que le répertoire existe
mkdir -p "$MQTT_CONFIG_DIR"

# Supprimer l'ancien fichier s'il existe
rm -f "$MQTT_CONFIG_DIR/passwords"

# Créer le mot de passe (avec le chemin complet)
if /usr/bin/mosquitto_passwd -b -c "$MQTT_CONFIG_DIR/passwords" "$MQTT_USER" "$MQTT_PASS" >> "$INSTALL_LOG" 2>&1; then
    # Vérifier que le fichier existe
    if [ -f "$MQTT_CONFIG_DIR/passwords" ]; then
        chmod 600 "$MQTT_CONFIG_DIR/passwords"
        chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
        log_and_show "  ↦ Authentification configurée ✓"
        log_info "Fichier passwords créé avec succès"
        ls -la "$MQTT_CONFIG_DIR/passwords" >> "$INSTALL_LOG" 2>&1
    else
        log_and_show "  ↦ Fichier passwords non créé ✗"
        log_error "Le fichier passwords n'a pas été créé"
    fi
else
    log_and_show "  ↦ Erreur création mot de passe ✗"
    log_error "Échec mosquitto_passwd"
    
    # Alternative : créer le fichier manuellement
    log_and_show "  ↦ Tentative de création manuelle..."
    # Générer le hash du mot de passe
    HASHED_PASS=$(echo -n "$MQTT_PASS" | openssl dgst -sha256 -hmac "$MQTT_USER" -binary | base64)
    echo "$MQTT_USER:$HASHED_PASS" > "$MQTT_CONFIG_DIR/passwords"
    chmod 600 "$MQTT_CONFIG_DIR/passwords"
    chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
fi

# Créer la configuration principale
cat > "$MQTT_CONFIG_DIR/mosquitto.conf" << EOF
# Configuration Mosquitto pour MaxLink
pid_file /var/run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log
log_dest stdout

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

# Vérifier que le fichier passwords existe vraiment avant de continuer
if [ ! -f "$MQTT_CONFIG_DIR/passwords" ]; then
    log_error "ERREUR CRITIQUE : Le fichier passwords n'existe pas !"
    echo "  ↦ ERREUR : Fichier d'authentification manquant ✗"
    
    # Essayer de le créer une dernière fois
    echo "$MQTT_USER:$MQTT_PASS" > "$MQTT_CONFIG_DIR/passwords.tmp"
    mosquitto_passwd -U "$MQTT_CONFIG_DIR/passwords.tmp" >> "$INSTALL_LOG" 2>&1
    mv "$MQTT_CONFIG_DIR/passwords.tmp" "$MQTT_CONFIG_DIR/passwords"
    chmod 600 "$MQTT_CONFIG_DIR/passwords"
    chown mosquitto:mosquitto "$MQTT_CONFIG_DIR/passwords"
fi

# S'assurer que mosquitto peut lire le fichier
chown -R mosquitto:mosquitto "$MQTT_CONFIG_DIR"
chmod 755 "$MQTT_CONFIG_DIR"

# Créer la configuration ACL simple
echo ""
echo "◦ Configuration des permissions (ACL)..."
cat > "$MQTT_CONFIG_DIR/acl.conf" << EOF
# ACL pour MaxLink
# Format: user topic permission

# maxlink peut tout faire
user $MQTT_USER
topic readwrite #

# Règles spécifiques futures
# user esp32
# topic write rpi/device/+/result
# topic read rpi/device/+/command
EOF

# Ajouter l'ACL à la config
echo "acl_file $MQTT_CONFIG_DIR/acl.conf" >> "$MQTT_CONFIG_DIR/mosquitto.conf"
echo "  ↦ ACL configurée ✓"

send_progress 60 "Mosquitto configuré"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 5 : INSTALLATION DU COLLECTEUR
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 5 : INSTALLATION DU COLLECTEUR SYSTÈME"
echo "========================================================================"
echo ""

send_progress 70 "Installation du collecteur..."

echo "◦ Création de la structure des répertoires..."
mkdir -p "$MAXLINK_CONFIG_DIR"
mkdir -p "$LOG_DIR"  # Utilise le dossier logs sur la clé USB
echo "  ↦ Répertoires créés ✓"

echo ""
echo "◦ Création du fichier de configuration..."
create_collectors_config
echo "  ↦ Configuration créée ✓"

echo ""
echo "◦ Installation du collecteur de métriques..."
create_system_metrics_collector
echo "  ↦ Scripts du collecteur créés ✓"

echo ""
echo "◦ Création du service systemd..."
create_systemd_service
echo "  ↦ Service systemd créé ✓"

send_progress 80 "Collecteur installé"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 6 : DÉMARRAGE DES SERVICES
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 6 : DÉMARRAGE DES SERVICES"
echo "========================================================================"
echo ""

send_progress 85 "Démarrage des services..."

echo "◦ Activation et démarrage de Mosquitto..."
systemctl enable mosquitto >> "$INSTALL_LOG" 2>&1
if systemctl start mosquitto >> "$INSTALL_LOG" 2>&1; then
    log_info "Mosquitto démarré"
else
    log_error "Échec démarrage Mosquitto"
fi
wait_silently 3

# Vérifier que Mosquitto est démarré
if systemctl is-active --quiet mosquitto; then
    echo "  ↦ Mosquitto démarré ✓"
else
    echo "  ↦ Erreur au démarrage de Mosquitto ✗"
    log_error "Mosquitto n'est pas actif"
    echo ""
    echo "Dernières lignes du journal Mosquitto :"
    journalctl -u mosquitto -n 20 --no-pager | tee -a "$INSTALL_LOG"
    exit 1
fi

echo ""
echo "◦ Test de connexion MQTT..."
if mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "test" -m "test" >> "$INSTALL_LOG" 2>&1; then
    echo "  ↦ Connexion MQTT fonctionnelle ✓"
    log_info "Test connexion MQTT réussi"
else
    echo "  ↦ Erreur de connexion MQTT ✗"
    log_error "Test connexion MQTT échoué"
    
    # Diagnostic
    echo ""
    echo "Diagnostic MQTT :"
    echo "Vérification des ports..." | tee -a "$INSTALL_LOG"
    netstat -tlnp | grep mosquitto >> "$INSTALL_LOG" 2>&1
    echo "Status du service..." | tee -a "$INSTALL_LOG"
    systemctl status mosquitto >> "$INSTALL_LOG" 2>&1
    
    exit 1
fi

echo ""
echo "◦ Activation et démarrage du collecteur..."
systemctl daemon-reload
systemctl enable maxlink-system-metrics >> "$INSTALL_LOG" 2>&1
if systemctl start maxlink-system-metrics >> "$INSTALL_LOG" 2>&1; then
    log_info "Collecteur démarré"
else
    log_error "Échec démarrage collecteur"
fi
wait_silently 3

# Vérifier que le collecteur est démarré
if systemctl is-active --quiet maxlink-system-metrics; then
    echo "  ↦ Collecteur démarré ✓"
else
    echo "  ↦ Erreur au démarrage du collecteur ✗"
    log_error "Collecteur n'est pas actif"
    echo ""
    echo "Dernières lignes du journal collecteur :"
    journalctl -u maxlink-system-metrics -n 20 --no-pager | tee -a "$INSTALL_LOG"
fi

send_progress 95 "Services démarrés"
echo ""
sleep 2

# ===============================================================================
# ÉTAPE 7 : FINALISATION
# ===============================================================================

echo "========================================================================"
echo "ÉTAPE 7 : FINALISATION"
echo "========================================================================"
echo ""

send_progress 98 "Finalisation..."

# Test rapide des métriques
echo "◦ Vérification des métriques..."
echo "  ↦ Attente de données..."
wait_silently 5

# Vérifier qu'on reçoit des données
log_info "Test réception des métriques"
if mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "rpi/system/cpu/+" -C 1 -W 5 >> "$INSTALL_LOG" 2>&1; then
    echo "  ↦ Métriques CPU reçues ✓"
    log_info "Métriques reçues avec succès"
    
    # Capturer quelques métriques pour le log
    echo "" >> "$INSTALL_LOG"
    echo "Échantillon de métriques reçues :" >> "$INSTALL_LOG"
    mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "rpi/system/+/+" -C 5 -W 2 >> "$INSTALL_LOG" 2>&1
else
    echo "  ↦ Pas de métriques reçues (vérifier les logs) ⚠"
    log_warn "Pas de métriques reçues dans le délai"
    
    # Diagnostic supplémentaire
    echo "" >> "$INSTALL_LOG"
    echo "Diagnostic collecteur :" >> "$INSTALL_LOG"
    ps aux | grep system-metrics >> "$INSTALL_LOG" 2>&1
    echo "" >> "$INSTALL_LOG"
    echo "Topics MQTT disponibles :" >> "$INSTALL_LOG"
    mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "#" -C 10 -W 2 >> "$INSTALL_LOG" 2>&1 || echo "Aucun topic trouvé" >> "$INSTALL_LOG"
fi

# Déconnexion WiFi
echo ""
echo "◦ Déconnexion du réseau WiFi..."
nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
wait_silently 2
nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
echo "  ↦ WiFi déconnecté ✓"

# Réactiver le mode AP s'il était actif avant
if [ "$AP_WAS_ACTIVE" = true ]; then
    echo ""
    echo "◦ Réactivation du mode point d'accès..."
    nmcli con up "$AP_SSID" >/dev/null 2>&1 || true
    wait_silently 3
    echo "  ↦ Mode AP réactivé ✓"
fi

send_progress 100 "Installation terminée !"

echo ""
echo "◦ Installation terminée avec succès !"
echo "  ↦ Broker MQTT : localhost:$MQTT_PORT"
echo "  ↦ WebSocket : localhost:$MQTT_WEBSOCKET_PORT"
echo "  ↦ Utilisateur : $MQTT_USER"
echo "  ↦ Mot de passe : $MQTT_PASS"
echo ""
echo "◦ Services installés :"
echo "  ↦ mosquitto (broker MQTT)"
echo "  ↦ maxlink-system-metrics (collecteur)"
echo ""
echo "◦ Configuration :"
echo "  ↦ /etc/maxlink/collectors.conf"
echo ""
echo "◦ Logs disponibles :"
echo "  ↦ journalctl -u mosquitto"
echo "  ↦ journalctl -u maxlink-system-metrics"
echo "  ↦ /var/log/maxlink/collectors.log"
echo ""
echo "◦ Topics MQTT disponibles :"
echo "  ↦ rpi/system/cpu/core[1-4]"
echo "  ↦ rpi/system/temperature/[cpu|gpu]"
echo "  ↦ rpi/system/frequency/[cpu|gpu]"
echo "  ↦ rpi/system/memory/[ram|swap|disk]"
echo "  ↦ rpi/system/uptime"
echo ""

echo "  ↦ Redémarrage dans 10 secondes..."
echo ""
echo "◦ IMPORTANT : Fichier de log complet disponible :"
echo "  ↦ $INSTALL_LOG"
echo ""

log_info "Installation MQTT et collecteur système terminée - Redémarrage du système"

# Copier aussi les logs système pertinents
echo "" >> "$INSTALL_LOG"
echo "=== LOGS MOSQUITTO ===" >> "$INSTALL_LOG"
journalctl -u mosquitto -n 50 --no-pager >> "$INSTALL_LOG" 2>&1
echo "" >> "$INSTALL_LOG"
echo "=== LOGS COLLECTEUR ===" >> "$INSTALL_LOG"
journalctl -u maxlink-system-metrics -n 50 --no-pager >> "$INSTALL_LOG" 2>&1

# Pause de 10 secondes avant reboot
sleep 10

# Redémarrer
reboot