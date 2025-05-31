#!/usr/bin/env python3
"""
Template de base pour les collecteurs de widgets MaxLink
Version améliorée avec mécanisme de retry robuste pour le démarrage au boot
"""

import os
import sys
import time
import json
import logging
from datetime import datetime
from abc import ABC, abstractmethod

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)

try:
    import paho.mqtt.client as mqtt
except ImportError:
    logging.error("Module paho-mqtt non installé")
    sys.exit(1)

class BaseCollector(ABC):
    """Classe de base pour tous les collecteurs de widgets"""
    
    def __init__(self, config_file, logger_name):
        """Initialise le collecteur avec gestion de retry améliorée"""
        self.logger = logging.getLogger(logger_name)
        self.config = self.load_config(config_file)
        self.mqtt_client = None
        self.connected = False
        
        # Configuration MQTT
        self.mqtt_config = self.config['mqtt']['broker']
        
        # Configuration retry depuis l'environnement
        self.retry_enabled = os.environ.get('MQTT_RETRY_ENABLED', 'true').lower() == 'true'
        self.retry_delay = int(os.environ.get('MQTT_RETRY_DELAY', '10'))
        self.max_retries = int(os.environ.get('MQTT_MAX_RETRIES', '0'))  # 0 = infini
        
        # Compteur de tentatives
        self.connection_attempts = 0
        self.last_connection_attempt = 0
        
        # Statistiques
        self.stats = {
            'messages_sent': 0,
            'errors': 0,
            'start_time': time.time(),
            'connection_failures': 0
        }
        
        self.logger.info(f"Collecteur initialisé - Version {self.config['widget']['version']}")
        self.logger.info(f"Retry: {self.retry_enabled}, Delay: {self.retry_delay}s, Max: {self.max_retries}")
    
    def load_config(self, config_file):
        """Charge la configuration depuis le fichier JSON"""
        try:
            with open(config_file, 'r') as f:
                return json.load(f)
        except Exception as e:
            self.logger.error(f"Erreur chargement config: {e}")
            sys.exit(1)
    
    def connect_mqtt(self):
        """Connexion au broker MQTT avec retry robuste"""
        while True:
            try:
                self.connection_attempts += 1
                self.last_connection_attempt = time.time()
                
                # Vérifier si on a atteint la limite de tentatives
                if self.max_retries > 0 and self.connection_attempts > self.max_retries:
                    self.logger.error(f"Limite de tentatives atteinte ({self.max_retries})")
                    return False
                
                self.logger.info(f"Tentative de connexion MQTT #{self.connection_attempts}")
                
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
                    self.logger.info("Connexion MQTT établie avec succès")
                    self.stats['connection_failures'] = 0
                    return True
                else:
                    raise Exception("Timeout de connexion")
                
            except Exception as e:
                self.stats['connection_failures'] += 1
                self.logger.error(f"Erreur connexion MQTT: {e}")
                
                if self.mqtt_client:
                    try:
                        self.mqtt_client.loop_stop()
                        self.mqtt_client.disconnect()
                    except:
                        pass
                
                if not self.retry_enabled:
                    return False
                
                # Attendre avant de réessayer
                self.logger.info(f"Nouvelle tentative dans {self.retry_delay} secondes...")
                time.sleep(self.retry_delay)
    
    def on_connect(self, client, userdata, flags, rc):
        """Callback de connexion"""
        if rc == 0:
            self.logger.info("Connecté au broker MQTT")
            self.connected = True
            self.on_mqtt_connected()
        else:
            self.logger.error(f"Échec connexion MQTT, code: {rc}")
            self.connected = False
    
    def on_disconnect(self, client, userdata, rc):
        """Callback de déconnexion"""
        self.logger.warning(f"Déconnecté du broker MQTT (code: {rc})")
        self.connected = False
        
        # Tentative de reconnexion automatique
        if self.retry_enabled and rc != 0:
            self.logger.info("Reconnexion automatique activée")
            # Le client Paho gère la reconnexion automatiquement
    
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
            
            result = self.mqtt_client.publish(topic, json.dumps(payload), qos=1)
            
            if result.rc == 0:
                self.stats['messages_sent'] += 1
                return True
            else:
                self.stats['errors'] += 1
                return False
                
        except Exception as e:
            self.logger.error(f"Erreur publication: {e}")
            self.stats['errors'] += 1
            return False
    
    def publish_data(self, topic, data):
        """Publie des données complexes sur MQTT"""
        if not self.connected:
            return False
        
        try:
            payload = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                **data
            }
            
            result = self.mqtt_client.publish(topic, json.dumps(payload), qos=1)
            return result.rc == 0
            
        except Exception as e:
            self.logger.error(f"Erreur publication: {e}")
            return False
    
    def log_statistics(self):
        """Affiche les statistiques"""
        runtime = time.time() - self.stats['start_time']
        hours = int(runtime // 3600)
        minutes = int((runtime % 3600) // 60)
        
        self.logger.info(
            f"Stats - Runtime: {hours}h {minutes}m | "
            f"Messages: {self.stats['messages_sent']} | "
            f"Erreurs: {self.stats['errors']} | "
            f"Échecs connexion: {self.stats['connection_failures']}"
        )
    
    def run(self):
        """Boucle principale du collecteur avec gestion d'erreurs robuste"""
        self.logger.info("Démarrage du collecteur")
        
        # Attendre un peu au démarrage pour laisser le système se stabiliser
        startup_delay = int(os.environ.get('STARTUP_DELAY', '5'))
        if startup_delay > 0:
            self.logger.info(f"Pause de {startup_delay}s au démarrage...")
            time.sleep(startup_delay)
        
        # Se connecter au broker MQTT
        if not self.connect_mqtt():
            self.logger.error("Impossible de se connecter au broker MQTT après toutes les tentatives")
            return
        
        self.logger.info("Collecteur opérationnel")
        
        # Initialiser les variables spécifiques au widget
        self.initialize()
        
        # Compteur pour les statistiques
        stats_counter = 0
        
        try:
            while True:
                try:
                    # Vérifier la connexion MQTT
                    if not self.connected:
                        self.logger.warning("Connexion MQTT perdue, tentative de reconnexion...")
                        if not self.connect_mqtt():
                            self.logger.error("Reconnexion échouée, arrêt du collecteur")
                            break
                    
                    # Collecter et publier les données
                    self.collect_and_publish()
                    
                    # Afficher les statistiques toutes les 5 minutes
                    stats_counter += 1
                    if stats_counter >= 300:  # 5 minutes si sleep de 1s
                        self.log_statistics()
                        stats_counter = 0
                    
                    # Pause selon l'intervalle configuré
                    time.sleep(self.get_update_interval())
                    
                except Exception as e:
                    self.logger.error(f"Erreur dans la boucle de collecte: {e}")
                    self.stats['errors'] += 1
                    time.sleep(5)  # Pause en cas d'erreur
                
        except KeyboardInterrupt:
            self.logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            self.logger.error(f"Erreur dans la boucle principale: {e}")
        finally:
            self.cleanup()
            
            if self.mqtt_client:
                self.mqtt_client.loop_stop()
                self.mqtt_client.disconnect()
            
            self.log_statistics()
            self.logger.info("Collecteur arrêté")
    
    @abstractmethod
    def on_mqtt_connected(self):
        """Appelé quand la connexion MQTT est établie (à implémenter)"""
        pass
    
    @abstractmethod
    def initialize(self):
        """Initialise les variables spécifiques au widget (à implémenter)"""
        pass
    
    @abstractmethod
    def collect_and_publish(self):
        """Collecte et publie les données (à implémenter)"""
        pass
    
    @abstractmethod
    def get_update_interval(self):
        """Retourne l'intervalle de mise à jour en secondes (à implémenter)"""
        pass
    
    def cleanup(self):
        """Nettoyage optionnel avant l'arrêt (peut être surchargé)"""
        pass