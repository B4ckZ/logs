#!/bin/bash

# ===============================================================================
# MODULE SYSTEM METRICS - INSTALLATION
# Collecteur pour CPU, RAM, Températures, etc.
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="$(dirname "$MODULE_DIR")"
BASE_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Source des variables
source "$BASE_DIR/scripts/common/variables.sh"

# Configuration du module
MODULE_NAME="system_metrics"
MODULE_VERSION="1.0"
MODULE_DESCRIPTION="Collecteur de métriques système (CPU, RAM, Temp)"

# ===============================================================================
# FONCTIONS
# ===============================================================================

log_module() {
    echo "[SYSTEM_METRICS] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SYSTEM_METRICS] $1" >> "$LOG_DIR/modules_install.log"
}

# ===============================================================================
# INSTALLATION
# ===============================================================================

echo ""
echo "  → Installation de System Metrics..."

# 1. Installer les dépendances Python
log_module "Installation des dépendances Python"
if apt-get install -y python3-psutil python3-paho-mqtt >/dev/null 2>&1; then
    echo "    ✓ Dépendances installées"
else
    echo "    ✗ Erreur installation dépendances"
    exit 1
fi

# 2. Créer les répertoires
mkdir -p "$BASE_DIR/scripts/collectors/common"
mkdir -p "/etc/maxlink"

# 3. Créer le fichier de configuration
log_module "Création de la configuration"
cat > "/etc/maxlink/collectors.conf" << EOF
[broker]
host = localhost
port = 1883
websocket_port = 9001
username = maxlink
password = mqtt

[metrics_groups]
# Fréquences en secondes
fast = 1
normal = 5
slow = 30

[topics]
# Structure des topics
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

# 4. Copier le client MQTT commun
log_module "Installation du client MQTT"
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
        
        self.client.username_pw_set(
            config['broker']['username'],
            config['broker']['password']
        )
        
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

# 5. Copier le collecteur système
log_module "Installation du collecteur système"
cat > "$BASE_DIR/scripts/collectors/system-metrics.py" << 'EOF'
#!/usr/bin/env python3
import os
import sys
import time
import psutil
import logging
import configparser
from pathlib import Path

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from common.mqtt_client import MQTTClient

