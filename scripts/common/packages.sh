#!/bin/bash

# ===============================================================================
# MAXLINK - MODULE DE GESTION DES PAQUETS
# Centralise le téléchargement et l'installation des paquets
# ===============================================================================

# Vérifier que les variables sont chargées
if [ -z "$BASE_DIR" ]; then
    echo "ERREUR: Ce module doit être sourcé après variables.sh"
    exit 1
fi

# ===============================================================================
# CONFIGURATION
# ===============================================================================

# Répertoire de cache des paquets
PACKAGE_CACHE_DIR="/var/cache/maxlink/packages"
PACKAGE_LIST_FILE="$BASE_DIR/scripts/common/packages.list"
PACKAGE_METADATA_FILE="$PACKAGE_CACHE_DIR/metadata.json"

# Durée de validité du cache (7 jours)
CACHE_VALIDITY_DAYS=7
CACHE_VALIDITY_SECONDS=$((CACHE_VALIDITY_DAYS * 86400))

# ===============================================================================
# FONCTIONS PRINCIPALES
# ===============================================================================

# Initialiser le système de cache
init_package_cache() {
    log_info "Initialisation du cache des paquets"
    
    # Créer le répertoire de cache
    if ! mkdir -p "$PACKAGE_CACHE_DIR"; then
        log_error "Impossible de créer $PACKAGE_CACHE_DIR"
        return 1
    fi
    
    # Définir les permissions appropriées
    chmod 755 "$PACKAGE_CACHE_DIR"
    
    log_success "Cache initialisé: $PACKAGE_CACHE_DIR"
    return 0
}

# Vérifier si le cache est valide
is_cache_valid() {
    # Vérifier l'existence du fichier metadata
    if [ ! -f "$PACKAGE_METADATA_FILE" ]; then
        log_info "Pas de métadonnées de cache trouvées"
        return 1
    fi
    
    # Vérifier l'âge du cache
    local cache_timestamp=$(stat -c %Y "$PACKAGE_METADATA_FILE" 2>/dev/null || echo 0)
    local current_timestamp=$(date +%s)
    local cache_age=$((current_timestamp - cache_timestamp))
    
    if [ $cache_age -gt $CACHE_VALIDITY_SECONDS ]; then
        log_info "Cache obsolète (âge: $(($cache_age / 86400)) jours)"
        return 1
    fi
    
    log_info "Cache valide (âge: $(($cache_age / 86400)) jours)"
    return 0
}

# Lire la liste des paquets requis
get_required_packages() {
    if [ ! -f "$PACKAGE_LIST_FILE" ]; then
        log_error "Fichier de liste des paquets non trouvé: $PACKAGE_LIST_FILE"
        return 1
    fi
    
    # Lire et filtrer les commentaires et lignes vides
    grep -v '^#' "$PACKAGE_LIST_FILE" 2>/dev/null | grep -v '^$' || true
}

