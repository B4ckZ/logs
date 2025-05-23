#!/bin/bash

# Détecter le répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Vérifier si l'utilisateur a des privilèges sudo
if [ "$EUID" -ne 0 ]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "  MaxLink™ Admin Panel V2.0 - Configuration"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    echo "◦ ERREUR: Ce script doit être exécuté avec des privilèges sudo."
    echo ""
    echo "Usage correct:"
    echo "  sudo bash $0"
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi

# Header d'accueil
clear
echo "════════════════════════════════════════════════════════════════"
echo "  MaxLink™ Admin Panel V2.0 - Initialisation"
echo "  © 2025 WERIT. Tous droits réservés."
echo "════════════════════════════════════════════════════════════════"
echo ""

# NOUVEAU : Préserver les privilèges root pour l'interface Python
echo "◦ Configuration des privilèges permanents..."

# Exporter les variables d'environnement pour maintenir les privilèges
export MAXLINK_ROOT_MODE=1
export MAXLINK_BASE_DIR="$SCRIPT_DIR"
export DISPLAY="${DISPLAY:-:0.0}"

# Créer un fichier de session root pour l'interface Python
cat > "$SCRIPT_DIR/.maxlink_session" << EOF
MAXLINK_ROOT_MODE=1
MAXLINK_BASE_DIR=$SCRIPT_DIR
MAXLINK_SUDO_USER=${SUDO_USER:-$(whoami)}
MAXLINK_ORIGINAL_HOME=${SUDO_USER:+/home/$SUDO_USER}
DISPLAY=${DISPLAY:-:0.0}
PATH=$PATH
EOF

chmod 600 "$SCRIPT_DIR/.maxlink_session"
echo "  ➡ Session root configurée"

# Vérifier et créer les assets manquants
echo "• Vérification des assets..."
if [ ! -f "$SCRIPT_DIR/assets/bg.jpg" ]; then
    echo "  ⦿ Image de fond manquante, création en cours..."
    mkdir -p "$SCRIPT_DIR/assets"
    
    # Créer une image par défaut simple
    if command -v convert >/dev/null 2>&1; then
        convert -size 1920x1080 gradient:"#2E3440"-"#3B4252" \
                -gravity center -pointsize 72 -fill "#81A1C1" \
                -annotate +0+0 "MaxLink™" "$SCRIPT_DIR/assets/bg.jpg"
        echo "  ➡ Image de fond créée avec ImageMagick"
    else
        # Créer un fichier placeholder de 1KB
        head -c 1024 /dev/zero > "$SCRIPT_DIR/assets/bg.jpg"
        echo "  ➡ Image placeholder créée (remplacez par votre image)"
    fi
else
    echo "  ➡ Image de fond détectée"
fi

# Créer le répertoire de logs avec permissions appropriées
echo "• Création des répertoires nécessaires..."
mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/logs/archived"
chmod 755 "$SCRIPT_DIR/logs"
chmod 755 "$SCRIPT_DIR/logs/archived"

# Créer les répertoires de scripts s'ils n'existent pas
mkdir -p "$SCRIPT_DIR/scripts/install"
mkdir -p "$SCRIPT_DIR/scripts/start"
mkdir -p "$SCRIPT_DIR/scripts/test"
mkdir -p "$SCRIPT_DIR/scripts/uninstall"
mkdir -p "$SCRIPT_DIR/scripts/common"

echo "  ➡ Structure des dossiers créée"

# Libération des verrous APT avant de continuer
echo "• Libération des verrous APT..."
rm -f /var/lib/apt/lists/lock 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true
rm -f /var/lib/dpkg/lock* 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
echo "  ➡ Verrous APT libérés"

# Rendre TOUS les scripts exécutables avec permissions root
echo "• Configuration des permissions complètes..."
find "$SCRIPT_DIR/scripts" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || echo "  ⦿ Aucun script trouvé (normal lors de la première installation)"

