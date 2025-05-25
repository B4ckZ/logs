#!/bin/bash

# ===============================================================================
# MAXLINK - TEST NGINX ET DNS
# ===============================================================================

echo "========================================================================"
echo "TEST NGINX ET DNS - $(date)"
echo "========================================================================"
echo ""

# ===============================================================================
# TEST 1 : SERVICES
# ===============================================================================

echo "TEST 1 : SERVICES"
echo "------------------------------------------------------------------------"

# NetworkManager
if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager : OK"
else
    echo "NetworkManager : ERREUR - Service inactif"
fi

# Nginx
if systemctl is-active --quiet nginx; then
    echo "Nginx : OK"
else
    echo "Nginx : ERREUR - Service inactif"
fi

# Dnsmasq (intégré à NetworkManager)
if pgrep -f "dnsmasq.*NetworkManager" > /dev/null; then
    echo "Dnsmasq : OK (PID: $(pgrep -f 'dnsmasq.*NetworkManager'))"
else
    echo "Dnsmasq : ERREUR - Processus non trouvé"
fi

echo ""

# ===============================================================================
# TEST 2 : CONFIGURATION DNS
# ===============================================================================

echo "TEST 2 : CONFIGURATION DNS"
echo "------------------------------------------------------------------------"

# Fichier de config dnsmasq
if [ -f "/etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf" ]; then
    echo "Fichier config : OK"
    echo ""
    echo "Contenu :"
    cat /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf
    echo ""
    
    # Vérifier l'entrée DNS
    if grep -q "address=/maxlink.dashboard.local/192.168.4.1" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf; then
        echo "Entrée DNS : OK - maxlink.dashboard.local -> 192.168.4.1"
    else
        echo "Entrée DNS : ERREUR - Entrée manquante"
    fi
else
    echo "Fichier config : ERREUR - Fichier manquant"
fi

echo ""

# ===============================================================================
# TEST 3 : RÉSOLUTION DNS LOCALE
# ===============================================================================

echo "TEST 3 : RÉSOLUTION DNS LOCALE (sur le serveur)"
echo "------------------------------------------------------------------------"

# Test avec dig
if command -v dig >/dev/null 2>&1; then
    echo "Test avec dig :"
    dig +short @127.0.0.1 maxlink.dashboard.local
    if dig +short @127.0.0.1 maxlink.dashboard.local | grep -q "192.168.4.1"; then
        echo "Résolution locale : OK"
    else
        echo "Résolution locale : ERREUR"
    fi
else
    echo "dig non installé"
fi

# Test avec nslookup
if command -v nslookup >/dev/null 2>&1; then
    echo ""
    echo "Test avec nslookup :"
    nslookup maxlink.dashboard.local 127.0.0.1 2>&1 | grep -A2 "Name:"
fi

# Test avec getent
echo ""
echo "Test avec getent :"
getent hosts maxlink.dashboard.local || echo "Pas de résolution"

echo ""

# ===============================================================================
# TEST 4 : PORT DNS
# ===============================================================================

echo "TEST 4 : PORT DNS (53)"
echo "------------------------------------------------------------------------"

# Vérifier qui écoute sur le port 53
echo "Processus écoutant sur le port 53 :"
ss -tulpn | grep :53 | grep -v ":::" || netstat -tulpn | grep :53 | grep -v ":::"

echo ""

# ===============================================================================
# TEST 5 : CONFIGURATION NGINX
# ===============================================================================

echo "TEST 5 : CONFIGURATION NGINX"
echo "------------------------------------------------------------------------"

# Vérifier server_name
if grep -q "server_name.*maxlink.dashboard.local" /etc/nginx/sites-available/maxlink-dashboard; then
    echo "Server_name : OK"
    grep "server_name" /etc/nginx/sites-available/maxlink-dashboard
else
    echo "Server_name : ERREUR - maxlink.dashboard.local non configuré"
fi

echo ""

# ===============================================================================
# TEST 6 : TESTS HTTP
# ===============================================================================

echo "TEST 6 : TESTS HTTP"
echo "------------------------------------------------------------------------"

# Test sur IP
if curl -s -o /dev/null -w "%{http_code}" http://192.168.4.1/ | grep -q "200"; then
    echo "HTTP via IP : OK (200)"
else
    echo "HTTP via IP : ERREUR ($(curl -s -o /dev/null -w "%{http_code}" http://192.168.4.1/))"
fi

# Test sur nom de domaine
if curl -s -o /dev/null -w "%{http_code}" http://maxlink.dashboard.local/ | grep -q "200"; then
    echo "HTTP via domaine : OK (200)"
else
    echo "HTTP via domaine : ERREUR ($(curl -s -o /dev/null -w "%{http_code}" http://maxlink.dashboard.local/))"
fi

echo ""

# ===============================================================================
# TEST 7 : CONFIGURATION DHCP
# ===============================================================================

echo "TEST 7 : CONFIGURATION DHCP"
echo "------------------------------------------------------------------------"

# Vérifier si le serveur DNS est annoncé
if grep -q "dhcp-option=option:dns-server,192.168.4.1" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf; then
    echo "Option DNS dans DHCP : OK"
else
    echo "Option DNS dans DHCP : ERREUR - Le serveur DNS n'est pas annoncé aux clients"
fi

echo ""

# ===============================================================================
# DIAGNOSTIC
# ===============================================================================

echo "========================================================================"
echo "DIAGNOSTIC"
echo "========================================================================"
echo ""

# Identifier le problème principal
if ! pgrep -f "dnsmasq.*NetworkManager" > /dev/null; then
    echo "PROBLÈME : Dnsmasq n'est pas lancé par NetworkManager"
    echo ""
    echo "SOLUTION :"
    echo "1. sudo systemctl restart NetworkManager"
    echo "2. Vérifier que le mode AP est actif"
elif ! grep -q "dhcp-option=option:dns-server,192.168.4.1" /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf 2>/dev/null; then
    echo "PROBLÈME : Les clients ne reçoivent pas l'adresse du serveur DNS"
    echo ""
    echo "SOLUTION :"
    echo "1. Ajouter dans /etc/NetworkManager/dnsmasq-shared.d/00-maxlink-ap.conf :"
    echo "   dhcp-option=option:dns-server,192.168.4.1"
    echo "2. sudo systemctl restart NetworkManager"
else
    echo "Configuration serveur : OK"
    echo ""
    echo "Le problème vient probablement du client (ordinateur/smartphone) :"
    echo "- Le client n'utilise pas le DNS fourni par le DHCP"
    echo "- Le client a un cache DNS"
    echo ""
    echo "Sur le client, vérifier :"
    echo "- Les serveurs DNS utilisés"
    echo "- Forcer le DNS à 192.168.4.1"
fi

echo ""
echo "========================================================================"
echo "FIN DU TEST"
echo "========================================================================"