class SystemMetricsCollector:
    def __init__(self, config_file="/etc/maxlink/collectors.conf"):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        self.setup_logging()
        self.mqtt = MQTTClient(self.config)
        
        self.last_fast = 0
        self.last_normal = 0
        self.last_slow = 0
        
        self.interval_fast = int(self.config['metrics_groups']['fast'])
        self.interval_normal = int(self.config['metrics_groups']['normal'])
        self.interval_slow = int(self.config['metrics_groups']['slow'])
        
        self.topic_prefix = self.config['topics']['prefix']
        
    def setup_logging(self):
        log_level = self.config.get('logging', 'level', fallback='INFO')
        log_file = self.config.get('logging', 'file', fallback='/var/log/maxlink/collectors.log')
        
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
        return psutil.cpu_percent(interval=0.1, percpu=True)
    
    def get_temperatures(self):
        temps = {"cpu": None, "gpu": None}
        try:
            temp_file = "/sys/class/thermal/thermal_zone0/temp"
            if os.path.exists(temp_file):
                with open(temp_file, 'r') as f:
                    temp_c = float(f.read().strip()) / 1000.0
                    temps["cpu"] = round(temp_c, 1)
            temps["gpu"] = temps["cpu"]
        except Exception as e:
            self.logger.error(f"Erreur lecture température: {e}")
        return temps
    
    def get_frequencies(self):
        freqs = {"cpu": None, "gpu": None}
        try:
            cpu_info = psutil.cpu_freq()
            if cpu_info:
                freqs["cpu"] = round(cpu_info.current / 1000, 2)
            
            gpu_freq_file = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if os.path.exists(gpu_freq_file):
                with open(gpu_freq_file, 'r') as f:
                    freq_khz = float(f.read().strip())
                    freqs["gpu"] = round(freq_khz / 1000, 0)
        except Exception as e:
            self.logger.error(f"Erreur lecture fréquences: {e}")
        return freqs
    
    def get_memory_usage(self):
        memory = {}
        try:
            ram = psutil.virtual_memory()
            memory["ram"] = round(ram.percent, 1)
            
            swap = psutil.swap_memory()
            memory["swap"] = round(swap.percent, 1)
            
            disk = psutil.disk_usage('/')
            memory["disk"] = round(disk.percent, 1)
        except Exception as e:
            self.logger.error(f"Erreur lecture mémoire: {e}")
        return memory
    
    def get_uptime(self):
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.readline().split()[0])
                return int(uptime_seconds)
        except:
            return 0
    
    def collect_fast_metrics(self):
        cpu_usage = self.get_cpu_usage()
        for i, usage in enumerate(cpu_usage, 1):
            topic = f"{self.topic_prefix}/system/cpu/core{i}"
            self.mqtt.publish(topic, round(usage, 1), "%")
        
        memory = self.get_memory_usage()
        if "ram" in memory:
            topic = f"{self.topic_prefix}/system/memory/ram"
            self.mqtt.publish(topic, memory["ram"], "%")
    
    def collect_normal_metrics(self):
        temps = self.get_temperatures()
        for temp_type, value in temps.items():
            if value is not None:
                topic = f"{self.topic_prefix}/system/temperature/{temp_type}"
                self.mqtt.publish(topic, value, "°C")
        
        freqs = self.get_frequencies()
        if freqs["cpu"] is not None:
            topic = f"{self.topic_prefix}/system/frequency/cpu"
            self.mqtt.publish(topic, freqs["cpu"], "GHz")
        
        if freqs["gpu"] is not None:
            topic = f"{self.topic_prefix}/system/frequency/gpu"
            self.mqtt.publish(topic, freqs["gpu"], "MHz")
    
    def collect_slow_metrics(self):
        memory = self.get_memory_usage()
        
        if "swap" in memory:
            topic = f"{self.topic_prefix}/system/memory/swap"
            self.mqtt.publish(topic, memory["swap"], "%")
        
        if "disk" in memory:
            topic = f"{self.topic_prefix}/system/memory/disk"
            self.mqtt.publish(topic, memory["disk"], "%")
        
        uptime = self.get_uptime()
        topic = f"{self.topic_prefix}/system/uptime"
        self.mqtt.publish(topic, uptime, "seconds")
    
    def run(self):
        self.logger.info("Démarrage du collecteur de métriques système")
        
        if not self.mqtt.connect():
            self.logger.error("Impossible de se connecter au broker MQTT")
            return
        
        time.sleep(2)
        self.logger.info("Collecteur démarré avec succès")
        
        try:
            while True:
                current_time = time.time()
                
                if current_time - self.last_fast >= self.interval_fast:
                    self.collect_fast_metrics()
                    self.last_fast = current_time
                
                if current_time - self.last_normal >= self.interval_normal:
                    self.collect_normal_metrics()
                    self.last_normal = current_time
                
                if current_time - self.last_slow >= self.interval_slow:
                    self.collect_slow_metrics()
                    self.last_slow = current_time
                
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

chmod +x "$BASE_DIR/scripts/collectors/system-metrics.py"

# 6. Créer le service systemd
log_module "Création du service systemd"
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

# 7. Activer et démarrer le service
log_module "Activation du service"
systemctl daemon-reload
systemctl enable maxlink-system-metrics >/dev/null 2>&1
if systemctl start maxlink-system-metrics; then
    echo "    ✓ Service démarré"
    
    # Enregistrer le module
    python3 -c "
import json
from datetime import datetime

modules_file = '/etc/maxlink/installed_modules.json'
try:
    with open(modules_file, 'r') as f:
        modules = json.load(f)
except:
    modules = {}

modules['$MODULE_NAME'] = {
    'version': '$MODULE_VERSION',
    'installed_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'status': 'active',
    'description': '$MODULE_DESCRIPTION'
}

with open(modules_file, 'w') as f:
    json.dump(modules, f, indent=2)
"
    log_module "Module enregistré avec succès"
    echo "    ✓ Module System Metrics installé"
    exit 0
else
    echo "    ✗ Erreur démarrage du service"
    exit 1
fi