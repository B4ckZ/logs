#!/bin/bash

# Source du système de logging
source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/common/logging.sh"

# Configuration
AP_SSID="MaxLink-NETWORK"
AP_IP="192.168.4.1"

# Variables de test
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialisation du logging
init_logging "Tests et diagnostics du point d'accès WiFi MaxLink-NETWORK"

# Fonction pour exécuter un test
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    log_debug "Test $TESTS_TOTAL: $test_name"
    echo "Test $TESTS_TOTAL: $test_name"
    
    if eval "$test_command" > /dev/null 2>&1; then
        show_result "✓ RÉUSSI: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_info "Test réussi: $test_name"
        return 0
    else
        show_result "✗ ÉCHEC: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "Test échoué: $test_name"
        return 1
    fi
}

# DÉMARRAGE
section_header "TESTS ET DIAGNOSTICS DU POINT D'ACCÈS MAXLINK"

log_info "Démarrage des tests complets du point d'accès WiFi MaxLink-NETWORK"

# TESTS PRÉLIMINAIRES
section_header "TESTS PRÉLIMINAIRES"

run_test "Privilèges administrateur" "[ \"\$EUID\" -eq 0 ]"
run_test "Installation de NetworkManager" "systemctl list-unit-files | grep -q 'NetworkManager.service'"
run_test "Service NetworkManager actif" "systemctl is-active --quiet NetworkManager"
run_test "Interface WiFi wlan0 présente" "ip link show wlan0"
run_test "Configuration point d'accès existante" "nmcli connection show '$AP_SSID'"

# TESTS DE CONNECTIVITÉ
section_header "TESTS DE CONNECTIVITÉ"

run_test "Point d'accès actif" "nmcli -g NAME connection show --active | grep -q '$AP_SSID'"
run_test "Adresse IP assignée" "ip addr show wlan0 | grep -q 'inet [0-9]'"
run_test "Interface en mode AP" "iw wlan0 info | grep -q 'type AP'"
run_test "Routage IP activé" "[ \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = \"1\" ]"

# TESTS RÉSEAU AVANCÉS
section_header "TESTS RÉSEAU AVANCÉS"

log_info "Analyse détaillée de l'interface wlan0"
if ip addr show wlan0 > /dev/null 2>&1; then
    IP_INFO=$(ip addr show wlan0 | grep -o "inet [0-9.]*/[0-9]*" | head -1)
    if [ -n "$IP_INFO" ]; then
        show_result "✓ Adresse IP: $IP_INFO"
        log_info "Adresse IP détectée: $IP_INFO"
    else
        show_result "✗ Aucune adresse IP configurée"
        log_error "Aucune adresse IP sur wlan0"
    fi
    
    MAC_INFO=$(ip addr show wlan0 | grep -o "link/ether [a-f0-9:]* " | cut -d' ' -f2)
    if [ -n "$MAC_INFO" ]; then
        show_result "✓ Adresse MAC: $MAC_INFO"
        log_info "Adresse MAC: $MAC_INFO"
    else
        show_result "✗ Adresse MAC non trouvée"
        log_error "Adresse MAC non trouvée"
    fi
else
    show_result "✗ Interface wlan0 inaccessible"
    log_error "Interface wlan0 inaccessible"
fi

log_info "Informations détaillées du point d'accès"
if iw wlan0 info > /dev/null 2>&1; then
    CHANNEL=$(iw wlan0 info 2>/dev/null | grep channel | awk '{print $2}' || echo "N/A")
    FREQ=$(iw wlan0 info 2>/dev/null | grep channel | awk '{print $4}' | tr -d '()' || echo "N/A")
    TYPE=$(iw wlan0 info 2>/dev/null | grep type | awk '{print $2}' || echo "N/A")
    
    echo "  • Type: $TYPE"
    echo "  • Canal: $CHANNEL"
    echo "  • Fréquence: $FREQ MHz"
    show_result "Informations récupérées"
    log_info "AP Info - Type: $TYPE, Canal: $CHANNEL, Fréquence: $FREQ MHz"
