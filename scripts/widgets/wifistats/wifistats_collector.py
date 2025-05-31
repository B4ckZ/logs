#!/usr/bin/env python3
"""
Collecteur de statistiques WiFi pour le widget WiFi Stats
Version simplifiée : nom, MAC et uptime uniquement
"""

import os
import sys
import time
import json
import subprocess
import re
import logging
from datetime import datetime

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('wifistats')

try:
    import paho.mqtt.client as mqtt
except ImportError:
    logger.error("Module paho-mqtt non installé")
    sys.exit(1)

class WiFiStatsCollector:
    def __init__(self, config_file):
        """Initialise le collecteur"""
        self.config = self.load_config(config_file)
        self.mqtt_client = None
        self.connected = False
        
        # Configuration
        self.mqtt_config = self.config['mqtt']['broker']
        self.update_interval = self.config['collector']['update_intervals']['default']
        
        # Configuration retry depuis l'environnement
        self.retry_enabled = os.environ.get('MQTT_RETRY_ENABLED', 'true').lower() == 'true'
        self.retry_delay = int(os.environ.get('MQTT_RETRY_DELAY', '10'))
        self.max_retries = int(os.environ.get('MQTT_MAX_RETRIES', '0'))  # 0 = infini
        
        # Compteur de tentatives
        self.connection_attempts = 0
        
        # Interface WiFi (généralement wlan0)
        self.interface = "wlan0"
        
        # Cache pour stocker les temps de connexion
        self.client_first_seen = {}
        
        # Statistiques
        self.stats = {
            'messages_sent': 0,
            'errors': 0,
            'start_time': time.time(),
            'connection_failures': 0
        }
        
        logger.info(f"Collecteur WiFi Stats simplifié initialisé - Version {self.config['widget']['version']}")
    
    def load_config(self, config_file):
        """Charge la configuration"""
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
                
                if self.max_retries > 0 and self.connection_attempts > self.max_retries:
                    logger.error(f"Limite de tentatives atteinte ({self.max_retries})")
                    return False
                
                logger.info(f"Tentative de connexion MQTT #{self.connection_attempts}")
                
                self.mqtt_client = mqtt.Client()
                self.mqtt_client.on_connect = lambda c,u,f,rc: self._on_connect(rc)
                self.mqtt_client.on_disconnect = lambda c,u,rc: self._on_disconnect(rc)
                
                self.mqtt_client.username_pw_set(
                    self.mqtt_config['username'],
                    self.mqtt_config['password']
                )
                
                self.mqtt_client.reconnect_delay_set(min_delay=1, max_delay=120)
                
                self.mqtt_client.connect(
                    self.mqtt_config['host'], 
                    self.mqtt_config['port'], 
                    60
                )
                
                self.mqtt_client.loop_start()
                
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
                
                logger.info(f"Nouvelle tentative dans {self.retry_delay} secondes...")
                time.sleep(self.retry_delay)
    
    def _on_connect(self, rc):
        """Callback de connexion"""
        if rc == 0:
            logger.info("Connecté au broker MQTT")
            self.connected = True
        else:
            logger.error(f"Échec connexion MQTT, code: {rc}")
    
    def _on_disconnect(self, rc):
        """Callback de déconnexion"""
        logger.warning(f"Déconnecté du broker MQTT (code: {rc})")
        self.connected = False
        self.stats['connection_failures'] += 1
    
    def publish_data(self, topic, data):
        """Publie des données sur MQTT"""
        if not self.connected:
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                **data
            }
            
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
    
    def format_uptime(self, seconds):
        """Formate l'uptime en format lisible"""
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        minutes = (seconds % 3600) // 60
        secs = seconds % 60
        
        # Format complet avec padding : 00j 00h 00m 00s
        return f"{days:02d}j {hours:02d}h {minutes:02d}m {secs:02d}s"
    
    def get_ap_clients(self):
        """Récupère la liste simplifiée des clients connectés"""
        clients = []
        
        try:
            # Vérifier que l'interface existe et est en mode AP
            check_cmd = f"iw dev {self.interface} info"
            check_result = subprocess.run(check_cmd.split(), capture_output=True, text=True)
            
            if check_result.returncode != 0 or 'type AP' not in check_result.stdout:
                logger.debug("Interface non en mode AP ou non disponible")
                return clients
            
            # Utiliser iw pour lister les stations
            cmd = f"iw dev {self.interface} station dump"
            result = subprocess.run(cmd.split(), capture_output=True, text=True)
            
            if result.returncode == 0:
                current_client = {}
                
                for line in result.stdout.split('\n'):
                    if line.startswith('Station'):
                        # Nouveau client
                        if current_client and 'mac' in current_client:
                            clients.append(current_client)
                        
                        mac = line.split()[1]
                        current_client = {'mac': mac}
                        
                    elif 'connected time:' in line:
                        # Temps de connexion en secondes
                        match = re.search(r'connected time:\s*(\d+)', line)
                        if match:
                            connected_seconds = int(match.group(1))
                            current_client['uptime'] = self.format_uptime(connected_seconds)
                
                # Ajouter le dernier client
                if current_client and 'mac' in current_client:
                    clients.append(current_client)
            
            # Enrichir avec les noms depuis DHCP
            self._enrich_with_names(clients)
            
        except Exception as e:
            logger.error(f"Erreur récupération clients: {e}")
            self.stats['errors'] += 1
        
        return clients
    
    def _enrich_with_names(self, clients):
        """Ajoute uniquement les noms des devices"""
        try:
            # Lire le fichier de leases dnsmasq
            leases_file = "/var/lib/misc/dnsmasq.leases"
            if os.path.exists(leases_file):
                with open(leases_file, 'r') as f:
                    for line in f:
                        parts = line.strip().split()
                        if len(parts) >= 4:
                            mac = parts[1].lower()
                            name = parts[3] if parts[3] != '*' else None
                            
                            # Chercher le client correspondant
                            for client in clients:
                                if client.get('mac', '').lower() == mac:
                                    if name and name != '*':
                                        client['name'] = name
                                    break
        except Exception as e:
            logger.debug(f"Impossible de lire les leases DHCP: {e}")
        
        # Si pas de nom, utiliser un nom générique basé sur le MAC
        for client in clients:
            if 'name' not in client:
                client['name'] = self._get_device_name(client['mac'])
            # S'assurer qu'il y a toujours un uptime
            if 'uptime' not in client:
                client['uptime'] = '0s'
    
    def _get_device_name(self, mac):
        """Génère un nom basique basé sur le MAC"""
        # Utiliser les 3 derniers octets du MAC pour créer un nom unique
        mac_suffix = mac.replace(':', '')[-6:].upper()
        return f"Device-{mac_suffix}"
    
    def get_ap_status(self):
        """Récupère l'état basique de l'AP"""
        status = {
            'ssid': None,
            'mode': 'unknown'
        }
        
        try:
            cmd = f"iw dev {self.interface} info"
            result = subprocess.run(cmd.split(), capture_output=True, text=True)
            
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if 'ssid' in line:
                        match = re.search(r'ssid\s+(.+)', line)
                        if match:
                            status['ssid'] = match.group(1)
                    elif 'type' in line:
                        if 'AP' in line:
                            status['mode'] = 'AP'
                        elif 'managed' in line:
                            status['mode'] = 'client'
        
        except Exception as e:
            logger.error(f"Erreur récupération status AP: {e}")
        
        return status
    
    def collect_and_publish(self):
        """Collecte et publie les données simplifiées"""
        try:
            # Récupérer les clients
            clients = self.get_ap_clients()
            
            # Format simplifié : juste nom, MAC et uptime
            simplified_clients = []
            for client in clients:
                simplified_clients.append({
                    'name': client.get('name', 'Unknown'),
                    'mac': client.get('mac', ''),
                    'uptime': client.get('uptime', '0s')
                })
            
            # Publier la liste des clients
            self.publish_data("rpi/network/wifi/clients", {
                "clients": simplified_clients,
                "count": len(simplified_clients)
            })
            
            # Récupérer et publier le status minimal
            status = self.get_ap_status()
            status['clients_count'] = len(clients)
            
            self.publish_data("rpi/network/wifi/status", status)
            
            logger.debug(f"Données publiées - {len(clients)} clients")
            
        except Exception as e:
            logger.error(f"Erreur collecte/publication: {e}")
            self.stats['errors'] += 1
    
    def log_statistics(self):
        """Affiche les statistiques"""
        runtime = time.time() - self.stats['start_time']
        hours = int(runtime // 3600)
        minutes = int((runtime % 3600) // 60)
        
        logger.info(
            f"Stats - Runtime: {hours}h {minutes}m | "
            f"Messages: {self.stats['messages_sent']} | "
            f"Erreurs: {self.stats['errors']}"
        )
    
    def run(self):
        """Boucle principale"""
        logger.info("Démarrage du collecteur WiFi Stats simplifié")
        
        startup_delay = int(os.environ.get('STARTUP_DELAY', '10'))
        if startup_delay > 0:
            logger.info(f"Pause de {startup_delay}s au démarrage...")
            time.sleep(startup_delay)
        
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT")
            return
        
        logger.info("Collecteur opérationnel")
        
        stats_counter = 0
        error_count = 0
        
        try:
            while True:
                try:
                    if not self.connected:
                        logger.warning("Connexion MQTT perdue, reconnexion...")
                        if not self.connect_mqtt():
                            logger.error("Reconnexion échouée")
                            break
                    
                    self.collect_and_publish()
                    
                    stats_counter += 1
                    if stats_counter >= (300 // self.update_interval):
                        self.log_statistics()
                        stats_counter = 0
                    
                    error_count = 0
                    time.sleep(self.update_interval)
                    
                except Exception as e:
                    error_count += 1
                    logger.error(f"Erreur dans la boucle: {e}")
                    self.stats['errors'] += 1
                    
                    if error_count > 10:
                        logger.error("Trop d'erreurs consécutives")
                        break
                    
                    time.sleep(10)
                
        except KeyboardInterrupt:
            logger.info("Arrêt demandé")
        finally:
            if self.mqtt_client:
                self.mqtt_client.loop_stop()
                self.mqtt_client.disconnect()
            
            self.log_statistics()
            logger.info("Collecteur arrêté")

if __name__ == "__main__":
    config_file = os.environ.get('CONFIG_FILE')
    
    if not config_file and len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    if not config_file:
        widget_dir = os.path.dirname(os.path.abspath(__file__))
        config_file = os.path.join(widget_dir, "wifistats_widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    collector = WiFiStatsCollector(config_file)
    collector.run()