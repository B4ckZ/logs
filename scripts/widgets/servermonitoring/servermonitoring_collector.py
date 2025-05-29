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

# Configuration du logging - Nouveau système simplifié
base_dir = Path(__file__).resolve().parents[4]  # Remonter à la racine MaxLink
log_dir = base_dir / "logs"
log_dir.mkdir(exist_ok=True)
log_file = log_dir / "servermonitoring.log"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file, mode='a'),  # Append au fichier existant
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
        """Charge la configuration depuis servermonitoring_widget.json"""
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
    # Chemin vers servermonitoring_widget.json
    widget_dir = os.path.dirname(os.path.abspath(__file__))
    config_file = os.path.join(widget_dir, "servermonitoring_widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    # Lancer le collecteur
    collector = SystemMetricsCollector(config_file)
    collector.run()