else
    show_result "⚠ Impossible de récupérer les informations détaillées"
    log_warn "Impossible de récupérer les informations iw"
fi

# TESTS DHCP ET DNS
section_header "TESTS DHCP ET DNS"

log_info "Vérification du serveur DHCP"
if pgrep -f "dnsmasq" > /dev/null 2>&1; then
    DNSMASQ_PID=$(pgrep -f "dnsmasq" | head -1)
    show_result "✓ Serveur DHCP (dnsmasq) actif (PID: $DNSMASQ_PID)"
    log_info "Serveur DHCP actif, PID: $DNSMASQ_PID"
    
    if [ -f /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf ]; then
        DHCP_RANGE=$(cat /etc/NetworkManager/dnsmasq-shared.d/dhcp-range.conf | grep dhcp-range)
        show_result "✓ Configuration DHCP: $DHCP_RANGE"
        log_info "Configuration DHCP: $DHCP_RANGE"
    else
        show_result "⚠ Fichier de configuration DHCP non trouvé"
        log_warn "Fichier de configuration DHCP manquant"
    fi
else
    show_result "⚠ Serveur DHCP (dnsmasq) non détecté"
    log_warn "Serveur DHCP non détecté"
fi

run_test "Test de connectivité locale (ping localhost)" "ping -c 1 127.0.0.1"
run_test "Test de connectivité sur l'interface AP" "ping -c 1 $AP_IP -I wlan0"

# TESTS DE SÉCURITÉ
section_header "TESTS DE SÉCURITÉ"

log_info "Vérification de la configuration de sécurité"
SECURITY_CONFIG=$(nmcli connection show "$AP_SSID" | grep "802-11-wireless-security.key-mgmt" | awk '{print $2}' || echo "none")
if [ "$SECURITY_CONFIG" = "wpa-psk" ]; then
    show_result "✓ Sécurité WPA2-PSK configurée"
    log_info "Sécurité WPA2-PSK configurée"
else
    show_result "⚠ Configuration de sécurité: $SECURITY_CONFIG"
    log_warn "Configuration de sécurité inattendue: $SECURITY_CONFIG"
fi

PASSWORD_SET=$(nmcli connection show "$AP_SSID" | grep "802-11-wireless-security.psk:" | awk '{print $2}' || echo "none")
if [ "$PASSWORD_SET" != "none" ] && [ -n "$PASSWORD_SET" ]; then
    show_result "✓ Mot de passe WPA2 configuré"
    log_info "Mot de passe WPA2 configuré"
else
    show_result "✗ Mot de passe WPA2 non configuré"
    log_error "Mot de passe WPA2 manquant"
fi

# CLIENTS CONNECTÉS
section_header "CLIENTS CONNECTÉS"

log_info "Recherche des clients connectés"
if command -v iw > /dev/null 2>&1; then
    CLIENTS_COUNT=$(iw dev wlan0 station dump 2>/dev/null | grep "Station" | wc -l || echo "0")
    if [ "$CLIENTS_COUNT" -gt 0 ]; then
        show_result "✓ $CLIENTS_COUNT client(s) connecté(s)"
        log_info "$CLIENTS_COUNT clients connectés"
        
        echo "Détails des clients connectés :"
        iw dev wlan0 station dump 2>/dev/null | while read line; do
            if echo "$line" | grep -q "Station"; then
                MAC=$(echo "$line" | awk '{print $2}')
                echo "  • Client MAC: $MAC"
                log_debug "Client connecté: $MAC"
            elif echo "$line" | grep -q "signal:"; then
                SIGNAL=$(echo "$line" | awk '{print $2}')
                echo "    Signal: $SIGNAL dBm"
            elif echo "$line" | grep -q "connected time:"; then
                TIME=$(echo "$line" | cut -d':' -f2- | xargs)
                echo "    Connecté depuis: $TIME"
                echo ""
            fi
        done
        show_result "Détails affichés"
    else
        show_result "ℹ Aucun client actuellement connecté"
        log_info "Aucun client connecté"
    fi
