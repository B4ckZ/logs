#!/usr/bin/env python3
"""
Collecteur de statistiques WiFi pour le widget WiFi Stats
Version améliorée avec métriques étendues : nom, IP, MAC, signal et uptime client
"""

import os
import sys
import time
import json
import subprocess
import re
import logging
from datetime import datetime, timedelta

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
        
        logger.info(f"Collecteur WiFi Stats initialisé - Version {self.config['widget']['version']}")
        logger.info(f"Retry: {self.retry_enabled}, Delay: {self.retry_delay}s, Max: {self.max_retries}")
    
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
                
                # Vérifier si on a atteint la limite
                if self.max_retries > 0 and self.connection_attempts > self.max_retries:
                    logger.error(f"Limite de tentatives atteinte ({self.max_retries})")
                    return False
                
                logger.info(f"Tentative de connexion MQTT #{self.connection_attempts} à {self.mqtt_config['host']}:{self.mqtt_config['port']}")
                
                # Créer le client MQTT
                self.mqtt_client = mqtt.Client()
                
                # Callbacks
                self.mqtt_client.on_connect = lambda c,u,f,rc: self._on_connect(rc)
                self.mqtt_client.on_disconnect = lambda c,u,rc: self._on_disconnect(rc)
                
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
        """Publie des données sur MQTT avec gestion d'erreur"""
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
    
    def get_signal_quality(self, signal_dbm):
        """Convertit le signal dBm en qualité pourcentage"""
        # Conversion approximative dBm vers %
        # -30 dBm = 100% (excellent)
        # -90 dBm = 0% (très mauvais)
        if signal_dbm >= -30:
            return 100
        elif signal_dbm <= -90:
            return 0
        else:
            # Interpolation linéaire
            return int(((signal_dbm + 90) / 60) * 100)
    
    def format_uptime(self, seconds):
        """Formate l'uptime en format lisible"""
        if seconds < 60:
            return f"{seconds}s"
        elif seconds < 3600:
            minutes = seconds // 60
            return f"{minutes}m"
        elif seconds < 86400:
            hours = seconds // 3600
            minutes = (seconds % 3600) // 60
            return f"{hours}h {minutes}m"
        else:
            days = seconds // 86400
            hours = (seconds % 86400) // 3600
            return f"{days}j {hours}h"
    
    def get_ap_clients(self):
        """Récupère la liste des clients connectés à l'AP avec toutes les métriques"""
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
                            # Traiter le client précédent
                            self._process_client(current_client)
                            clients.append(current_client)
                        
                        mac = line.split()[1]
                        current_client = {'mac': mac}
                        
                    elif 'signal:' in line:
                        # Signal en dBm
                        match = re.search(r'signal:\s*(-?\d+)', line)
                        if match:
                            signal = int(match.group(1))
                            current_client['signal'] = signal
                            current_client['signal_quality'] = self.get_signal_quality(signal)
                            
                    elif 'connected time:' in line:
                        # Temps de connexion en secondes
                        match = re.search(r'connected time:\s*(\d+)', line)
                        if match:
                            connected_seconds = int(match.group(1))
                            current_client['connected_seconds'] = connected_seconds
                            current_client['uptime'] = self.format_uptime(connected_seconds)
                            
                    elif 'rx bytes:' in line:
                        # Octets reçus
                        match = re.search(r'rx bytes:\s*(\d+)', line)
                        if match:
                            current_client['rx_bytes'] = int(match.group(1))
                            
                    elif 'tx bytes:' in line:
                        # Octets transmis
                        match = re.search(r'tx bytes:\s*(\d+)', line)
                        if match:
                            current_client['tx_bytes'] = int(match.group(1))
                
                # Ajouter le dernier client
                if current_client and 'mac' in current_client:
                    self._process_client(current_client)
                    clients.append(current_client)
            
            # Enrichir avec les infos DHCP
            self._enrich_with_dhcp_info(clients)
            
            # Enrichir avec les noms d'hôtes si possible
            self._enrich_with_hostnames(clients)
            
        except Exception as e:
            logger.error(f"Erreur récupération clients: {e}")
            self.stats['errors'] += 1
        
        return clients
    
    def _process_client(self, client):
        """Traite les données d'un client"""
        mac = client.get('mac', '')
        
        # Gérer le cache pour calculer l'uptime total si le client se reconnecte
        current_time = time.time()
        
        if mac not in self.client_first_seen:
            self.client_first_seen[mac] = current_time
        
        # Si le client n'a pas d'uptime (vient de se connecter), calculer depuis le cache
        if 'connected_seconds' not in client:
            total_seconds = int(current_time - self.client_first_seen[mac])
            client['connected_seconds'] = total_seconds
            client['uptime'] = self.format_uptime(total_seconds)
    
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
                            lease_time = parts[0]
                            mac = parts[1].lower()
                            ip = parts[2]
                            name = parts[3] if parts[3] != '*' else None
                            
                            # Chercher le client correspondant
                            for client in clients:
                                if client.get('mac', '').lower() == mac:
                                    client['ip'] = ip
                                    if name and name != '*':
                                        client['name'] = name
                                    break
        except Exception as e:
            logger.debug(f"Impossible de lire les leases DHCP: {e}")
    
    def _enrich_with_hostnames(self, clients):
        """Tente de résoudre les noms d'hôtes pour les clients"""
        for client in clients:
            try:
                # Si on a une IP mais pas de nom, tenter une résolution inverse
                if 'ip' in client and 'name' not in client:
                    # Utiliser getent ou nslookup
                    cmd = f"getent hosts {client['ip']}"
                    result = subprocess.run(cmd.split(), capture_output=True, text=True)
                    
                    if result.returncode == 0 and result.stdout:
                        parts = result.stdout.strip().split()
                        if len(parts) > 1:
                            hostname = parts[1].split('.')[0]  # Prendre seulement le nom court
                            if hostname != client['ip']:  # Éviter de mettre l'IP comme nom
                                client['name'] = hostname
                
                # Si toujours pas de nom, utiliser un nom générique basé sur le fabricant MAC
                if 'name' not in client:
                    client['name'] = self._get_mac_vendor(client['mac'])
                    
            except Exception as e:
                logger.debug(f"Erreur résolution hostname: {e}")
    
    def _get_mac_vendor(self, mac):
        """Retourne un nom basé sur le préfixe MAC (OUI)"""
        # Dictionnaire simplifié des préfixes MAC courants
        mac_prefixes = {
            'b8:27:eb': 'Raspberry-Pi',
            'dc:a6:32': 'Raspberry-Pi',
            'e4:5f:01': 'Raspberry-Pi',
            '00:1e:06': 'Wibrain',
            'ac:bc:32': 'Apple',
            '00:17:c4': 'Netgear',
            '00:1f:33': 'Netgear',
            'f4:f5:d8': 'Google',
            '94:94:26': 'ASUS',
            '00:e0:4c': 'Realtek',
            'b4:b5:2f': 'Hewlett-Packard',
            '00:25:00': 'Apple',
            '68:7f:74': 'Cisco-Linksys',
            'dc:85:de': 'AzureWave',
            'b0:c0:90': 'Chicony',
        }
        
        prefix = mac[:8].lower()
        for mac_prefix, vendor in mac_prefixes.items():
            if prefix.startswith(mac_prefix):
                return f"{vendor}-Device"
        
        return f"Device-{mac[-5:].replace(':', '')}"
    
    def get_ap_status(self):
        """Récupère l'état de l'AP"""
        status = {
            'ssid': None,
            'channel': None,
            'frequency': None,
            'mode': 'unknown'
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
                    elif 'type' in line:
                        if 'AP' in line:
                            status['mode'] = 'AP'
                        elif 'managed' in line:
                            status['mode'] = 'client'
        
        except Exception as e:
            logger.error(f"Erreur récupération status AP: {e}")
            self.stats['errors'] += 1
        
        return status
    
    def collect_and_publish(self):
        """Collecte et publie les données"""
        try:
            # Récupérer les clients
            clients = self.get_ap_clients()
            
            # Publier la liste des clients avec toutes les métriques
            self.publish_data("rpi/network/wifi/clients", {
                "clients": clients,
                "count": len(clients)
            })
            
            # Récupérer et publier le status
            status = self.get_ap_status()
            status['clients_count'] = len(clients)
            
            self.publish_data("rpi/network/wifi/status", status)
            
            # Log détaillé pour debug
            logger.info(f"Données publiées - {len(clients)} clients connectés, mode: {status.get('mode', 'unknown')}")
            for client in clients:
                logger.debug(f"  • {client.get('name', 'Unknown')} - IP: {client.get('ip', 'N/A')} - "
                           f"MAC: {client.get('mac', 'N/A')} - Signal: {client.get('signal', 'N/A')}dBm "
                           f"({client.get('signal_quality', 0)}%) - Uptime: {client.get('uptime', 'N/A')}")
            
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
            f"Erreurs: {self.stats['errors']} | "
            f"Échecs connexion: {self.stats['connection_failures']}"
        )
    
    def run(self):
        """Boucle principale avec gestion d'erreurs robuste"""
        logger.info("Démarrage du collecteur WiFi Stats")
        
        # Attendre un peu au démarrage pour laisser le système se stabiliser
        startup_delay = int(os.environ.get('STARTUP_DELAY', '10'))
        if startup_delay > 0:
            logger.info(f"Pause de {startup_delay}s au démarrage...")
            time.sleep(startup_delay)
        
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
                    # Vérifier la connexion MQTT
                    if not self.connected:
                        logger.warning("Connexion MQTT perdue, reconnexion...")
                        if not self.connect_mqtt():
                            logger.error("Reconnexion échouée")
                            break
                    
                    # Collecter et publier
                    self.collect_and_publish()
                    
                    # Afficher les statistiques toutes les 5 minutes
                    stats_counter += 1
                    if stats_counter >= (300 // self.update_interval):
                        self.log_statistics()
                        stats_counter = 0
                    
                    # Réinitialiser le compteur d'erreurs si tout va bien
                    error_count = 0
                    
                    # Pause selon l'intervalle configuré
                    time.sleep(self.update_interval)
                    
                except Exception as e:
                    error_count += 1
                    logger.error(f"Erreur dans la boucle de collecte: {e}")
                    self.stats['errors'] += 1
                    
                    # Si trop d'erreurs consécutives, arrêter
                    if error_count > 10:
                        logger.error("Trop d'erreurs consécutives, arrêt du collecteur")
                        break
                    
                    time.sleep(10)  # Pause plus longue en cas d'erreur
                
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