# Télécharger tous les paquets requis
download_all_packages() {
    log_info "Téléchargement de tous les paquets requis"
    
    # Nettoyer l'ancien cache
    rm -rf "$PACKAGE_CACHE_DIR"/*
    
    # Créer les métadonnées
    cat > "$PACKAGE_METADATA_FILE" << EOF
{
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "version": "$MAXLINK_VERSION",
    "packages": []
}
EOF
    
    # Mettre à jour les listes de paquets
    log_info "Mise à jour des listes de paquets APT"
    if ! apt-get update -qq; then
        log_error "Échec de la mise à jour APT"
        return 1
    fi
    
    # Télécharger chaque paquet
    local packages=$(get_required_packages)
    local total_packages=$(echo "$packages" | wc -l)
    local current_package=0
    local failed_packages=""
    
    echo "$packages" | while IFS= read -r package; do
        [ -z "$package" ] && continue
        
        ((current_package++))
        local progress=$((current_package * 100 / total_packages))
        
        echo "◦ Téléchargement [$current_package/$total_packages]: $package"
        log_info "Téléchargement du paquet: $package"
        
        # Télécharger le paquet et ses dépendances
        if apt-get download -o Dir::Cache::archives="$PACKAGE_CACHE_DIR" \
           $(apt-cache depends --recurse --no-recommends --no-suggests \
           --no-conflicts --no-breaks --no-replaces --no-enhances \
           $package 2>/dev/null | grep "^\w" | sort -u) \
           >/dev/null 2>&1; then
            echo "  ↦ $package téléchargé ✓"
            log_success "Paquet téléchargé: $package"
            
            # Mettre à jour les métadonnées
            python3 -c "
import json
with open('$PACKAGE_METADATA_FILE', 'r') as f:
    data = json.load(f)
data['packages'].append('$package')
with open('$PACKAGE_METADATA_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
        else
            echo "  ↦ $package échec ✗"
            log_error "Échec du téléchargement: $package"
            failed_packages="$failed_packages $package"
        fi
    done
    
    # Résumé
    local downloaded_count=$(ls -1 "$PACKAGE_CACHE_DIR"/*.deb 2>/dev/null | wc -l)
    echo ""
    echo "◦ Téléchargement terminé"
    echo "  ↦ Paquets téléchargés: $downloaded_count"
    log_info "Total paquets téléchargés: $downloaded_count"
    
    if [ -n "$failed_packages" ]; then
        echo "  ↦ Paquets échoués:$failed_packages"
        log_warn "Paquets non téléchargés:$failed_packages"
        return 1
    fi
    
    return 0
}

# Installer un paquet depuis le cache
install_package_from_cache() {
    local package_name="$1"
    
    log_info "Installation du paquet depuis le cache: $package_name"
    
    # Vérifier si le paquet est dans le cache
    local deb_files=$(find "$PACKAGE_CACHE_DIR" -name "${package_name}*.deb" 2>/dev/null)
    
    if [ -z "$deb_files" ]; then
        log_error "Paquet non trouvé dans le cache: $package_name"
        return 1
    fi
    
    # Installer avec dpkg
    if dpkg -i $deb_files >/dev/null 2>&1; then
        log_success "Paquet installé depuis le cache: $package_name"
        return 0
    else
        # Essayer de corriger les dépendances
        log_warn "Tentative de correction des dépendances pour $package_name"
        apt-get install -f -y >/dev/null 2>&1
        return $?
    fi
}

# Installer tous les paquets d'une catégorie
install_packages_by_category() {
    local category="$1"
    
    log_info "Installation des paquets de la catégorie: $category"
    
    # Extraire les paquets de la catégorie
    local packages=$(grep "^$category:" "$PACKAGE_LIST_FILE" 2>/dev/null | cut -d: -f2)
    
    if [ -z "$packages" ]; then
        log_warn "Aucun paquet trouvé pour la catégorie: $category"
        return 0
    fi
    
    # Installer chaque paquet
    for package in $packages; do
        echo "  ↦ Installation de $package..."
        if install_package_from_cache "$package"; then
            echo "    ✓ $package installé"
        else
            echo "    ✗ Échec pour $package"
            log_error "Échec d'installation: $package"
        fi
    done
    
    return 0
}

# Nettoyer le cache
clean_package_cache() {
    log_info "Nettoyage du cache des paquets"
    
    if [ -d "$PACKAGE_CACHE_DIR" ]; then
        local size=$(du -sh "$PACKAGE_CACHE_DIR" 2>/dev/null | cut -f1)
        rm -rf "$PACKAGE_CACHE_DIR"/*
        echo "  ↦ Cache nettoyé ($size libérés)"
        log_success "Cache nettoyé: $size libérés"
    fi
    
    return 0
}

# Obtenir des statistiques sur le cache
get_cache_stats() {
    if [ ! -d "$PACKAGE_CACHE_DIR" ]; then
        echo "Cache non initialisé"
        return 1
    fi
    
    local total_size=$(du -sh "$PACKAGE_CACHE_DIR" 2>/dev/null | cut -f1)
    local deb_count=$(ls -1 "$PACKAGE_CACHE_DIR"/*.deb 2>/dev/null | wc -l)
    local cache_age="N/A"
    
    if [ -f "$PACKAGE_METADATA_FILE" ]; then
        local cache_timestamp=$(stat -c %Y "$PACKAGE_METADATA_FILE")
        local current_timestamp=$(date +%s)
        cache_age="$((($current_timestamp - $cache_timestamp) / 86400)) jours"
    fi
    
    echo "=== Statistiques du cache ==="
    echo "Emplacement : $PACKAGE_CACHE_DIR"
    echo "Taille      : $total_size"
    echo "Paquets     : $deb_count"
    echo "Âge         : $cache_age"
    echo "=========================="
}

# ===============================================================================
# EXPORT DES FONCTIONS
# ===============================================================================

export -f init_package_cache
export -f is_cache_valid
export -f get_required_packages
export -f download_all_packages
export -f install_package_from_cache
export -f install_packages_by_category
export -f clean_package_cache
export -f get_cache_stats