#!/bin/bash

# Script de réparation rapide pour Mosquitto

echo "========================================================================"
echo "RÉPARATION DE LA CONFIGURATION MOSQUITTO"
echo "========================================================================"
echo ""

# Arrêter le service
echo "◦ Arrêt du service Mosquitto..."
sudo systemctl stop mosquitto
echo "  ↦ Service arrêté ✓"

# Sauvegarder l'ancienne configuration
echo ""
echo "◦ Sauvegarde de l'ancienne configuration..."
sudo cp /etc/mosquitto/mosquitto.conf /etc/mosquitto/mosquitto.conf.broken
echo "  ↦ Sauvegardée dans mosquitto.conf.broken ✓"

# Créer la nouvelle configuration
echo ""
echo "◦ Création de la configuration corrigée..."
sudo tee /etc/mosquitto/mosquitto.conf > /dev/null << 'EOF'
# Configuration Mosquitto pour MaxLink
# Configuration minimale et fonctionnelle

# Persistence
persistence true
persistence_location /var/lib/mosquitto/

# Logging
log_dest file /var/log/mosquitto/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information

# Authentification
allow_anonymous false
password_file /etc/mosquitto/passwords

# Listener MQTT standard
listener 1883
protocol mqtt

# Listener WebSocket
listener 9001
protocol websockets

# Utilisateur système
user mosquitto
EOF

echo "  ↦ Configuration créée ✓"

# Vérifier les permissions
echo ""
echo "◦ Vérification des permissions..."
sudo chown mosquitto:mosquitto /etc/mosquitto/mosquitto.conf
sudo chmod 644 /etc/mosquitto/mosquitto.conf
echo "  ↦ Permissions corrigées ✓"

# Vérifier que les répertoires existent
echo ""
echo "◦ Vérification des répertoires..."
sudo mkdir -p /var/lib/mosquitto /var/log/mosquitto /var/run/mosquitto
sudo chown -R mosquitto:mosquitto /var/lib/mosquitto /var/log/mosquitto /var/run/mosquitto
echo "  ↦ Répertoires vérifiés ✓"

# Redémarrer le service
echo ""
echo "◦ Démarrage du service..."
if sudo systemctl start mosquitto; then
    echo "  ↦ Service démarré ✓"
    
    # Attendre un peu
    sleep 2
    
    # Vérifier le statut
    echo ""
    echo "◦ Vérification du statut..."
    if systemctl is-active --quiet mosquitto; then
        echo "  ↦ Mosquitto est actif ✓"
        
        # Test de connexion
        echo ""
        echo "◦ Test de connexion..."
        if mosquitto_pub -h localhost -u maxlink -P mqtt -t "test/repair" -m "Configuration réparée" 2>/dev/null; then
            echo "  ↦ Connexion MQTT fonctionnelle ✓"
        else
            echo "  ↦ Problème de connexion ✗"
        fi
        
        # Vérifier les ports
        echo ""
        echo "◦ Ports en écoute :"
        sudo netstat -tlnp | grep mosquitto
        
    else
        echo "  ↦ Le service n'est pas actif ✗"
        echo ""
        echo "Dernières lignes du journal :"
        sudo journalctl -u mosquitto -n 10 --no-pager
    fi
else
    echo "  ↦ Échec du démarrage ✗"
    echo ""
    echo "Erreur détaillée :"
    sudo journalctl -u mosquitto -n 20 --no-pager
fi

echo ""
echo "========================================================================"
echo "RÉPARATION TERMINÉE"
echo "========================================================================"