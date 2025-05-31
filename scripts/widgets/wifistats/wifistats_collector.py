#!/usr/bin/env python3
"""
Collecteur de statistiques WiFi pour le widget WiFi Stats
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
        
        # Interface WiFi (généralement wlan0)
        self.interface = "wlan0"
        
        logger.info(f"Collecteur WiFi Stats initialisé - Version {self.config['widget']['version']}")
    
    def load_config(self, config_file):
        """Charge la configuration"""
        try:
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Erreur chargement config: {e}")
            sys.exit(1)
    
    def connect_mqtt(self):
        """Connexion au broker MQTT"""
        try:
            self.mqtt_client = mqtt.Client()
            
            # Callbacks
            self.mqtt_client.on_connect = lambda c,u,f,rc: self._on_connect(rc)
            self.mqtt_client.on_disconnect = lambda c,u,rc: self._on_disconnect(rc)
            
            # Authentification
            self.mqtt_client.username_pw_set(
                self.mqtt_config['username'],
                self.mqtt_config['password']
            )
            
            # Connexion
            logger.info(f"Connexion à {self.mqtt_config['host']}:{self.mqtt_config['port']}")
            self.mqtt_client.connect(
                self.mqtt_config['host'], 
                self.mqtt_config['port'], 
                60
            )
            
            self.mqtt_client.loop_start()
            
            # Attendre la connexion
            timeout = 10
            while not self.connected and timeout > 0:
                time.sleep(0.5)
                timeout -= 0.5
            
            return self.connected
            
        except Exception as e:
            logger.error(f"Erreur connexion MQTT: {e}")
            return False
    
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
    
    def publish_data(self, topic, data):
        """Publie des données sur MQTT"""
        if not self.connected:
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                **data
            }
            
            result = self.mqtt_client.publish(topic, json.dumps(payload))
            return result.rc == 0
            
        except Exception as e:
            logger.error(f"Erreur publication: {e}")
            return False
    
    def get_ap_clients(self):
        """Récupère la liste des clients connectés à l'AP"""
        clients = []
        
        try:
            # Utiliser iw pour lister les stations
            cmd = f"iw dev {self.interface} station dump"
            result = subprocess.run(cmd.split(), capture_output=True, text=True)
            
            if result.returncode == 0:
                current_client = {}
                
                for line in result.stdout.split('\n'):
                    if line.startswith('Station'):
                        # Nouveau client
                        if current_client:
                            clients.append(current_client)
                        mac = line.split()[1]
                        current_client = {'mac': mac}
                    elif 'signal:' in line:
                        # Signal en dBm
                        match = re.search(r'signal:\s*(-?\d+)', line)
                        if match:
                            current_client['signal'] = int(match.group(1))
                    elif 'connected time:' in line:
                        # Temps de connexion
                        match = re.search(r'connected time:\s*(\d+)', line)
                        if match:
                            current_client['connected_seconds'] = int(match.group(1))
                
                # Ajouter le dernier client
                if current_client:
                    clients.append(current_client)
            
            # Enrichir avec les infos DHCP si disponibles
            self._enrich_with_dhcp_info(clients)
            
        except Exception as e:
            logger.error(f"Erreur récupération clients: {e}")
        
        return clients
    
    def _enrich_with_dhcp_info(self, clients):
        """Enrichit les infos clients avec les données DHCP"""
        try:
            # Lire le fichier de leases dnsmasq
            leases_file = "/var/lib/misc/dnsmasq.leases"
            if os.path.exists(leases_file):
                with open(leases_file, 'r') as f:
                    for line in f:
                        parts = line.strip().split()
                        if len(parts) >= 4:
                            mac = parts[1].lower()
                            ip = parts[2]
                            name = parts[3] if parts[3] != '*' else None
                            
                            # Chercher le client correspondant
                            for client in clients:
                                if client['mac'].lower() == mac:
                                    client['ip'] = ip
                                    if name:
                                        client['name'] = name
                                    break
        except Exception as e:
            logger.debug(f"Impossible de lire les leases DHCP: {e}")
    
    def get_ap_status(self):
        """Récupère l'état de l'AP"""
        status = {
            'ssid': None,
            'channel': None,
            'frequency': None
        }
        
        try:
            # Utiliser iw pour obtenir les infos
            cmd = f"iw dev {self.interface} info"
            result = subprocess.run(cmd.split(), capture_output=True, text=True)
            
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if 'ssid' in line:
                        match = re.search(r'ssid\s+(.+)', line)
                        if match:
                            status['ssid'] = match.group(1)
                    elif 'channel' in line:
                        match = re.search(r'channel\s+(\d+)', line)
                        if match:
                            status['channel'] = int(match.group(1))
                    elif 'freq:' in line:
                        match = re.search(r'freq:\s*(\d+)', line)
                        if match:
                            status['frequency'] = int(match.group(1))
        
        except Exception as e:
            logger.error(f"Erreur récupération status AP: {e}")
        
        return status
    
    def collect_and_publish(self):
        """Collecte et publie les données"""
        try:
            # Récupérer les clients
            clients = self.get_ap_clients()
            
            # Publier la liste des clients
            self.publish_data("rpi/network/wifi/clients", {
                "clients": clients,
                "count": len(clients)
            })
            
            # Récupérer et publier le status
            status = self.get_ap_status()
            status['clients_count'] = len(clients)
            
            self.publish_data("rpi/network/wifi/status", status)
            
            logger.info(f"Données publiées - {len(clients)} clients connectés")
            
        except Exception as e:
            logger.error(f"Erreur collecte/publication: {e}")
    
    def run(self):
        """Boucle principale"""
        logger.info("Démarrage du collecteur WiFi Stats")
        
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT")
            return
        
        logger.info("Collecteur opérationnel")
        
        try:
            while True:
                self.collect_and_publish()
                time.sleep(self.update_interval)
                
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
    # Configuration
    config_file = os.environ.get('CONFIG_FILE')
    
    if not config_file and len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    if not config_file:
        widget_dir = os.path.dirname(os.path.abspath(__file__))
        config_file = os.path.join(widget_dir, "wifistats_widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    # Lancer le collecteur
    collector = WiFiStatsCollector(config_file)
    collector.run()