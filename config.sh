#!/bin/bash

# Détecter le répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Vérifier si l'utilisateur a des privilèges sudo
if [ "$EUID" -ne 0 ]; then
    echo "========================================================================"
    echo "  MaxLink™ Admin Panel - Erreur"
    echo "========================================================================"
    echo ""
    echo "◦ Ce script doit être exécuté avec des privilèges sudo."
    echo ""
    echo "  Usage: sudo bash $0"
    echo ""
    echo "========================================================================"
    exit 1
fi

# Header d'accueil
clear
echo "========================================================================"
echo "  MaxLink™ Admin Panel - Initialisation"
echo "  © 2025 WERIT. Tous droits réservés."
echo "========================================================================"
echo ""

# ÉTAPE 1 : CONFIGURATION DE LA SESSION
echo "ÉTAPE 1 : CONFIGURATION DE LA SESSION"
echo "------------------------------------------------------------------------"
echo ""

echo "◦ Configuration des privilèges root..."

# Exporter les variables d'environnement
export MAXLINK_ROOT_MODE=1
export MAXLINK_BASE_DIR="$SCRIPT_DIR"
export DISPLAY="${DISPLAY:-:0.0}"

# Créer le fichier de session
cat > "$SCRIPT_DIR/.maxlink_session" << EOF
MAXLINK_ROOT_MODE=1
MAXLINK_BASE_DIR=$SCRIPT_DIR
MAXLINK_SUDO_USER=${SUDO_USER:-$(whoami)}
MAXLINK_ORIGINAL_HOME=${SUDO_USER:+/home/$SUDO_USER}
DISPLAY=${DISPLAY:-:0.0}
PATH=$PATH
EOF

chmod 600 "$SCRIPT_DIR/.maxlink_session"
echo "  ↦ Session root configurée ✓"

echo ""

# ÉTAPE 2 : CRÉATION DE LA STRUCTURE
echo "ÉTAPE 2 : CRÉATION DE LA STRUCTURE DES DOSSIERS"
echo "------------------------------------------------------------------------"
echo ""

echo "◦ Création des répertoires..."

# Créer les répertoires nécessaires
mkdir -p "$SCRIPT_DIR/logs/archived"
mkdir -p "$SCRIPT_DIR/scripts/install"
mkdir -p "$SCRIPT_DIR/scripts/start"
mkdir -p "$SCRIPT_DIR/scripts/test"
mkdir -p "$SCRIPT_DIR/scripts/uninstall"
mkdir -p "$SCRIPT_DIR/scripts/common"
mkdir -p "$SCRIPT_DIR/assets"

echo "  ↦ Structure créée ✓"

# Configuration des permissions
echo ""
echo "◦ Configuration des permissions..."

find "$SCRIPT_DIR/scripts" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
echo "  ↦ Scripts exécutables ✓"

echo ""

# ÉTAPE 3 : INFORMATIONS SYSTÈME
echo "ÉTAPE 3 : VÉRIFICATION DU SYSTÈME"
echo "------------------------------------------------------------------------"
echo ""

echo "◦ Informations système :"
echo "  ↦ OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  ↦ Architecture: $(uname -m)"
echo "  ↦ Python: $(python3 --version 2>/dev/null || echo "Non installé")"
echo "  ↦ Mode privilégié: Actif (UID=$EUID)"

# Vérifier l'interface WiFi
if ip link show wlan0 > /dev/null 2>&1; then
    echo "  ↦ Interface WiFi: wlan0 détectée ✓"
else
    echo "  ↦ Interface WiFi: Non détectée ⚠"
fi

# Vérifier l'espace disque
AVAILABLE_SPACE=$(df -BM / | tail -1 | awk '{print $4}' | sed 's/M//')
echo "  ↦ Espace disponible: ${AVAILABLE_SPACE}M"

echo ""
sleep 2

# ÉTAPE 4 : LANCEMENT DE L'INTERFACE
echo "ÉTAPE 4 : LANCEMENT DE L'INTERFACE"
echo "------------------------------------------------------------------------"
echo ""

echo "◦ Démarrage de MaxLink Admin Panel..."
echo "  ↦ Privilèges root actifs"
echo "  ↦ Logs disponibles dans: $SCRIPT_DIR/logs/"
echo ""

sleep 1

# Vérifier que Python3 est disponible
if ! command -v python3 &> /dev/null; then
    echo "⚠ ERREUR: Python3 n'est pas installé."
    echo "  Veuillez d'abord exécuter le script update_install.sh"
    echo ""
    exit 1
fi

# Vérifier que l'interface existe
if [ ! -f "$SCRIPT_DIR/interface.py" ]; then
    echo "⚠ ERREUR: interface.py non trouvé."
    echo "  Vérifiez l'intégrité des fichiers."
    echo ""
    exit 1
fi

# Lancer l'interface
echo "◦ Lancement..."
echo ""

# Permettre l'affichage si nécessaire
if [ -n "$SUDO_USER" ] && [ -n "$DISPLAY" ]; then
    xhost +local: > /dev/null 2>&1 || true
fi

# Lancer Python avec les privilèges root
python3 "$SCRIPT_DIR/interface.py"

# Message de fin
echo ""
echo "========================================================================"
echo "  MaxLink™ Admin Panel - Session terminée"
echo "========================================================================"