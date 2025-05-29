#!/usr/bin/env python3
"""
Collecteur de métriques système pour le widget Server Monitoring
Envoie les données via MQTT au dashboard MaxLink
Version avec système de logging unifié
"""

import os
import sys
import time
import json
import logging
from datetime import datetime
from pathlib import Path

# Configuration du logging unifié - Aligné avec le système bash
base_dir = Path(__file__).resolve().parents[4]  # Remonter à la racine MaxLink
log_dir = base_dir / "logs" / "widgets"
log_dir.mkdir(parents=True, exist_ok=True)

# Nom du script pour le logging
script_name = "servermonitoring_collector"
log_file = log_dir / f"{script_name}.log"

# Configuration du logging - Format identique aux scripts bash
class MaxLinkFormatter(logging.Formatter):
    """Formateur personnalisé pour correspondre au format bash"""
    def format(self, record):
        # Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] [script_name] Message
        timestamp = datetime.fromtimestamp(record.created).strftime('%Y-%m-%d %H:%M:%S')
        return f"[{timestamp}] [{record.levelname}] [{script_name}] {record.getMessage()}"

# Configuration des handlers
file_handler = logging.FileHandler(log_file, mode='a', encoding='utf-8')
file_handler.setFormatter(MaxLinkFormatter())

console_handler = logging.StreamHandler()
console_handler.setFormatter(MaxLinkFormatter())

# Configuration du logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
logger.addHandler(file_handler)
logger.addHandler(console_handler)

# Header de démarrage
def log_startup():
    """Écrit le header de démarrage dans le log"""
    with open(log_file, 'a') as f:
        f.write("\n")
        f.write("="*80 + "\n")
        f.write(f"DÉMARRAGE: {script_name}\n")
        f.write(f"Description: Collecteur de métriques système pour MaxLink\n")
        f.write(f"Date: {datetime.now().strftime('%c')}\n")
        f.write(f"Utilisateur: {os.environ.get('USER', 'unknown')}\n")
        f.write(f"Répertoire: {os.getcwd()}\n")
        f.write("="*80 + "\n")
        f.write("\n")
    logger.info("Collecteur Server Monitoring démarré")

# Footer de fin
def log_shutdown(exit_code=0):
    """Écrit le footer de fin dans le log"""
    with open(log_file, 'a') as f:
        f.write("\n")
        f.write("="*80 + "\n")
        f.write(f"FIN: {script_name}\n")
        f.write(f"Code de sortie: {exit_code}\n")
        f.write(f"Date: {datetime.now().strftime('%c')}\n")
        f.write("="*80 + "\n")
        f.write("\n")

# Import des modules nécessaires
try:
    import psutil
    logger.debug("Module psutil importé avec succès")
except ImportError:
    logger.error("Module psutil non installé")
    log_shutdown(1)
    sys.exit(1)

try:
    import paho.mqtt.client as mqtt
    logger.debug("Module paho-mqtt importé avec succès")
except ImportError:
    logger.error("Module paho-mqtt non installé")
    log_shutdown(1)
    sys.exit(1)

