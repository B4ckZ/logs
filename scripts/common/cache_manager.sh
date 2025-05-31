#!/bin/bash

# ===============================================================================
# MAXLINK - GESTIONNAIRE DE CACHE DE PAQUETS
# Outil pour gérer le cache local des paquets
# ===============================================================================

# Définir le répertoire de base (ajusté pour le nouveau chemin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source des modules (dans le même dossier maintenant)
source "$SCRIPT_DIR/variables.sh"
source "$SCRIPT_DIR/logging.sh"
source "$SCRIPT_DIR/packages.sh"

# ===============================================================================
# FONCTIONS
# ===============================================================================

# Afficher l'aide
show_help() {
    cat << EOF
MaxLink - Gestionnaire de Cache de Paquets

Usage: $0 [COMMANDE]

COMMANDES:
    status      Afficher l'état et les statistiques du cache
    update      Mettre à jour le cache (télécharger les paquets)
    clean       Nettoyer complètement le cache
    list        Lister tous les paquets dans le cache
    verify      Vérifier l'intégrité du cache
    install     Installer un paquet depuis le cache
    help        Afficher cette aide

EXEMPLES:
    $0 status               # Voir l'état du cache
    $0 update               # Télécharger/mettre à jour les paquets
    $0 clean                # Supprimer tout le cache
    $0 list                 # Lister les paquets téléchargés
    $0 install nginx        # Installer nginx depuis le cache

EOF
}

# Vérifier les privilèges root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "⚠ Ce script doit être exécuté avec des privilèges root"
        echo "Usage: sudo $0 $1"
        exit 1
    fi
}

# Afficher le statut du cache
show_status() {
    echo "========================================================================"
    echo "ÉTAT DU CACHE DE PAQUETS MAXLINK"
    echo "========================================================================"
    echo ""
    
    if [ ! -d "$PACKAGE_CACHE_DIR" ]; then
        echo "◦ Cache non initialisé"
        echo "  ↦ Exécutez '$0 update' pour créer le cache"
        return 1
    fi
    
    # Afficher les statistiques
    get_cache_stats
    
    echo ""
    echo "◦ Validité du cache:"
    if is_cache_valid; then
        echo "  ↦ Cache VALIDE ✓"
    else
        echo "  ↦ Cache OBSOLÈTE ou INVALIDE ✗"
        echo "  ↦ Exécutez '$0 update' pour rafraîchir"
    fi
    
    echo ""
}

# Mettre à jour le cache
update_cache() {
    check_root
    
    echo "========================================================================"
    echo "MISE À JOUR DU CACHE DE PAQUETS"
    echo "========================================================================"
    echo ""
    
    # Initialiser le logging
    init_logging "Mise à jour du cache de paquets" "system"
    
    # Vérifier la connexion internet
    echo "◦ Vérification de la connectivité..."
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        echo "  ↦ Pas de connexion Internet ✗"
        echo ""
        echo "Une connexion Internet est nécessaire pour mettre à jour le cache."
        echo "Connectez-vous au WiFi ou vérifiez votre connexion."
        exit 1
    fi
    echo "  ↦ Connectivité OK ✓"
    
    # Initialiser le cache si nécessaire
    echo ""
    echo "◦ Initialisation du cache..."
    if init_package_cache; then
        echo "  ↦ Cache initialisé ✓"
    else
        echo "  ↦ Erreur d'initialisation ✗"
        exit 1
    fi
    
    # Télécharger les paquets
    echo ""
    if download_all_packages; then
        echo ""
        echo "✓ Cache mis à jour avec succès !"
    else
        echo ""
        echo "⚠ Mise à jour partielle du cache"
        echo "Certains paquets n'ont pas pu être téléchargés."
    fi
    
    # Afficher les statistiques finales
    echo ""
    get_cache_stats
}

# Nettoyer le cache
clean_cache() {
    check_root
    
    echo "========================================================================"
    echo "NETTOYAGE DU CACHE DE PAQUETS"
    echo "========================================================================"
    echo ""
    
    # Demander confirmation
    echo "⚠ ATTENTION: Cette action va supprimer tous les paquets téléchargés."
    echo ""
    read -p "Êtes-vous sûr de vouloir continuer ? (o/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Oo]$ ]]; then
        echo ""
        echo "Nettoyage annulé."
        exit 0
    fi
    
    echo ""
    echo "◦ Nettoyage en cours..."
    
    # Nettoyer le cache
    if clean_package_cache; then
        echo ""
        echo "✓ Cache nettoyé avec succès !"
    else
        echo ""
        echo "✗ Erreur lors du nettoyage"
        exit 1
    fi
}

