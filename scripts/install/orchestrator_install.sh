#!/bin/bash

# ===============================================================================
# MAXLINK - SYSTÈME D'ORCHESTRATION AVEC SYSTEMD
# Script d'installation de l'orchestrateur pour un démarrage fiable
# ===============================================================================

# Définir le répertoire de base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des modules
source "$BASE_DIR/scripts/common/variables.sh"
source "$BASE_DIR/scripts/common/logging.sh"

# ===============================================================================
# INITIALISATION
# ===============================================================================

# Initialiser le logging
init_logging "Installation de l'orchestrateur MaxLink" "install"

# Vérifier les privilèges root
if [ "$EUID" -ne 0 ]; then
    echo "⚠ Ce script doit être exécuté avec des privilèges root"
    exit 1
fi

echo ""
echo "========================================================================"
echo "INSTALLATION DE L'ORCHESTRATEUR MAXLINK"
echo "========================================================================"
echo ""

# ===============================================================================
# ÉTAPE 1 : CRÉATION DES SCRIPTS DE HEALTHCHECK
# ===============================================================================

echo "◦ Création des scripts de vérification..."
mkdir -p /opt/maxlink/healthchecks

# 1. Script de vérification MQTT
cat > /opt/maxlink/healthchecks/check-mqtt.sh << 'EOF'
#!/bin/bash
# Vérification que Mosquitto est prêt à accepter des connexions

# Configuration depuis l'environnement ou valeurs par défaut
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mqtt}"
MQTT_PORT="${MQTT_PORT:-1883}"
MAX_ATTEMPTS=30
ATTEMPT=0

echo "[MQTT Check] Vérification du broker MQTT..."

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    # Test de connexion
    if mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "test/healthcheck" -m "test" 2>/dev/null; then
        echo "[MQTT Check] ✓ Broker MQTT opérationnel"
        
        # Vérifier aussi les topics système
        if timeout 2 mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t '$SYS/broker/version' -C 1 >/dev/null 2>&1; then
            echo "[MQTT Check] ✓ Topics système accessibles"
        fi
        
        exit 0
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
    echo "[MQTT Check] Tentative $ATTEMPT/$MAX_ATTEMPTS..."
    sleep 2
done

echo "[MQTT Check] ✗ Timeout - Mosquitto non disponible après $MAX_ATTEMPTS tentatives"
exit 1
EOF

# 2. Script de vérification réseau
cat > /opt/maxlink/healthchecks/check-network.sh << 'EOF'
#!/bin/bash
# Vérification que le réseau est complètement initialisé

echo "[Network Check] Vérification du réseau..."

# Attendre que NetworkManager soit complètement prêt
for i in {1..30}; do
    if nmcli general status >/dev/null 2>&1; then
        echo "[Network Check] ✓ NetworkManager opérationnel"
        break
    fi
    echo "[Network Check] Attente NetworkManager... ($i/30)"
    sleep 1
done

# Vérifier l'interface WiFi
if ip link show wlan0 >/dev/null 2>&1; then
    echo "[Network Check] ✓ Interface WiFi disponible"
    
    # Si l'AP est configuré, vérifier qu'il est actif
    if nmcli con show | grep -q "MaxLink-NETWORK"; then
        echo "[Network Check] Configuration AP détectée"
        
        # Attendre que l'AP soit actif si nécessaire
        for i in {1..20}; do
            if nmcli con show --active | grep -q "MaxLink-NETWORK"; then
                echo "[Network Check] ✓ Point d'accès actif"
                break
            fi
            echo "[Network Check] Attente activation AP... ($i/20)"
            sleep 2
        done
    fi
else
    echo "[Network Check] ⚠ Interface WiFi non trouvée"
fi

# Vérifier la résolution DNS locale si dnsmasq est actif
if pgrep -f "dnsmasq.*NetworkManager" >/dev/null; then
    echo "[Network Check] ✓ Service DNS (dnsmasq) actif"