class SystemMetricsCollector:
    def __init__(self, config_file):
        """Initialise le collecteur avec la configuration du widget"""
        logger.info(f"Initialisation du collecteur avec config: {config_file}")
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
        
        # Statistiques pour le logging
        self.stats = {
            'messages_sent': 0,
            'errors': 0,
            'start_time': time.time()
        }
        
    def load_config(self, config_file):
        """Charge la configuration depuis servermonitoring_widget.json"""
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
            logger.info("Configuration chargée avec succès")
            logger.debug(f"Intervalles: fast={config['collector']['update_intervals']['fast']}s, "
                        f"normal={config['collector']['update_intervals']['normal']}s, "
                        f"slow={config['collector']['update_intervals']['slow']}s")
            return config
        except Exception as e:
            logger.error(f"Erreur chargement config: {e}")
            log_shutdown(1)
            sys.exit(1)
    
    def connect_mqtt(self):
        """Connexion au broker MQTT"""
        try:
            broker = self.config['mqtt']['broker']
            logger.info(f"Tentative de connexion MQTT à {broker['host']}:{broker['port']}")
            
            self.mqtt_client = mqtt.Client()
            
            # Callbacks
            self.mqtt_client.on_connect = self.on_connect
            self.mqtt_client.on_disconnect = self.on_disconnect
            self.mqtt_client.on_publish = self.on_publish
            
            # Authentification
            self.mqtt_client.username_pw_set(
                broker['username'],
                broker['password']
            )
            logger.debug(f"Authentification configurée: user={broker['username']}")
            
            # Connexion
            self.mqtt_client.connect(broker['host'], broker['port'], 60)
            self.mqtt_client.loop_start()
            
            # Attendre la connexion
            logger.info("Attente de la connexion MQTT...")
            timeout = 10
            while not self.connected and timeout > 0:
                time.sleep(0.5)
                timeout -= 0.5
            
            if not self.connected:
                logger.error("Timeout de connexion MQTT")
                return False
            
            logger.success("Connexion MQTT établie")
            return True
            
        except Exception as e:
            logger.error(f"Erreur connexion MQTT: {e}")
            self.stats['errors'] += 1
            return False
    
    def on_connect(self, client, userdata, flags, rc):
        """Callback de connexion"""
        if rc == 0:
            logger.info("Connecté au broker MQTT avec succès")
            self.connected = True
        else:
            logger.error(f"Échec connexion MQTT, code: {rc}")
            self.connected = False
    
    def on_disconnect(self, client, userdata, rc):
        """Callback de déconnexion"""
        logger.warning(f"Déconnecté du broker MQTT (code: {rc})")
        self.connected = False
    
    def on_publish(self, client, userdata, mid):
        """Callback de publication"""
        self.stats['messages_sent'] += 1
        if self.stats['messages_sent'] % 100 == 0:
            logger.info(f"Messages envoyés: {self.stats['messages_sent']}")
    
    def publish_metric(self, topic, value, unit=None):
        """Publie une métrique sur MQTT"""
        if not self.connected:
            logger.warning(f"Tentative de publication sur {topic} mais non connecté")
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "value": value
            }
            
            if unit:
                payload["unit"] = unit
            
            result = self.mqtt_client.publish(topic, json.dumps(payload))
            
            if result.rc == 0:
                logger.debug(f"Publié: {topic} = {value}{unit or ''}")
                return True
            else:
                logger.error(f"Échec publication sur {topic}, rc={result.rc}")
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
                topic = f"rpi/system/cpu/core{i}"
                self.publish_metric(topic, round(percent, 1), "%")
            
            logger.debug(f"CPU collecté: {len(cpu_percents)} cores")
                
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
                    
                self.publish_metric("rpi/system/temperature/cpu", round(temp_c, 1), "°C")
                # GPU = CPU sur Raspberry Pi
                self.publish_metric("rpi/system/temperature/gpu", round(temp_c, 1), "°C")
                
                if temp_c > 70:
                    logger.warning(f"Température élevée: {temp_c:.1f}°C")
            else:
                logger.warning("Fichier de température non trouvé")
                
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
                self.publish_metric("rpi/system/frequency/cpu", freq_ghz, "GHz")
            
            # Fréquence GPU (spécifique Raspberry Pi)
            gpu_freq_file = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if os.path.exists(gpu_freq_file):
                with open(gpu_freq_file, 'r') as f:
                    freq_khz = float(f.read().strip())
                    freq_mhz = round(freq_khz / 1000, 0)
                    self.publish_metric("rpi/system/frequency/gpu", freq_mhz, "MHz")
                    
        except Exception as e:
            logger.error(f"Erreur collecte fréquences: {e}")
            self.stats['errors'] += 1
    
    def collect_memory_metrics(self):
        """Collecte les métriques mémoire"""
        try:
            # RAM
            ram = psutil.virtual_memory()
            self.publish_metric("rpi/system/memory/ram", round(ram.percent, 1), "%")
            
            if ram.percent > 80:
                logger.warning(f"Utilisation RAM élevée: {ram.percent:.1f}%")
            
            # SWAP
            swap = psutil.swap_memory()
            self.publish_metric("rpi/system/memory/swap", round(swap.percent, 1), "%")
            
            # Disque
            disk = psutil.disk_usage('/')
            self.publish_metric("rpi/system/memory/disk", round(disk.percent, 1), "%")
            
            if disk.percent > 80:
                logger.warning(f"Espace disque faible: {disk.percent:.1f}% utilisé")
                
        except Exception as e:
            logger.error(f"Erreur collecte mémoire: {e}")
            self.stats['errors'] += 1
    
    def collect_uptime_metrics(self):
        """Collecte l'uptime"""
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = int(float(f.readline().split()[0]))
                self.publish_metric("rpi/system/uptime", uptime_seconds, "seconds")
                
                # Log toutes les heures
                if uptime_seconds % 3600 < 30:
                    days = uptime_seconds // 86400
                    hours = (uptime_seconds % 86400) // 3600
                    logger.info(f"Uptime système: {days}j {hours}h")
                    
        except Exception as e:
            logger.error(f"Erreur collecte uptime: {e}")
            self.stats['errors'] += 1
    
    def log_statistics(self):
        """Affiche les statistiques périodiquement"""
        runtime = time.time() - self.stats['start_time']
        hours = int(runtime // 3600)
        minutes = int((runtime % 3600) // 60)
        
        logger.info(f"=== STATISTIQUES ===")
        logger.info(f"Temps d'exécution: {hours}h {minutes}m")
        logger.info(f"Messages envoyés: {self.stats['messages_sent']}")
        logger.info(f"Erreurs: {self.stats['errors']}")
        if self.stats['messages_sent'] > 0:
            error_rate = (self.stats['errors'] / self.stats['messages_sent']) * 100
            logger.info(f"Taux d'erreur: {error_rate:.2f}%")
        logger.info("===================")
    
    def run(self):
        """Boucle principale du collecteur"""
        logger.info("Démarrage de la boucle principale du collecteur")
        
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT")
            return
        
        logger.info("Collecteur opérationnel - Début de la collecte des métriques")
        
        # Compteur pour les statistiques
        stats_counter = 0
        
        try:
            while True:
                current_time = time.time()
                
                # Groupe rapide (CPU, RAM)
                if current_time - self.last_update['fast'] >= self.intervals['fast']:
                    logger.debug("Collecte groupe rapide")
                    self.collect_cpu_metrics()
                    self.collect_memory_metrics()  # RAM seulement
                    self.last_update['fast'] = current_time
                
                # Groupe normal (Températures, Fréquences)
                if current_time - self.last_update['normal'] >= self.intervals['normal']:
                    logger.debug("Collecte groupe normal")
                    self.collect_temperature_metrics()
                    self.collect_frequency_metrics()
                    self.last_update['normal'] = current_time
                
                # Groupe lent (SWAP, Disk, Uptime)
                if current_time - self.last_update['slow'] >= self.intervals['slow']:
                    logger.debug("Collecte groupe lent")
                    self.collect_memory_metrics()  # Toutes les métriques
                    self.collect_uptime_metrics()
                    self.last_update['slow'] = current_time
                
                # Afficher les statistiques toutes les 5 minutes
                stats_counter += 1
                if stats_counter >= 3000:  # 300 secondes à 0.1s par boucle
                    self.log_statistics()
                    stats_counter = 0
                
                # Pause pour éviter la surcharge CPU
                time.sleep(0.1)
                
        except KeyboardInterrupt:
            logger.info("Arrêt demandé par l'utilisateur (Ctrl+C)")
        except Exception as e:
            logger.error(f"Erreur dans la boucle principale: {e}")
            self.stats['errors'] += 1
        finally:
            if self.mqtt_client:
                logger.info("Fermeture de la connexion MQTT...")
                self.mqtt_client.loop_stop()
                self.mqtt_client.disconnect()
            
            # Statistiques finales
            self.log_statistics()
            logger.info("Collecteur arrêté")

# Extension du logger pour ajouter la méthode success
def success(self, message):
    """Log un message de succès au niveau INFO avec préfixe"""
    self.info(f"[SUCCESS] {message}")

# Ajouter la méthode au logger
logger.success = lambda msg: success(logger, msg)

if __name__ == "__main__":
    # Log de démarrage
    log_startup()
    
    # Chemin vers servermonitoring_widget.json
    widget_dir = os.path.dirname(os.path.abspath(__file__))
    config_file = os.path.join(widget_dir, "servermonitoring_widget.json")
    
    logger.info(f"Répertoire du widget: {widget_dir}")
    logger.info(f"Fichier de configuration: {config_file}")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        log_shutdown(1)
        sys.exit(1)
    
    exit_code = 0
    try:
        # Lancer le collecteur
        collector = SystemMetricsCollector(config_file)
        collector.run()
    except Exception as e:
        logger.error(f"Erreur fatale: {e}")
        exit_code = 1
    finally:
        # Log de fin
        log_shutdown(exit_code)
        sys.exit(exit_code)