#!/bin/bash

# ===============================================================================
# MAXLINK - MODULE HELPER WIFI
# Gestion automatique des connexions WiFi pour installations hybrides
# ===============================================================================

# Vérifier que les variables sont chargées
if [ -z "$BASE_DIR" ]; then
    echo "ERREUR: Ce module doit être sourcé après variables.sh"
    exit 1
fi

# ===============================================================================
# VARIABLES INTERNES
# ===============================================================================

# État de l'AP avant intervention
WIFI_HELPER_AP_WAS_ACTIVE=false
WIFI_HELPER_WIFI_CONNECTED=false

# ===============================================================================
# FONCTIONS PRINCIPALES
# ===============================================================================

# Vérifier si nous avons une connexion internet
check_internet_connection() {
    log_debug "Vérification de la connectivité internet"
    
    # Test simple avec ping
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_debug "Connectivité internet OK"
        return 0
    else
        log_debug "Pas de connectivité internet"
        return 1
    fi
}

# Sauvegarder l'état actuel du réseau
save_network_state() {
    log_info "Sauvegarde de l'état réseau actuel"
    
    # Vérifier si l'AP est active
    if nmcli con show --active | grep -q "$AP_SSID"; then
        WIFI_HELPER_AP_WAS_ACTIVE=true
        log_info "Mode AP actif détecté"
    else
        WIFI_HELPER_AP_WAS_ACTIVE=false
        log_info "Mode AP non actif"
    fi
    
    # Vérifier si déjà connecté au WiFi
    if nmcli con show --active | grep -q "$WIFI_SSID"; then
        WIFI_HELPER_WIFI_CONNECTED=true
        log_info "Déjà connecté au WiFi $WIFI_SSID"
    else
        WIFI_HELPER_WIFI_CONNECTED=false
    fi
}

# Restaurer l'état réseau précédent
restore_network_state() {
    log_info "Restauration de l'état réseau"
    
    # Déconnecter le WiFi si on n'était pas connecté avant
    if [ "$WIFI_HELPER_WIFI_CONNECTED" = false ]; then
        if nmcli con show --active | grep -q "$WIFI_SSID"; then
            log_info "Déconnexion du WiFi $WIFI_SSID"
            nmcli connection down "$WIFI_SSID" >/dev/null 2>&1
            nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
            wait_silently 2
        fi
    fi
    
    # Réactiver l'AP si elle était active
    if [ "$WIFI_HELPER_AP_WAS_ACTIVE" = true ]; then
        log_info "Réactivation du mode AP"
        nmcli con up "$AP_SSID" >/dev/null 2>&1 || {
            log_error "Impossible de réactiver le mode AP"
            # Ne pas bloquer, continuer quand même
        }
        wait_silently 3
    fi
}

# Se connecter automatiquement au WiFi pour télécharger
ensure_internet_connection() {
    log_info "Vérification et établissement de la connexion internet"
    
    # Sauvegarder l'état actuel
    save_network_state
    
    # Si déjà connecté, parfait
    if check_internet_connection; then
        log_success "Connexion internet déjà disponible"
        return 0
    fi
    
    # Sinon, établir la connexion
    echo "◦ Connexion automatique au réseau pour téléchargement..."
    log_info "Connexion automatique requise pour télécharger les paquets"
    
    # Désactiver l'AP si nécessaire
    if [ "$WIFI_HELPER_AP_WAS_ACTIVE" = true ]; then
        echo "  ↦ Désactivation temporaire du mode AP..."
        log_info "Désactivation temporaire de l'AP"
        nmcli con down "$AP_SSID" >/dev/null 2>&1
        wait_silently 2
    fi
    
    # Se connecter au WiFi
    echo "  ↦ Connexion au réseau \"$WIFI_SSID\"..."
    log_info "Tentative de connexion à $WIFI_SSID"
    
    # Supprimer l'ancienne connexion si elle existe
    nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1
    
    # Nouvelle connexion
    if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" >/dev/null 2>&1; then
        echo "  ↦ Connexion établie ✓"
        log_success "Connexion WiFi établie"
        wait_silently 5
        
        # Vérifier la connectivité
        if check_internet_connection; then
            echo "  ↦ Connectivité internet confirmée ✓"
            log_success "Connectivité internet confirmée"
            return 0
        else
            echo "  ↦ Pas de connectivité internet ✗"
            log_error "Connexion WiFi OK mais pas d'internet"
            return 1
        fi
    else
        echo "  ↦ Impossible de se connecter ✗"
        log_error "Échec de la connexion WiFi"
        
        # Restaurer l'état précédent en cas d'échec
        restore_network_state
        return 1
    fi
}