# Lister les paquets dans le cache
list_packages() {
    echo "========================================================================"
    echo "PAQUETS DANS LE CACHE"
    echo "========================================================================"
    echo ""
    
    if [ ! -d "$PACKAGE_CACHE_DIR" ]; then
        echo "◦ Cache non initialisé"
        return 1
    fi
    
    # Compter les paquets
    local deb_count=$(ls -1 "$PACKAGE_CACHE_DIR"/*.deb 2>/dev/null | wc -l)
    
    if [ $deb_count -eq 0 ]; then
        echo "◦ Aucun paquet dans le cache"
        return 0
    fi
    
    echo "◦ $deb_count paquet(s) trouvé(s):"
    echo ""
    
    # Lister avec taille
    ls -lh "$PACKAGE_CACHE_DIR"/*.deb 2>/dev/null | awk '{print "  • " $9 " (" $5 ")"}' | sed "s|$PACKAGE_CACHE_DIR/||g"
    
    echo ""
    
    # Taille totale
    local total_size=$(du -sh "$PACKAGE_CACHE_DIR" 2>/dev/null | cut -f1)
    echo "◦ Taille totale: $total_size"
}

# Vérifier l'intégrité du cache
verify_cache() {
    echo "========================================================================"
    echo "VÉRIFICATION DU CACHE"
    echo "========================================================================"
    echo ""
    
    if [ ! -d "$PACKAGE_CACHE_DIR" ]; then
        echo "◦ Cache non initialisé ✗"
        return 1
    fi
    
    echo "◦ Vérification des métadonnées..."
    if [ -f "$PACKAGE_METADATA_FILE" ]; then
        echo "  ↦ Fichier de métadonnées présent ✓"
        
        # Vérifier le JSON
        if python3 -c "import json; json.load(open('$PACKAGE_METADATA_FILE'))" 2>/dev/null; then
            echo "  ↦ Métadonnées valides ✓"
        else
            echo "  ↦ Métadonnées corrompues ✗"
        fi
    else
        echo "  ↦ Fichier de métadonnées manquant ✗"
    fi
    
    echo ""
    echo "◦ Vérification des paquets..."
    
    # Vérifier chaque paquet .deb
    local total_debs=0
    local valid_debs=0
    
    for deb in "$PACKAGE_CACHE_DIR"/*.deb 2>/dev/null; do
        [ ! -f "$deb" ] && continue
        ((total_debs++))
        
        if dpkg-deb --info "$deb" >/dev/null 2>&1; then
            ((valid_debs++))
        else
            echo "  ↦ Paquet corrompu: $(basename "$deb") ✗"
        fi
    done
    
    echo "  ↦ Paquets valides: $valid_debs/$total_debs"
    
    echo ""
    echo "◦ Vérification de la validité temporelle..."
    if is_cache_valid; then
        echo "  ↦ Cache dans la période de validité ✓"
    else
        echo "  ↦ Cache obsolète (> $CACHE_VALIDITY_DAYS jours) ✗"
    fi
    
    echo ""
    if [ $valid_debs -eq $total_debs ] && [ -f "$PACKAGE_METADATA_FILE" ] && is_cache_valid; then
        echo "✓ Cache intègre et valide !"
    else
        echo "⚠ Le cache nécessite une mise à jour"
        echo "  Exécutez '$0 update' pour corriger"
    fi
}

# Installer un paquet depuis le cache
install_from_cache() {
    check_root
    
    local package_name="$1"
    
    if [ -z "$package_name" ]; then
        echo "Usage: $0 install <nom_du_paquet>"
        exit 1
    fi
    
    echo "========================================================================"
    echo "INSTALLATION DEPUIS LE CACHE"
    echo "========================================================================"
    echo ""
    
    echo "◦ Recherche du paquet '$package_name' dans le cache..."
    
    if install_package_from_cache "$package_name"; then
        echo ""
        echo "✓ Paquet installé avec succès !"
    else
        echo ""
        echo "✗ Échec de l'installation"
        echo ""
        echo "Vérifiez que le paquet existe dans le cache avec:"
        echo "  $0 list"
    fi
}

# ===============================================================================
# PROGRAMME PRINCIPAL
# ===============================================================================

# Déterminer la commande
COMMAND="${1:-help}"

case "$COMMAND" in
    status)
        show_status
        ;;
    update)
        update_cache
        ;;
    clean)
        clean_cache
        ;;
    list)
        list_packages
        ;;
    verify)
        verify_cache
        ;;
    install)
        install_from_cache "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Commande inconnue: $COMMAND"
        echo "Utilisez '$0 help' pour voir les commandes disponibles"
        exit 1
        ;;
esac