fi

exit 0
EOF

# 3. Script de vérification Nginx
cat > /opt/maxlink/healthchecks/check-nginx.sh << 'EOF'
#!/bin/bash
# Vérification que Nginx est prêt

echo "[Nginx Check] Vérification du serveur web..."

# Vérifier que le service est actif
if ! systemctl is-active --quiet nginx; then
    echo "[Nginx Check] ✗ Service Nginx non actif"
    exit 1
fi

# Vérifier que le port est en écoute
if netstat -tlnp 2>/dev/null | grep -q ":80.*nginx" || ss -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
    echo "[Nginx Check] ✓ Nginx écoute sur le port 80"
else
    echo "[Nginx Check] ✗ Nginx n'écoute pas sur le port 80"
    exit 1
fi

# Test HTTP simple
if curl -s -o /dev/null -w "%{http_code}" http://localhost/ | grep -q "200\|304"; then
    echo "[Nginx Check] ✓ Réponse HTTP correcte"
else
    echo "[Nginx Check] ⚠ Pas de réponse HTTP valide"
fi

exit 0
EOF

# 4. Script de vérification globale
cat > /opt/maxlink/healthchecks/check-system.sh << 'EOF'
#!/bin/bash
# Vérification globale du système MaxLink

echo ""
echo "========================================================================"
echo "VÉRIFICATION DU SYSTÈME MAXLINK"
echo "========================================================================"
echo ""
echo "Date: $(date)"
echo ""

# Vérifier tous les composants
ERRORS=0

# 1. Réseau
echo "▶ Vérification réseau..."
if /opt/maxlink/healthchecks/check-network.sh; then
    echo "  └─ Réseau: OK ✓"
else
    echo "  └─ Réseau: ERREUR ✗"
    ((ERRORS++))
fi
echo ""

# 2. MQTT
echo "▶ Vérification MQTT..."
if /opt/maxlink/healthchecks/check-mqtt.sh; then
    echo "  └─ MQTT: OK ✓"
else
    echo "  └─ MQTT: ERREUR ✗"
    ((ERRORS++))
fi
echo ""

# 3. Nginx
echo "▶ Vérification Nginx..."
if /opt/maxlink/healthchecks/check-nginx.sh; then
    echo "  └─ Nginx: OK ✓"
else
    echo "  └─ Nginx: ERREUR ✗"
    ((ERRORS++))
fi
echo ""

# 4. Widgets
echo "▶ Vérification des widgets..."
WIDGET_ERRORS=0
for service in maxlink-widget-*; do
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        if systemctl is-active --quiet "$service"; then
            echo "  ├─ $service: ACTIF ✓"
        else
            echo "  ├─ $service: INACTIF ✗"
            ((WIDGET_ERRORS++))
        fi
    fi
done

if [ $WIDGET_ERRORS -eq 0 ]; then
    echo "  └─ Tous les widgets: OK ✓"
else
    echo "  └─ $WIDGET_ERRORS widget(s) inactif(s) ✗"
    ((ERRORS++))
fi
echo ""

# Résumé
echo "========================================================================"
if [ $ERRORS -eq 0 ]; then
    echo "RÉSULTAT: Système MaxLink opérationnel ✓"
else
    echo "RÉSULTAT: $ERRORS erreur(s) détectée(s) ✗"
fi
echo "========================================================================"
echo ""

exit $ERRORS
EOF

