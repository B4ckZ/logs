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