else
    show_result "⚠ Commande 'iw' non disponible pour lister les clients"
    log_warn "Commande iw non disponible"
fi

# TESTS DE PERFORMANCE
section_header "TESTS DE PERFORMANCE"

log_info "Tests de performance système"
if command -v iperf3 > /dev/null 2>&1; then
    show_result "ℹ iperf3 disponible pour tests de performance"
    log_info "iperf3 disponible"
else
    show_result "ℹ iperf3 non installé (optionnel pour tests de performance)"
    log_info "iperf3 non disponible"
fi

CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "N/A")
MEM_USAGE=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}' || echo "N/A")
show_result "CPU: ${CPU_USAGE}% | Mémoire: ${MEM_USAGE}%"
log_info "Performance - CPU: ${CPU_USAGE}%, Mémoire: ${MEM_USAGE}%"

# TESTS DE CONFIGURATION AUTOMATIQUE
section_header "TESTS DE CONFIGURATION AUTOMATIQUE"

run_test "Démarrage automatique configuré" "nmcli -g connection.autoconnect connection show '$AP_SSID' | grep -q 'yes'"
run_test "Service NetworkManager au démarrage" "systemctl is-enabled NetworkManager | grep -q 'enabled'"

# RÉSUMÉ DES TESTS
section_header "RÉSUMÉ DES TESTS"

log_info "Tests terminés - Total: $TESTS_TOTAL, Réussis: $TESTS_PASSED, Échoués: $TESTS_FAILED"

echo "Résultats des tests :"
echo "• Tests exécutés: $TESTS_TOTAL"
echo "• Tests réussis: $TESTS_PASSED"
echo "• Tests échoués: $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo "🎉 TOUS LES TESTS SONT RÉUSSIS !"
    echo "Le point d'accès MaxLink-NETWORK fonctionne parfaitement."
    
    cat << "EOF"
  _______ ______  _____ _______ _____ 
 |__   __|  ____|/ ____|__   __/ ____|
    | |  | |__  | (___    | | | (___  
    | |  |  __|  \___ \   | |  \___ \ 
    | |  | |____ ____) |  | |  ____) |
    |_|  |______|_____/   |_| |_____/ 

EOF
    
    show_result "Point d'accès '$AP_SSID' : État optimal !"
    log_info "Tous les tests réussis - État optimal"
    
elif [ $TESTS_FAILED -le 2 ]; then
    echo ""
    echo "⚠️  TESTS MAJORITAIREMENT RÉUSSIS"
    echo "Le point d'accès fonctionne mais quelques optimisations sont possibles."
    show_result "Point d'accès '$AP_SSID' : État fonctionnel avec avertissements"
    log_warn "Tests majoritairement réussis avec quelques avertissements"
    
else
    echo ""
    echo "❌ PLUSIEURS TESTS ONT ÉCHOUÉ"
    echo "Le point d'accès nécessite une attention particulière."
    show_result "Point d'accès '$AP_SSID' : Problèmes détectés"
    log_error "Plusieurs tests ont échoué"
    
    echo ""
    echo "Actions recommandées :"
    echo "• Vérifiez les logs détaillés"
    echo "• Redémarrez le point d'accès : sudo bash scripts/start/ap_start.sh"
    echo "• En cas de problème persistant, réinstallez : sudo bash scripts/install/ap_install.sh"
fi

log_info "Redémarrage programmé dans 10 secondes"
echo "Le système va redémarrer dans 10 secondes..."
for i in {10..1}; do
    echo -ne "\rRedémarrage dans $i secondes..."
    sleep 1
done
echo ""

log_info "Redémarrage du système"
reboot