# Rendre les scripts exécutables
chmod +x /opt/maxlink/healthchecks/*.sh
echo "  ↦ Scripts de vérification créés ✓"

# ===============================================================================
# ÉTAPE 2 : CRÉATION DES SERVICES DE HEALTHCHECK
# ===============================================================================

echo ""
echo "◦ Création des services de vérification..."

# 1. Service de vérification réseau au démarrage
cat > /etc/systemd/system/maxlink-network-ready.service << EOF
[Unit]
Description=MaxLink Network Readiness Check
After=NetworkManager.service
Wants=NetworkManager-wait-online.service
Before=maxlink-network.target

[Service]
Type=oneshot
ExecStart=/opt/maxlink/healthchecks/check-network.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=maxlink-network.target
EOF

# 2. Service de vérification MQTT
cat > /etc/systemd/system/maxlink-mqtt-ready.service << EOF
[Unit]
Description=MaxLink MQTT Readiness Check
After=mosquitto.service
Requires=mosquitto.service
Before=maxlink-core.target

[Service]
Type=oneshot
ExecStart=/opt/maxlink/healthchecks/check-mqtt.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
StartLimitInterval=60
StartLimitBurst=5
StandardOutput=journal
StandardError=journal
Environment="MQTT_USER=${MQTT_USER}"
Environment="MQTT_PASS=${MQTT_PASS}"
Environment="MQTT_PORT=${MQTT_PORT}"

[Install]
WantedBy=maxlink-core.target
EOF

# 3. Service de vérification système (pour monitoring)
cat > /etc/systemd/system/maxlink-health-monitor.service << EOF
[Unit]
Description=MaxLink System Health Monitor
After=maxlink-widgets.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /opt/maxlink/healthchecks/check-system.sh; sleep 300; done'
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "  ↦ Services de vérification créés ✓"

# ===============================================================================
# ÉTAPE 3 : CRÉATION DES TARGETS SYSTEMD
# ===============================================================================

echo ""
echo "◦ Création des targets d'orchestration..."

# 1. Target réseau MaxLink
cat > /etc/systemd/system/maxlink-network.target << EOF
[Unit]
Description=MaxLink Network Services
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target NetworkManager-wait-online.service maxlink-network-ready.service

[Install]
WantedBy=multi-user.target
EOF

# 2. Target core MaxLink (MQTT + Nginx)
cat > /etc/systemd/system/maxlink-core.target << EOF
[Unit]
Description=MaxLink Core Services
After=maxlink-network.target mosquitto.service
Wants=maxlink-network.target mosquitto.service maxlink-mqtt-ready.service

[Install]
WantedBy=multi-user.target
EOF

# 3. Target widgets MaxLink
cat > /etc/systemd/system/maxlink-widgets.target << EOF
[Unit]
Description=MaxLink Widget Services
After=maxlink-core.target maxlink-mqtt-ready.service
Wants=maxlink-core.target

[Install]
WantedBy=multi-user.target
EOF

echo "  ↦ Targets d'orchestration créés ✓"

# ===============================================================================
# ÉTAPE 4 : MODIFICATION DES SERVICES EXISTANTS
# ===============================================================================

echo ""
echo "◦ Mise à jour des services existants..."

# 1. Modifier Mosquitto pour utiliser le nouveau système
mkdir -p /etc/systemd/system/mosquitto.service.d/
cat > /etc/systemd/system/mosquitto.service.d/maxlink-orchestration.conf << EOF
[Unit]
# Intégration dans l'orchestration MaxLink
After=maxlink-network.target
PartOf=maxlink-core.target

[Service]
# Augmenter le timeout de démarrage
TimeoutStartSec=90
# S'assurer que le service redémarre en cas d'échec
Restart=on-failure
RestartSec=10
EOF

# 2. Modifier Nginx
mkdir -p /etc/systemd/system/nginx.service.d/
cat > /etc/systemd/system/nginx.service.d/maxlink-orchestration.conf << EOF
[Unit]
# Dépendances MaxLink
After=maxlink-network.target mosquitto.service
Wants=mosquitto.service
PartOf=maxlink-core.target

[Service]
# Attendre que MQTT soit prêt avant de démarrer
ExecStartPre=/opt/maxlink/healthchecks/check-mqtt.sh
# Timeout généreux
TimeoutStartSec=90
EOF

# 3. Créer un template pour tous les widgets
cat > /etc/systemd/system/maxlink-widget-template@.service << EOF
[Unit]
Description=MaxLink Widget %i
After=maxlink-core.target maxlink-mqtt-ready.service
Wants=maxlink-mqtt-ready.service
PartOf=maxlink-widgets.target

[Service]
Type=simple
# Le widget attend que MQTT soit prêt
ExecStartPre=/opt/maxlink/healthchecks/check-mqtt.sh
ExecStart=/usr/bin/python3 /path/to/widget/%i_collector.py
Restart=always
RestartSec=30
StartLimitInterval=600
StartLimitBurst=5

# Environnement robuste
Environment="PYTHONUNBUFFERED=1"
Environment="MQTT_RETRY_ENABLED=true"
Environment="MQTT_RETRY_DELAY=10"
Environment="MQTT_MAX_RETRIES=0"
Environment="STARTUP_DELAY=5"

[Install]
WantedBy=maxlink-widgets.target
EOF

# 4. Mettre à jour tous les services de widgets existants
for widget_service in /etc/systemd/system/maxlink-widget-*.service; do
    if [ -f "$widget_service" ]; then
        service_name=$(basename "$widget_service" .service)
        mkdir -p "/etc/systemd/system/${service_name}.service.d/"
        
        cat > "/etc/systemd/system/${service_name}.service.d/orchestration.conf" << EOF
[Unit]
# Orchestration MaxLink
After=maxlink-core.target maxlink-mqtt-ready.service
Wants=maxlink-mqtt-ready.service
PartOf=maxlink-widgets.target

[Service]
# Vérification MQTT avant démarrage
ExecStartPre=/opt/maxlink/healthchecks/check-mqtt.sh
# Délai réduit car on vérifie que MQTT est prêt
ExecStartPre=/bin/sleep 5
# Redémarrage plus agressif
Restart=always
RestartSec=20
StartLimitInterval=300
StartLimitBurst=10
EOF
        
        echo "  ↦ Service $service_name mis à jour ✓"
    fi
done

# ===============================================================================
# ÉTAPE 5 : SCRIPT DE GESTION
# ===============================================================================

echo ""
echo "◦ Création du script de gestion..."

cat > /usr/local/bin/maxlink-orchestrator << 'EOF'
#!/bin/bash
# Script de gestion de l'orchestrateur MaxLink

case "$1" in
    status)
        echo "=== État de l'orchestrateur MaxLink ==="
        echo ""
        echo "▶ Targets:"
        systemctl status maxlink-network.target --no-pager --lines=0
        systemctl status maxlink-core.target --no-pager --lines=0
        systemctl status maxlink-widgets.target --no-pager --lines=0
        echo ""
        echo "▶ Services de vérification:"
        systemctl status maxlink-network-ready.service --no-pager --lines=0
        systemctl status maxlink-mqtt-ready.service --no-pager --lines=0
        echo ""
        echo "▶ Services core:"
        systemctl status mosquitto --no-pager --lines=0
        systemctl status nginx --no-pager --lines=0
        echo ""
        echo "▶ Widgets:"
        systemctl status 'maxlink-widget-*' --no-pager --lines=0
        ;;
        
    check)
        /opt/maxlink/healthchecks/check-system.sh
        ;;
        
    restart-all)
        echo "Redémarrage de tous les services MaxLink..."
        systemctl restart maxlink-network.target
        sleep 2
        systemctl restart maxlink-core.target
        sleep 5
        systemctl restart maxlink-widgets.target
        echo "Redémarrage terminé."
        ;;
        
    restart-widgets)
        echo "Redémarrage des widgets uniquement..."
        systemctl restart maxlink-widgets.target
        echo "Widgets redémarrés."
        ;;
        
    logs)
        case "$2" in
            mqtt)
                journalctl -u mosquitto -u maxlink-mqtt-ready -f
                ;;
            widgets)
                journalctl -u 'maxlink-widget-*' -f
                ;;
            network)
                journalctl -u NetworkManager -u maxlink-network-ready -f
                ;;
            all)
                journalctl -u mosquitto -u nginx -u 'maxlink-*' -f
                ;;
            *)
                echo "Usage: $0 logs {mqtt|widgets|network|all}"
                ;;
        esac
        ;;
        
    enable)
        echo "Activation de l'orchestrateur..."
        systemctl daemon-reload
        systemctl enable maxlink-network.target
        systemctl enable maxlink-core.target
        systemctl enable maxlink-widgets.target
        systemctl enable maxlink-network-ready.service
        systemctl enable maxlink-mqtt-ready.service
        systemctl enable maxlink-health-monitor.service
        echo "Orchestrateur activé."
        ;;
        
    disable)
        echo "Désactivation de l'orchestrateur..."
        systemctl disable maxlink-health-monitor.service
        systemctl disable maxlink-mqtt-ready.service
        systemctl disable maxlink-network-ready.service
        systemctl disable maxlink-widgets.target
        systemctl disable maxlink-core.target
        systemctl disable maxlink-network.target
        echo "Orchestrateur désactivé."
        ;;
        
    *)
        echo "MaxLink Orchestrator Control"
        echo ""
        echo "Usage: $0 {status|check|restart-all|restart-widgets|logs|enable|disable}"
        echo ""
        echo "  status          - Afficher l'état de tous les services"
        echo "  check           - Vérifier la santé du système"
        echo "  restart-all     - Redémarrer tous les services dans l'ordre"
        echo "  restart-widgets - Redémarrer uniquement les widgets"
        echo "  logs [service]  - Afficher les logs (mqtt|widgets|network|all)"
        echo "  enable          - Activer l'orchestrateur au démarrage"
        echo "  disable         - Désactiver l'orchestrateur"
        echo ""
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/maxlink-orchestrator
echo "  ↦ Script de gestion créé ✓"

# ===============================================================================
# ÉTAPE 6 : ACTIVATION ET TEST
# ===============================================================================

echo ""
echo "◦ Activation de l'orchestrateur..."

# Recharger systemd
systemctl daemon-reload

# Activer les nouveaux services et targets
systemctl enable maxlink-network.target
systemctl enable maxlink-core.target
systemctl enable maxlink-widgets.target
systemctl enable maxlink-network-ready.service
systemctl enable maxlink-mqtt-ready.service

echo "  ↦ Orchestrateur activé ✓"

# ===============================================================================
# RÉSUMÉ
# ===============================================================================

echo ""
echo "========================================================================"
echo "INSTALLATION TERMINÉE"
echo "========================================================================"
echo ""
echo "L'orchestrateur MaxLink est maintenant installé et actif."
echo ""
echo "▶ Architecture de démarrage :"
echo "  1. network.target → NetworkManager"
echo "  2. maxlink-network.target → Vérification réseau"
echo "  3. mosquitto.service → Démarrage MQTT"
echo "  4. maxlink-mqtt-ready → Vérification MQTT"
echo "  5. maxlink-core.target → Services core (Nginx)"
echo "  6. maxlink-widgets.target → Tous les widgets"
echo ""
echo "▶ Commandes utiles :"
echo "  • maxlink-orchestrator status    - État du système"
echo "  • maxlink-orchestrator check     - Vérification complète"
echo "  • maxlink-orchestrator logs all  - Voir tous les logs"
echo ""
echo "▶ Prochaine étape :"
echo "  Redémarrer le système pour tester l'orchestration complète"
echo ""

log_success "Orchestrateur MaxLink installé avec succès"

# Proposer un test immédiat
echo "Voulez-vous tester l'orchestrateur maintenant ? (o/N)"
read -r response
if [[ "$response" =~ ^[Oo]$ ]]; then
    echo ""
    echo "Test de l'orchestrateur..."
    /usr/local/bin/maxlink-orchestrator check
fi