# NOUVEAU : Donner des permissions étendues aux scripts
find "$SCRIPT_DIR/scripts" -name "*.sh" -type f -exec chown root:root {} \; 2>/dev/null || true
find "$SCRIPT_DIR" -name "*.py" -type f -exec chown root:root {} \; 2>/dev/null || true

echo "  ➡ Permissions étendues configurées"

# Vérifier si Python et tkinter sont installés
echo "• Vérification de Python et des dépendances..."

if ! command -v python3 &> /dev/null; then
    echo "  ⦿ Python3 n'est pas installé. Installation en cours..."
    apt-get update > /dev/null 2>&1
    apt-get install -y python3 python3-pip > /dev/null 2>&1
    echo "  ➡ Python3 installé"
else
    echo "  ➡ Python3 détecté"
fi

if ! python3 -c "import tkinter" &> /dev/null; then
    echo "  ⦿ Tkinter n'est pas installé. Installation en cours..."
    apt-get install -y python3-tk > /dev/null 2>&1
    echo "  ➡ Tkinter installé"
else
    echo "  ➡ Tkinter disponible"
fi

# Vérifier que les outils réseau de base sont présents
echo "• Vérification des outils réseau..."

tools_needed=("nmcli" "iw" "ip" "ping")
missing_tools=()

for tool in "${tools_needed[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        missing_tools+=("$tool")
    fi
done

if [ ${#missing_tools[@]} -gt 0 ]; then
    echo "  ⦿ Installation des outils réseau manquants: ${missing_tools[*]}"
    apt-get update > /dev/null 2>&1
    apt-get install -y wireless-tools net-tools iputils-ping network-manager > /dev/null 2>&1
    echo "  ➡ Outils réseau installés"
else
    echo "  ➡ Tous les outils réseau sont disponibles"
fi

# NOUVEAU : Installation d'ImageMagick si manquant (pour créer des images)
if ! command -v convert &> /dev/null; then
    echo "• Installation d'ImageMagick..."
    apt-get install -y imagemagick > /dev/null 2>&1
    echo "  ➡ ImageMagick installé"
fi

# Informations système
echo ""
echo "« Informations système »"
echo "  • OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "  • Kernel: $(uname -r)"
echo "  • Architecture: $(uname -m)"
echo "  • Python: $(python3 --version)"
echo "  • Utilisateur sudo: ${SUDO_USER:-root}"
echo "  • Mode privilégié: ◦ ACTIF"

# Vérifier l'interface WiFi
if ip link show wlan0 > /dev/null 2>&1; then
    echo "  • Interface WiFi: wlan0 ◦ OK"
else
    echo "  • Interface WiFi: ⦿ wlan0 non détectée"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ➼ Lancement de l'interface MaxLink Admin Panel V2.0"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "« Informations importantes »"
echo "  • Interface lancée avec privilèges root complets"
echo "  • Tous les scripts s'exécutent automatiquement sans demande sudo"
echo "  • Logs détaillés générés dans logs/"
echo "  • Snapshots système automatiques"
echo "  • Redémarrages automatiques après chaque opération"
echo ""

# Petit délai pour laisser lire les informations
sleep 3

echo "➼ Démarrage de l'interface avec privilèges complets..."
sleep 1

# MODIFICATION CRITIQUE : Lancer Python directement en root
# L'interface hérite des privilèges root et peut tout faire
if [ -n "$DISPLAY" ]; then
    # Si on a un affichage X11
    if [ -n "$SUDO_USER" ]; then
        # Permettre l'affichage à l'utilisateur sudo
        xhost +local: > /dev/null 2>&1 || true
        # MAIS lancer Python en root pour garder les privilèges
        python3 "$SCRIPT_DIR/interface.py"
    else
        python3 "$SCRIPT_DIR/interface.py"
    fi
else
    # Pas d'affichage X11, essayer quand même
    python3 "$SCRIPT_DIR/interface.py"
fi

# Message de fin
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  MaxLink™ Admin Panel V2.0 - Session terminée"
echo "════════════════════════════════════════════════════════════════"