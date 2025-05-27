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
        
        # Configuration du client
        self.client.username_pw_set(
            config['broker']['username'],
            config['broker']['password']
        )
        
        # Callbacks
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