# Télécharger et mettre en cache les paquets manquants
download_missing_packages() {
    local packages="$1"
    
    if [ -z "$packages" ]; then
        log_warn "Aucun paquet à télécharger"
        return 0
    fi
    
    log_info "Téléchargement des paquets: $packages"
    echo "◦ Téléchargement des paquets manquants..."
    
    # S'assurer d'avoir internet
    if ! ensure_internet_connection; then
        echo "  ↦ Impossible d'établir la connexion ✗"
        return 1
    fi
    
    # Mettre à jour les listes si nécessaire
    echo "  ↦ Mise à jour des listes de paquets..."
    if ! apt-get update -qq >/dev/null 2>&1; then
        log_error "Échec de apt-get update"
        restore_network_state
        return 1
    fi
    
    # Installer les paquets
    echo "  ↦ Installation des paquets..."
    if apt-get install -y $packages >/dev/null 2>&1; then
        echo "  ↦ Paquets installés ✓"
        log_success "Paquets installés: $packages"
        
        # Copier dans le cache pour la prochaine fois
        if [ -d "$PACKAGE_CACHE_DIR" ]; then
            echo "  ↦ Mise en cache des paquets pour utilisation future..."
            copy_installed_packages_to_cache "$packages"
        fi
        
        # Restaurer l'état réseau
        restore_network_state
        return 0
    else
        echo "  ↦ Échec de l'installation ✗"
        log_error "Échec de l'installation des paquets"
        restore_network_state
        return 1
    fi
}

# Copier les paquets installés dans le cache
copy_installed_packages_to_cache() {
    local packages="$1"
    
    log_info "Copie des paquets dans le cache"
    
    # Créer le cache si nécessaire
    mkdir -p "$PACKAGE_CACHE_DIR"
    
    local copied=0
    for pkg in $packages; do
        # Trouver le fichier .deb dans le cache apt
        local deb_file=$(find /var/cache/apt/archives -name "${pkg}_*.deb" 2>/dev/null | head -1)
        
        if [ -f "$deb_file" ]; then
            cp "$deb_file" "$PACKAGE_CACHE_DIR/" 2>/dev/null && {
                ((copied++))
                log_debug "Copié: $(basename "$deb_file")"
            }
        fi
        
        # Copier aussi les dépendances
        local deps=$(apt-cache depends --recurse --no-recommends --no-suggests \
                    --no-conflicts --no-breaks --no-replaces --no-enhances \
                    "$pkg" 2>/dev/null | grep "^\w" | sort -u)
        
        for dep in $deps; do
            local dep_file=$(find /var/cache/apt/archives -name "${dep}_*.deb" 2>/dev/null | head -1)
            if [ -f "$dep_file" ]; then
                cp "$dep_file" "$PACKAGE_CACHE_DIR/" 2>/dev/null && {
                    log_debug "Copié dépendance: $(basename "$dep_file")"
                }
            fi
        done
    done
    
    log_info "$copied paquets copiés dans le cache"
    echo "    • $copied paquets sauvegardés dans le cache"
}

# Fonction helper pour installation hybride
hybrid_package_install() {
    local package_name="$1"
    local package_list="$2"
    
    echo "◦ Installation de $package_name..."
    log_info "Installation hybride de $package_name"
    
    # 1. Vérifier ce qui est déjà installé
    local missing_packages=""
    for pkg in $package_list; do
        if ! dpkg -l "$pkg" >/dev/null 2>&1; then
            missing_packages="$missing_packages $pkg"
        fi
    done
    
    if [ -z "$missing_packages" ]; then
        echo "  ↦ Déjà installé ✓"
        log_info "$package_name déjà installé"
        return 0
    fi
    
    # 2. Essayer depuis le cache local
    echo "  ↦ Recherche dans le cache local..."
    if [ -d "$PACKAGE_CACHE_DIR" ] && [ "$(ls -A $PACKAGE_CACHE_DIR/*.deb 2>/dev/null)" ]; then
        log_info "Tentative d'installation depuis le cache"
        
        local cache_failed=false
        cd "$PACKAGE_CACHE_DIR"
        
        # Essayer d'installer depuis le cache
        for pkg in $missing_packages; do
            if ls ${pkg}_*.deb >/dev/null 2>&1; then
                dpkg -i ${pkg}_*.deb >/dev/null 2>&1 || cache_failed=true
            else
                cache_failed=true
            fi
        done
        
        cd - >/dev/null
        
        # Vérifier ce qui manque encore
        missing_packages=""
        for pkg in $package_list; do
            if ! dpkg -l "$pkg" >/dev/null 2>&1; then
                missing_packages="$missing_packages $pkg"
            fi
        done
        
        if [ -z "$missing_packages" ]; then
            echo "  ↦ Installé depuis le cache ✓"
            log_success "$package_name installé depuis le cache"
            return 0
        else
            echo "  ↦ Installation partielle depuis le cache"
            log_info "Paquets toujours manquants: $missing_packages"
        fi
    fi
    
    # 3. Si il manque encore des paquets, télécharger
    if [ -n "$missing_packages" ]; then
        echo "  ↦ Téléchargement nécessaire pour:$missing_packages"
        if download_missing_packages "$missing_packages"; then
            echo "  ↦ $package_name installé avec succès ✓"
            log_success "$package_name installé complètement"
            return 0
        else
            echo "  ↦ Échec de l'installation ✗"
            log_error "Échec de l'installation de $package_name"
            return 1
        fi
    fi
    
    return 0
}

# ===============================================================================
# EXPORT DES FONCTIONS
# ===============================================================================

export -f check_internet_connection
export -f save_network_state
export -f restore_network_state
export -f ensure_internet_connection
export -f download_missing_packages
export -f copy_installed_packages_to_cache
export -f hybrid_package_install