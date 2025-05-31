#!/usr/bin/env python3
"""
Collecteur de métriques système pour le widget Server Monitoring
Version nettoyée sans delays système
"""

import os
import sys
import time
import json
import logging
from datetime import datetime
from pathlib import Path

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('servermonitoring')

# Import des modules requis
try:
    import psutil
except ImportError:
    logger.error("Module psutil non installé")
    sys.exit(1)

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
        
        # Configuration MQTT
        self.mqtt_config = self.config['mqtt']['broker']
        
        # Configuration retry MQTT uniquement
        self.retry_enabled = os.environ.get('MQTT_RETRY_ENABLED', 'true').lower() == 'true'
        self.retry_delay = int(os.environ.get('MQTT_RETRY_DELAY', '10'))
        self.max_retries = int(os.environ.get('MQTT_MAX_RETRIES', '0'))  # 0 = infini
        
        # Compteur de tentatives
        self.connection_attempts = 0
        
        # Intervalles de mise à jour
        self.intervals = self.config['collector']['update_intervals']
        self.last_update = {
            'fast': 0,
            'normal': 0,
            'slow': 0
        }
        
        # Statistiques
        self.stats = {
            'messages_sent': 0,
            'errors': 0,
            'start_time': time.time(),
            'connection_failures': 0
        }
        
        logger.info(f"Collecteur initialisé - Version {self.config['widget']['version']}")
        logger.info(f"Retry: {self.retry_enabled}, Delay: {self.retry_delay}s, Max: {self.max_retries}")
    
    def load_config(self, config_file):
        """Charge la configuration depuis le fichier JSON"""
        try:
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Erreur chargement config: {e}")
            sys.exit(1)
    
    def connect_mqtt(self):
        """Connexion au broker MQTT avec retry robuste"""
        while True:
            try:
                self.connection_attempts += 1
                
                # Vérifier si on a atteint la limite
                if self.max_retries > 0 and self.connection_attempts > self.max_retries:
                    logger.error(f"Limite de tentatives atteinte ({self.max_retries})")
                    return False
                
                logger.info(f"Tentative de connexion MQTT #{self.connection_attempts} à {self.mqtt_config['host']}:{self.mqtt_config['port']}")
                
                # Créer le client MQTT
                self.mqtt_client = mqtt.Client()
                
                # Callbacks
                self.mqtt_client.on_connect = self.on_connect
                self.mqtt_client.on_disconnect = self.on_disconnect
                
                # Authentification
                self.mqtt_client.username_pw_set(
                    self.mqtt_config['username'],
                    self.mqtt_config['password']
                )
                
                # Options de reconnexion automatique
                self.mqtt_client.reconnect_delay_set(min_delay=1, max_delay=120)
                
                # Connexion
                self.mqtt_client.connect(
                    self.mqtt_config['host'], 
                    self.mqtt_config['port'], 
                    60
                )
                
                # Démarrer la boucle
                self.mqtt_client.loop_start()
                
                # Attendre la connexion
                timeout = 30
                while not self.connected and timeout > 0:
                    time.sleep(0.5)
                    timeout -= 0.5
                
                if self.connected:
                    logger.info("Connexion MQTT établie avec succès")
                    self.stats['connection_failures'] = 0
                    return True
                else:
                    raise Exception("Timeout de connexion")
                
            except Exception as e:
                self.stats['connection_failures'] += 1
                logger.error(f"Erreur connexion MQTT: {e}")
                
                if self.mqtt_client:
                    try:
                        self.mqtt_client.loop_stop()
                    except:
                        pass
                
                if not self.retry_enabled:
                    return False
                
                # Attendre avant de réessayer
                logger.info(f"Nouvelle tentative dans {self.retry_delay} secondes...")
                time.sleep(self.retry_delay)
    
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
        logger.warning(f"Déconnecté du broker MQTT (code: {rc})")
        self.connected = False
        self.stats['connection_failures'] += 1
    
    def publish_metric(self, topic, value, unit=None):
        """Publie une métrique sur MQTT avec gestion d'erreur"""
        if not self.connected:
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "value": value
            }
            
            if unit:
                payload["unit"] = unit
            
            result = self.mqtt_client.publish(topic, json.dumps(payload), qos=1)
            
            if result.rc == 0:
                self.stats['messages_sent'] += 1
                return True
            else:
                self.stats['errors'] += 1
                return False
                
        except Exception as e:
            logger.error(f"Erreur publication: {e}")
            self.stats['errors'] += 1
            return False
    
    def collect_cpu_metrics(self):
        """Collecte les métriques CPU"""
        try:
            # Usage par core
            cpu_percents = psutil.cpu_percent(interval=0.1, percpu=True)
            for i, percent in enumerate(cpu_percents, 1):
                self.publish_metric(
                    f"rpi/system/cpu/core{i}", 
                    round(percent, 1), 
                    "%"
                )
        except Exception as e:
            logger.error(f"Erreur collecte CPU: {e}")
            self.stats['errors'] += 1
    
    def collect_temperature_metrics(self):
        """Collecte les températures"""
        try:
            # Température CPU (Raspberry Pi)
            temp_file = "/sys/class/thermal/thermal_zone0/temp"
            if os.path.exists(temp_file):
                with open(temp_file, 'r') as f:
                    temp_c = float(f.read().strip()) / 1000.0
                    
                self.publish_metric(
                    "rpi/system/temperature/cpu", 
                    round(temp_c, 1), 
                    "°C"
                )
                
                # GPU = CPU sur Raspberry Pi
                self.publish_metric(
                    "rpi/system/temperature/gpu", 
                    round(temp_c, 1), 
                    "°C"
                )
        except Exception as e:
            logger.error(f"Erreur collecte température: {e}")
            self.stats['errors'] += 1
    
    def collect_frequency_metrics(self):
        """Collecte les fréquences"""
        try:
            # Fréquence CPU
            cpu_freq = psutil.cpu_freq()
            if cpu_freq:
                freq_ghz = round(cpu_freq.current / 1000, 2)
                self.publish_metric(
                    "rpi/system/frequency/cpu", 
                    freq_ghz, 
                    "GHz"
                )
            
            # Fréquence GPU (spécifique Raspberry Pi)
            gpu_freq_file = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if os.path.exists(gpu_freq_file):
                with open(gpu_freq_file, 'r') as f:
                    freq_khz = float(f.read().strip())
                    freq_mhz = round(freq_khz / 1000, 0)
                    self.publish_metric(
                        "rpi/system/frequency/gpu", 
                        freq_mhz, 
                        "MHz"
                    )
        except Exception as e:
            logger.error(f"Erreur collecte fréquences: {e}")
            self.stats['errors'] += 1
    
    def collect_memory_metrics(self):
        """Collecte les métriques mémoire"""
        try:
            # RAM
            ram = psutil.virtual_memory()
            self.publish_metric(
                "rpi/system/memory/ram", 
                round(ram.percent, 1), 
                "%"
            )
            
            # SWAP
            swap = psutil.swap_memory()
            self.publish_metric(
                "rpi/system/memory/swap", 
                round(swap.percent, 1), 
                "%"
            )
            
            # Disque
            disk = psutil.disk_usage('/')
            self.publish_metric(
                "rpi/system/memory/disk", 
                round(disk.percent, 1), 
                "%"
            )
        except Exception as e:
            logger.error(f"Erreur collecte mémoire: {e}")
            self.stats['errors'] += 1
    
    def collect_uptime_metrics(self):
        """Collecte l'uptime"""
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = int(float(f.readline().split()[0]))
                self.publish_metric(
                    "rpi/system/uptime", 
                    uptime_seconds, 
                    "seconds"
                )
        except Exception as e:
            logger.error(f"Erreur collecte uptime: {e}")
            self.stats['errors'] += 1
    
    def log_statistics(self):
        """Affiche les statistiques"""
        runtime = time.time() - self.stats['start_time']
        hours = int(runtime // 3600)
        minutes = int((runtime % 3600) // 60)
        
        logger.info(
            f"Stats - Runtime: {hours}h {minutes}m | "
            f"Messages: {self.stats['messages_sent']} | "
            f"Erreurs: {self.stats['errors']} | "
            f"Échecs connexion: {self.stats['connection_failures']}"
        )
    
    def run(self):
        """Boucle principale du collecteur"""
        logger.info("Démarrage du collecteur")
        
        # Se connecter au broker MQTT avec retry
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT après toutes les tentatives")
            return
        
        logger.info("Collecteur opérationnel")
        
        # Compteur pour les statistiques
        stats_counter = 0
        error_count = 0
        
        try:
            while True:
                try:
                    current_time = time.time()
                    
                    # Vérifier la connexion MQTT
                    if not self.connected:
                        logger.warning("Connexion MQTT perdue, reconnexion...")
                        if not self.connect_mqtt():
                            logger.error("Reconnexion échouée")
                            break
                    
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
                    
                    # Afficher les statistiques toutes les 5 minutes
                    stats_counter += 1
                    if stats_counter >= 3000:  # 300 secondes à 0.1s par boucle
                        self.log_statistics()
                        stats_counter = 0
                    
                    # Réinitialiser le compteur d'erreurs si tout va bien
                    error_count = 0
                    
                    # Pause pour éviter la surcharge CPU
                    time.sleep(0.1)
                    
                except Exception as e:
                    error_count += 1
                    logger.error(f"Erreur dans la boucle de collecte: {e}")
                    self.stats['errors'] += 1
                    
                    # Si trop d'erreurs consécutives, arrêter
                    if error_count > 10:
                        logger.error("Trop d'erreurs consécutives, arrêt du collecteur")
                        break
                    
                    time.sleep(5)  # Pause plus longue en cas d'erreur
                
        except KeyboardInterrupt:
            logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            logger.error(f"Erreur dans la boucle principale: {e}")
        finally:
            if self.mqtt_client:
                self.mqtt_client.loop_stop()
                self.mqtt_client.disconnect()
            
            self.log_statistics()
            logger.info("Collecteur arrêté")

if __name__ == "__main__":
    # Récupérer le fichier de configuration depuis l'environnement ou le paramètre
    config_file = os.environ.get('CONFIG_FILE')
    
    if not config_file and len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    if not config_file:
        # Chemin par défaut
        widget_dir = os.path.dirname(os.path.abspath(__file__))
        config_file = os.path.join(widget_dir, "servermonitoring_widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    # Lancer le collecteur
    collector = SystemMetricsCollector(config_file)
    collector.run()