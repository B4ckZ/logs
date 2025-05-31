#!/usr/bin/env python3
"""
Collecteur de statistiques MQTT pour le widget MQTT Stats
Version utilisant les topics système $SYS de Mosquitto
"""

import os
import sys
import time
import json
import re
import logging
from datetime import datetime, timedelta
from collections import defaultdict

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('mqttstats')

try:
    import paho.mqtt.client as mqtt
except ImportError:
    logger.error("Module paho-mqtt non installé")
    sys.exit(1)

class MQTTStatsCollector:
    def __init__(self, config_file):
        """Initialise le collecteur"""
        self.config = self.load_config(config_file)
        self.mqtt_client = None
        self.stats_client = None  # Client séparé pour écouter les topics système
        self.connected = False
        self.stats_connected = False
        
        # Configuration
        self.mqtt_config = self.config['mqtt']['broker']
        self.update_interval = self.config['collector']['update_intervals']['default']
        
        # Configuration retry depuis l'environnement
        self.retry_enabled = os.environ.get('MQTT_RETRY_ENABLED', 'true').lower() == 'true'
        self.retry_delay = int(os.environ.get('MQTT_RETRY_DELAY', '10'))
        self.max_retries = int(os.environ.get('MQTT_MAX_RETRIES', '0'))  # 0 = infini
        
        # Compteur de tentatives
        self.connection_attempts = 0
        
        # Structure de données MQTT - état actuel
        self.mqttData = {
            'received': 0,
            'sent': 0,
            'clients_connected': 0,
            'uptime_seconds': 0,
            'uptime': { 'days': 0, 'hours': 0, 'minutes': 0, 'seconds': 0 },
            'latency': 0,
            'status': 'error',
            'topics': [],
            'lastActivityTimestamp': time.time(),
            'connected': False,
            'broker_version': 'N/A',
            'broker_load': {}
        }
        
        # Topics actifs (hors système)
        self.active_topics = set()
        self.topic_last_seen = {}
        
        # Cache des valeurs système
        self.sys_values = {}
        
        # Statistiques internes
        self.stats = {
            'messages_sent': 0,
            'errors': 0,
            'start_time': time.time(),
            'connection_failures': 0
        }
        
        logger.info(f"Collecteur MQTT Stats initialisé - Version {self.config['widget']['version']}")
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
                
                # 1. Client principal pour publier les stats
                self.mqtt_client = mqtt.Client(client_id="mqttstats-publisher")
                self.mqtt_client.on_connect = lambda c,u,f,rc: self._on_connect(c, u, f, rc, "publisher")
                self.mqtt_client.on_disconnect = lambda c,u,rc: self._on_disconnect(c, u, rc, "publisher")
                self.mqtt_client.username_pw_set(
                    self.mqtt_config['username'],
                    self.mqtt_config['password']
                )
                self.mqtt_client.connect(
                    self.mqtt_config['host'], 
                    self.mqtt_config['port'], 
                    60
                )
                self.mqtt_client.loop_start()
                
                # 2. Client pour écouter les topics système et utilisateur
                self.stats_client = mqtt.Client(client_id="mqttstats-listener")
                self.stats_client.on_connect = lambda c,u,f,rc: self._on_connect(c, u, f, rc, "listener")
                self.stats_client.on_disconnect = lambda c,u,rc: self._on_disconnect(c, u, rc, "listener")
                self.stats_client.on_message = self._on_message
                self.stats_client.username_pw_set(
                    self.mqtt_config['username'],
                    self.mqtt_config['password']
                )
                self.stats_client.connect(
                    self.mqtt_config['host'], 
                    self.mqtt_config['port'], 
                    60
                )
                self.stats_client.loop_start()
                
                # Attendre les connexions
                timeout = 30
                while (not self.connected or not self.stats_connected) and timeout > 0:
                    time.sleep(0.5)
                    timeout -= 0.5
                
                if self.connected and self.stats_connected:
                    logger.info("Connexions MQTT établies avec succès")
                    self.stats['connection_failures'] = 0
                    return True
                else:
                    raise Exception("Timeout de connexion")
                
            except Exception as e:
                self.stats['connection_failures'] += 1
                logger.error(f"Erreur connexion MQTT: {e}")
                
                # Nettoyer les clients
                for client in [self.mqtt_client, self.stats_client]:
                    if client:
                        try:
                            client.loop_stop()
                            client.disconnect()
                        except:
                            pass
                
                if not self.retry_enabled:
                    return False
                
                # Attendre avant de réessayer
                logger.info(f"Nouvelle tentative dans {self.retry_delay} secondes...")
                time.sleep(self.retry_delay)
    
    def _on_connect(self, client, userdata, flags, rc, client_type):
        """Callback de connexion"""
        if rc == 0:
            logger.info(f"Client {client_type} connecté au broker MQTT")
            
            if client_type == "publisher":
                self.connected = True
                self.mqttData['connected'] = True
                self.mqttData['status'] = 'ok'
            else:
                self.stats_connected = True
                # S'abonner aux topics système
                client.subscribe("$SYS/#")
                # S'abonner à tous les topics utilisateur pour les compter
                client.subscribe("#")
                logger.info("Abonné aux topics système ($SYS/#) et utilisateur (#)")
        else:
            logger.error(f"Échec connexion MQTT {client_type}, code: {rc}")
    
    def _on_disconnect(self, client, userdata, rc, client_type):
        """Callback de déconnexion"""
        logger.warning(f"Client {client_type} déconnecté du broker MQTT (code: {rc})")
        
        if client_type == "publisher":
            self.connected = False
            self.mqttData['connected'] = False
            self.mqttData['status'] = 'error'
        else:
            self.stats_connected = False
        
        self.stats['connection_failures'] += 1
    
    def _on_message(self, client, userdata, msg):
        """Callback de réception de message"""
        try:
            topic = msg.topic
            payload = msg.payload.decode('utf-8')
            
            # Traiter les topics système
            if topic.startswith("$SYS/"):
                self._process_sys_topic(topic, payload)
            else:
                # Topics utilisateur - les ajouter à la liste des topics actifs
                if not topic.startswith("rpi/network/mqtt/"):  # Éviter nos propres topics
                    self.active_topics.add(topic)
                    self.topic_last_seen[topic] = time.time()
                    
                    # Garder seulement les 15 derniers topics
                    if len(self.active_topics) > 15:
                        # Supprimer le plus ancien
                        oldest_topic = min(self.topic_last_seen, key=self.topic_last_seen.get)
                        self.active_topics.discard(oldest_topic)
                        del self.topic_last_seen[oldest_topic]
            
        except Exception as e:
            logger.error(f"Erreur traitement message: {e}")
    
    def _process_sys_topic(self, topic, payload):
        """Traite les topics système"""
        try:
            # Stocker la valeur
            self.sys_values[topic] = payload
            
            # Traiter selon le topic
            if topic == "$SYS/broker/clients/connected":
                self.mqttData['clients_connected'] = int(payload)
                
            elif topic == "$SYS/broker/messages/received":
                self.mqttData['received'] = int(payload)
                
            elif topic == "$SYS/broker/messages/sent":
                self.mqttData['sent'] = int(payload)
                
            elif topic == "$SYS/broker/uptime":
                # Format: "X seconds"
                match = re.match(r'(\d+)\s*seconds?', payload)
                if match:
                    self.mqttData['uptime_seconds'] = int(match.group(1))
                    self._calculate_uptime()
                    
            elif topic == "$SYS/broker/version":
                self.mqttData['broker_version'] = payload
                
            elif topic.startswith("$SYS/broker/load/"):
                # Charge du broker (messages/seconde)
                load_type = topic.split('/')[-1]
                try:
                    self.mqttData['broker_load'][load_type] = float(payload)
                except:
                    pass
                    
        except Exception as e:
            logger.debug(f"Erreur traitement topic système {topic}: {e}")
    
    def _calculate_uptime(self):
        """Calcule l'uptime en jours/heures/minutes/secondes"""
        seconds = self.mqttData['uptime_seconds']
        
        days = seconds // 86400
        hours = (seconds % 86400) // 3600
        minutes = (seconds % 3600) // 60
        secs = seconds % 60
        
        self.mqttData['uptime'] = {
            'days': days,
            'hours': hours,
            'minutes': minutes,
            'seconds': secs
        }
    
    def calculate_latency(self):
        """Calcule la latence en faisant un ping MQTT"""
        if not self.connected:
            return
        
        try:
            start_time = time.time()
            # Publier un message de test
            result = self.mqtt_client.publish(
                "test/latency/ping",
                json.dumps({"timestamp": start_time}),
                qos=1
            )
            
            if result.rc == 0:
                # Estimation simple : temps de publication
                latency_ms = int((time.time() - start_time) * 1000)
                self.mqttData['latency'] = min(latency_ms, 999)  # Cap à 999ms
            
        except Exception as e:
            logger.debug(f"Erreur calcul latence: {e}")
    
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
    
    def collect_and_publish(self):
        """Collecte et publie les données"""
        try:
            # Calculer la latence
            self.calculate_latency()
            
            # Mettre à jour le timestamp d'activité
            self.mqttData['lastActivityTimestamp'] = time.time()
            
            # Préparer la liste des topics actifs
            topics_list = sorted(list(self.active_topics))[:15]  # Max 15 topics
            
            # Publier les statistiques principales
            self.publish_data("rpi/network/mqtt/stats", {
                "messages_received": self.mqttData['received'],
                "messages_sent": self.mqttData['sent'],
                "clients_connected": self.mqttData['clients_connected'],
                "uptime_seconds": self.mqttData['uptime_seconds'],
                "uptime": self.mqttData['uptime'],
                "latency_ms": self.mqttData['latency'],
                "broker_version": self.mqttData['broker_version'],
                "status": self.mqttData['status']
            })
            
            # Publier la liste des topics actifs
            self.publish_data("rpi/network/mqtt/topics", {
                "topics": topics_list,
                "count": len(topics_list)
            })
            
            # Log pour debug
            logger.info(
                f"Stats publiées - Reçus: {self.mqttData['received']}, "
                f"Envoyés: {self.mqttData['sent']}, "
                f"Clients: {self.mqttData['clients_connected']}, "
                f"Topics actifs: {len(topics_list)}"
            )
            
        except Exception as e:
            logger.error(f"Erreur collecte/publication: {e}")
            self.stats['errors'] += 1
    
    def log_statistics(self):
        """Affiche les statistiques"""
        runtime = time.time() - self.stats['start_time']
        hours = int(runtime // 3600)
        minutes = int((runtime % 3600) // 60)
        
        logger.info(
            f"Stats internes - Runtime: {hours}h {minutes}m | "
            f"Messages publiés: {self.stats['messages_sent']} | "
            f"Erreurs: {self.stats['errors']} | "
            f"Échecs connexion: {self.stats['connection_failures']}"
        )
    
    def run(self):
        """Boucle principale avec gestion d'erreurs robuste"""
        logger.info("Démarrage du collecteur MQTT Stats")
        
        # Attendre un peu au démarrage pour laisser le système se stabiliser
        startup_delay = int(os.environ.get('STARTUP_DELAY', '10'))
        if startup_delay > 0:
            logger.info(f"Pause de {startup_delay}s au démarrage...")
            time.sleep(startup_delay)
        
        # Se connecter au broker MQTT avec retry
        if not self.connect_mqtt():
            logger.error("Impossible de se connecter au broker MQTT après toutes les tentatives")
            return
        
        logger.info("Collecteur opérationnel - Lecture des topics système $SYS")
        
        # Attendre un peu pour recevoir les premières valeurs système
        logger.info("Attente des premières statistiques système...")
        time.sleep(5)
        
        # Compteur pour les statistiques
        stats_counter = 0
        error_count = 0
        
        try:
            while True:
                try:
                    # Vérifier les connexions MQTT
                    if not self.connected or not self.stats_connected:
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
            # Nettoyer
            for client in [self.mqtt_client, self.stats_client]:
                if client:
                    client.loop_stop()
                    client.disconnect()
            
            self.log_statistics()
            logger.info("Collecteur arrêté")

if __name__ == "__main__":
    # Configuration
    config_file = os.environ.get('CONFIG_FILE')
    
    if not config_file and len(sys.argv) > 1:
        config_file = sys.argv[1]
    
    if not config_file:
        widget_dir = os.path.dirname(os.path.abspath(__file__))
        config_file = os.path.join(widget_dir, "mqttstats_widget.json")
    
    if not os.path.exists(config_file):
        logger.error(f"Fichier de configuration non trouvé: {config_file}")
        sys.exit(1)
    
    # Lancer le collecteur
    collector = MQTTStatsCollector(config_file)
    collector.run()