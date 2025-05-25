import tkinter as tk
from tkinter import scrolledtext, messagebox
import subprocess
import os
import sys
import threading
from datetime import datetime
import re
import time
import platform

# Détection du système
IS_WINDOWS = platform.system() == "Windows"

# Couleurs du thème Nord
COLORS = {
    "nord0": "#2E3440",  # Fond sombre
    "nord1": "#3B4252",  # Fond moins sombre
    "nord3": "#4C566A",  # Bordure sélection
    "nord4": "#D8DEE9",  # Texte tertiaire
    "nord6": "#ECEFF4",  # Texte
    "nord8": "#88C0D0",  # Accent primaire (bleu clair)
    "nord10": "#5E81AC", # Bouton Installer
    "nord11": "#BF616A", # Rouge / Erreur / Désinstaller
    "nord14": "#A3BE8C", # Vert / Démarrer
    "nord15": "#B48EAD", # Violet / Tester
}

class VariablesManager:
    """Gestionnaire pour charger et utiliser les variables de variables.sh"""
    
    def __init__(self, base_path):
        self.base_path = base_path
        self.variables = {}
        self.load_variables()
    
    def load_variables(self):
        """Charge les variables depuis le fichier variables.sh"""
        variables_file = os.path.join(self.base_path, "scripts", "common", "variables.sh")
        
        if not os.path.exists(variables_file):
            raise FileNotFoundError(f"Fichier variables.sh non trouvé: {variables_file}")
        
        if os.path.getsize(variables_file) == 0:
            raise ValueError("Fichier variables.sh vide")
        
        try:
            # Lire directement le fichier et parser les variables importantes
            with open(variables_file, 'r') as f:
                content = f.read()
            
            # Parser les variables simples
            for line in content.split('\n'):
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    # Ignorer les fonctions et les exports
                    if line.startswith('export') or line.startswith('function') or '()' in line:
                        continue
                    
                    # Parser les variables simples
                    match = re.match(r'^([A-Z_][A-Z0-9_]*)="?([^"]*)"?$', line)
                    if match:
                        key = match.group(1)
                        value = match.group(2)
                        self.variables[key] = value
            
            # Parser SERVICES_LIST spécialement
            services_match = re.search(r'SERVICES_LIST=\((.*?)\)', content, re.DOTALL)
            if services_match:
                services_content = services_match.group(1)
                services = []
                # Extraire chaque service entre guillemets
                for match in re.findall(r'"([^"]+)"', services_content):
                    if ':' in match:
                        services.append(match)
                self.variables['SERVICES_LIST'] = services
            
            # Vérifier que les variables essentielles sont présentes
            required_vars = ['MAXLINK_VERSION', 'SERVICES_LIST']
            missing_vars = []
            
            for var in required_vars:
                if var not in self.variables:
                    missing_vars.append(var)
            
            if missing_vars:
                raise ValueError(f"Variables requises manquantes: {', '.join(missing_vars)}")
            
            # Vérifier que SERVICES_LIST n'est pas vide
            if not self.variables.get('SERVICES_LIST'):
                raise ValueError("SERVICES_LIST est vide")
                
        except Exception as e:
            raise Exception(f"Erreur lors du chargement de variables.sh: {e}")
    
    def get(self, key, default=None):
        """Récupère une variable avec valeur par défaut"""
        return self.variables.get(key, default)
    
    def get_window_title(self):
        """Construit le titre de la fenêtre depuis les variables"""
        version = self.get('MAXLINK_VERSION')
        if not version:
            raise ValueError("MAXLINK_VERSION non définie dans variables.sh")
        copyright_text = self.get('MAXLINK_COPYRIGHT', '© 2025 WERIT. Tous droits réservés.')
        return f"MaxLink™ Admin Panel V{version} - {copyright_text} - Usage non autorisé strictement interdit."
    
    def get_services_list(self):
        """Parse la liste des services depuis SERVICES_LIST"""
        services_raw = self.get('SERVICES_LIST', [])
        services = []
        
        for service_def in services_raw:
            # Format: "id:nom:statut_initial"
            parts = service_def.split(':')
            if len(parts) == 3:
                services.append({
                    "id": parts[0],
                    "name": parts[1], 
                    "status": parts[2]
                })
        
        if not services:
            raise ValueError("Aucun service défini dans SERVICES_LIST")
            
        return services

def validate_configuration():
    """Valide la configuration avant de créer l'interface"""
    base_path = os.path.dirname(os.path.abspath(__file__))
    
    try:
        # Essayer de charger les variables
        variables = VariablesManager(base_path)
        
        # Essayer de récupérer les services
        services = variables.get_services_list()
        
        # Vérifier qu'on a au moins un service
        if not services:
            raise ValueError("Aucun service configuré")
        
        # Si on arrive ici, la configuration est valide
        return True, variables, None
        
    except Exception as e:
        # Retourner l'erreur pour affichage
        return False, None, str(e)

class MaxLinkApp:
    def __init__(self, root, variables):
        self.root = root
        self.variables = variables
        
        # Chemins et initialisation
        self.base_path = os.path.dirname(os.path.abspath(__file__))
        
        # Configuration de la fenêtre avec variables
        try:
            self.root.title(self.variables.get_window_title())
        except Exception as e:
            self.root.title("MaxLink™ Admin Panel - Erreur de configuration")
            
        self.root.geometry("1280x720")
        self.root.configure(bg=COLORS["nord0"])
        
        # Centrer la fenêtre
        self.center_window()
        
        # Vérifier si on est en mode root
        self.root_mode = self.check_root_mode()
        
        # Charger les services depuis les variables
        try:
            self.services = self.variables.get_services_list()
            self.selected_service = self.services[0] if self.services else None
        except Exception as e:
            messagebox.showerror(
                "Erreur de configuration",
                f"Impossible de charger les services:\n{e}\n\nL'application va se fermer."
            )
            root.destroy()
            return
        
        # Variables pour la barre de progression
        self.progress_value = 0
        self.progress_max = 100
        self.progress_start_time = None
        
        # Créer l'interface
        self.create_interface()
    
    def center_window(self):
        """Centre la fenêtre sur l'écran"""
        self.root.update_idletasks()
        width = self.root.winfo_width()
        height = self.root.winfo_height()
        x = (self.root.winfo_screenwidth() // 2) - (width // 2)
        y = (self.root.winfo_screenheight() // 2) - (height // 2)
        self.root.geometry(f'{width}x{height}+{x}+{y}')
        
    def check_root_mode(self):
        """Vérifier si l'interface est lancée avec les privilèges root"""
        # Vérifier le fichier de session
        session_file = os.path.join(self.base_path, '.maxlink_session')
        if os.path.exists(session_file):
            try:
                with open(session_file, 'r') as f:
                    content = f.read()
                    if 'MAXLINK_ROOT_MODE=1' in content:
                        return True
            except:
                pass
        
        # Vérifier si on est root (compatible Windows/Linux)
        try:
            if hasattr(os, 'geteuid'):
                return os.geteuid() == 0
            else:
                # Windows - mode test
                import ctypes
                try:
                    return ctypes.windll.shell32.IsUserAnAdmin() != 0
                except:
                    return False
        except:
            return True  # Mode développement
        
    def create_interface(self):
        # Conteneur principal
        main = tk.Frame(self.root, bg=COLORS["nord0"], padx=15, pady=15)
        main.pack(fill="both", expand=True)
        
        # Panneau gauche (services + boutons)
        self.left_frame = tk.Frame(main, bg=COLORS["nord1"], width=350)
        self.left_frame.pack_propagate(False)
        self.left_frame.pack(side="left", fill="both", padx=15)
        
        # Zone des services
        services_frame = tk.Frame(self.left_frame, bg=COLORS["nord1"], padx=15, pady=15)
        services_frame.pack(fill="both", expand=True)
        
        services_title = tk.Label(
            services_frame,
            text="Services Disponibles",
            font=("Arial", 16, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        services_title.pack(pady=15)
        
        # Indicateur de mode privilégié
        if IS_WINDOWS:
            privilege_text = "Mode: Test Windows"
            privilege_color = COLORS["nord15"]
        else:
            privilege_text = "Mode Privilégié: ◦ ACTIF" if self.root_mode else "Mode Privilégié: ⚠ INACTIF"
            privilege_color = COLORS["nord14"] if self.root_mode else COLORS["nord11"]
        
        privilege_label = tk.Label(
            services_frame,
            text=privilege_text,
            font=("Arial", 10, "bold"),
            bg=COLORS["nord1"],
            fg=privilege_color
        )
        privilege_label.pack(pady=10)
        
        # Créer les éléments de service
        for service in self.services:
            self.create_service_item(services_frame, service)
        
        # Zone des boutons d'action
        buttons_frame = tk.Frame(self.left_frame, bg=COLORS["nord1"], padx=15, pady=20)
        buttons_frame.pack(fill="x")
        
        # Créer les boutons d'action
        self.create_action_buttons(buttons_frame)
        
        # Panneau droit (console + barre de progression)
        right_frame = tk.Frame(main, bg=COLORS["nord1"])
        right_frame.pack(side="right", fill="both", expand=True)
        
        # Console de sortie
        console_frame = tk.Frame(right_frame, bg=COLORS["nord1"], padx=15, pady=15)
        console_frame.pack(fill="both", expand=True)
        
        console_title = tk.Label(
            console_frame,
            text="Console de Sortie",
            font=("Arial", 16, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        console_title.pack(pady=10)
        
        self.console = scrolledtext.ScrolledText(
            console_frame, 
            bg=COLORS["nord0"], 
            fg=COLORS["nord6"],
            font=("Monospace", 11),
            wrap=tk.WORD
        )
        self.console.pack(fill="both", expand=True)
        
        # Cadre pour la barre de progression
        self.progress_frame = tk.Frame(right_frame, bg=COLORS["nord1"], padx=15, pady=15)
        self.progress_frame.pack(fill="x", side="bottom")
        
        # Titre de la progression
        self.progress_label = tk.Label(
            self.progress_frame,
            text="Progression",
            font=("Arial", 12, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        self.progress_label.pack(pady=10)
        
        # Canvas pour la barre de progression
        self.progress_canvas = tk.Canvas(
            self.progress_frame,
            height=30,
            bg=COLORS["nord0"],
            highlightthickness=0
        )
        self.progress_canvas.pack(fill="x", padx=10, pady=5)
        
        # Label pour les informations de progression
        self.progress_info = tk.Label(
            self.progress_frame,
            text="En attente...",
            font=("Arial", 10),
            bg=COLORS["nord1"],
            fg=COLORS["nord4"]
        )
        self.progress_info.pack()
        
        # Masquer la barre de progression initialement
        self.progress_frame.pack_forget()
        
        # Message d'accueil dans la console
        self.create_welcome_message()
        
        # Appliquer la sélection initiale
        self.update_selection()
    
    def show_progress_bar(self):
        """Affiche la barre de progression"""
        self.progress_frame.pack(fill="x", side="bottom")
        self.progress_value = 0
        self.progress_start_time = time.time()
        self.update_progress_bar()
    
    def hide_progress_bar(self):
        """Masque la barre de progression"""
        self.progress_frame.pack_forget()
    
    def update_progress_bar(self, value=None, text="En cours..."):
        """Met à jour la barre de progression"""
        if value is not None:
            self.progress_value = value
        
        # Calculer les dimensions
        self.progress_canvas.update_idletasks()
        width = self.progress_canvas.winfo_width() - 20
        height = 20
        
        # Effacer le canvas
        self.progress_canvas.delete("all")
        
        # Dessiner le fond
        self.progress_canvas.create_rectangle(
            10, 5, width + 10, height + 5,
            fill=COLORS["nord3"], outline=""
        )
        
        # Dessiner la barre de progression
        if self.progress_value > 0:
            filled_width = int(width * self.progress_value / self.progress_max)
            self.progress_canvas.create_rectangle(
                10, 5, filled_width + 10, height + 5,
                fill=COLORS["nord8"], outline=""
            )
        
        # Afficher le pourcentage au centre
        percentage = int(self.progress_value * 100 / self.progress_max)
        self.progress_canvas.create_text(
            width / 2 + 10, height / 2 + 5,
            text=f"{percentage}%",
            fill=COLORS["nord6"],
            font=("Arial", 10, "bold")
        )
        
        # Calculer le temps écoulé et restant
        if self.progress_start_time and self.progress_value > 0:
            elapsed = time.time() - self.progress_start_time
            eta = (elapsed / self.progress_value) * (self.progress_max - self.progress_value) if self.progress_value > 0 else 0
            
            elapsed_str = f"{int(elapsed // 60):02d}:{int(elapsed % 60):02d}"
            eta_str = f"{int(eta // 60):02d}:{int(eta % 60):02d}"
            
            self.progress_info.config(text=f"{text} | Écoulé: {elapsed_str} | Restant: ~{eta_str}")
        else:
            self.progress_info.config(text=text)
    
    def create_welcome_message(self):
        """Crée le message d'accueil simplifié"""
        if IS_WINDOWS:
            welcome_msg = "Console prête - Mode test Windows\n\n"
        else:
            status = "Mode privilégié actif" if self.root_mode else "Mode privilégié inactif"
            welcome_msg = f"Console prête - {status}\n\n"
        
        self.console.insert(tk.END, welcome_msg)
        self.console.config(state=tk.DISABLED)
        
    def create_service_item(self, parent, service):
        # Frame pour le service
        frame = tk.Frame(
            parent,
            bg=COLORS["nord1"],
            highlightthickness=3,
            padx=10,
            pady=10
        )
        frame.pack(fill="x", pady=8)
        
        # Configure les événements de clic
        frame.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
        # Nom du service (centré)
        label = tk.Label(
            frame, 
            text=service["name"],
            font=("Arial", 14, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"],
            anchor="center"
        )
        label.pack(side="left", fill="both", expand=True)
        label.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
        # Indicateur de statut
        status_color = COLORS["nord14"] if service["status"] == "active" else COLORS["nord11"]
        indicator = tk.Canvas(frame, width=20, height=20, bg=COLORS["nord1"], highlightthickness=0)
        indicator.pack(side="right", padx=10)
        indicator.create_oval(2, 2, 18, 18, fill=status_color, outline="")
        indicator.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
        # Stocker les références
        service["frame"] = frame
        service["indicator"] = indicator
        
    def create_action_buttons(self, parent):
        # Style commun
        button_style = {
            "font": ("Arial", 16, "bold"),
            "width": 20,
            "height": 2,
            "borderwidth": 0,
            "highlightthickness": 0,
            "cursor": "hand2"
        }
        
        # Boutons d'action
        actions = [
            {"text": "Installer", "bg": COLORS["nord10"], "action": "install"},
            {"text": "Démarrer", "bg": COLORS["nord14"], "action": "start"},
            {"text": "Tester", "bg": COLORS["nord15"], "action": "test"},
            {"text": "Désinstaller", "bg": COLORS["nord11"], "action": "uninstall"}
        ]
        
        for action in actions:
            btn = tk.Button(
                parent, 
                text=action["text"],
                bg=action["bg"],
                fg=COLORS["nord6"],
                command=lambda a=action["action"]: self.run_action(a),
                **button_style
            )
            btn.pack(fill="x", pady=5)
        
    def select_service(self, service):
        self.selected_service = service
        self.update_selection()
            
    def update_selection(self):
        for service in self.services:
            is_selected = service == self.selected_service
            border_color = COLORS["nord8"] if is_selected else COLORS["nord1"]
            service["frame"].config(highlightbackground=border_color, highlightcolor=border_color)
            
    def run_action(self, action):
        if not self.selected_service:
            return
            
        service = self.selected_service
        service_id = service["id"]
        
        # Sur Windows : ne rien faire, juste afficher dans la console
        if IS_WINDOWS:
            self.update_console(f"[Mode Test Windows] Action: {action} - Service: {service['name']}\n")
            return
            
        # Sur Linux : vérifier le mode privilégié
        if not self.root_mode:
            messagebox.showerror(
                "Privilèges insuffisants",
                "Cette interface doit être lancée avec des privilèges root.\n\n"
                "Fermez cette fenêtre et relancez avec :\n"
                "sudo bash config.sh"
            )
            return
            
        # Confirmation spéciale pour les désinstallations
        if action == "uninstall":
            result = messagebox.askyesno(
                "Confirmation de désinstallation",
                f"⚠ ATTENTION ⚠\n\n"
                f"Vous êtes sur le point de désinstaller complètement :\n"
                f"• {service['name']} [{service_id}]\n\n"
                f"Cette opération :\n"
                f"• Supprimera toutes les configurations\n"
                f"• Restaurera les paramètres par défaut\n"
                f"• Redémarrera automatiquement le système\n"
                f"• Ne peut pas être annulée facilement\n\n"
                f"Êtes-vous sûr de vouloir continuer ?",
                icon="warning"
            )
            
            if not result:
                self.update_console(f"Désinstallation de {service['name']} annulée.\n\n")
                return
        
        # Chemin du script
        script_path = f"scripts/{action}/{service_id}_{action}.sh"
        
        # Afficher l'action dans la console
        action_header = f"""
{"="*80}
EXÉCUTION: {service['name']} - {action.upper()}
{"="*80}
Service ID: {service_id}
Script: {script_path}
Logs: logs/{service_id}_{action}.log
Configuration: {self.variables.get('MAXLINK_VERSION', 'N/A')}
{"="*80}

"""
        self.update_console(action_header)
        
        # Afficher la barre de progression
        self.show_progress_bar()
        
        # Exécuter le script en arrière-plan
        threading.Thread(target=self.execute_script, args=(script_path, service, action), daemon=True).start()
    
    def execute_script(self, script_path, service, action):
        try:
            # Construire le chemin complet du script
            full_script_path = os.path.join(self.base_path, script_path)
            
            # Vérifier si le script existe
            if not os.path.exists(full_script_path):
                self.update_console(f"ERREUR: Script {script_path} non trouvé\n")
                self.update_console(f"Chemin recherché: {full_script_path}\n\n")
                self.hide_progress_bar()
                return
            
            # Exécuter avec subprocess de manière sécurisée
            cmd = ["bash", full_script_path]
            
            self.update_console(f"Exécution: {' '.join(cmd)}\n\n")
            
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE, 
                text=True, 
                bufsize=1,
                env=os.environ.copy()
            )
            
            # Lire la sortie en temps réel et détecter les mises à jour de progression
            for line in iter(process.stdout.readline, ''):
                if line:
                    # Chercher les mises à jour de progression dans la sortie
                    progress_match = re.search(r'PROGRESS:(\d+):(.+)', line)
                    if progress_match:
                        progress_value = int(progress_match.group(1))
                        progress_text = progress_match.group(2)
                        self.root.after(0, self.update_progress_bar, progress_value, progress_text)
                    else:
                        self.update_console(line)
            
            for line in iter(process.stderr.readline, ''):
                if line:
                    self.update_console(line, error=True)
            
            # Attendre la fin du processus
            return_code = process.wait()
            
            # Masquer la barre de progression
            self.root.after(0, self.hide_progress_bar)
            
            # Message de fin
            end_message = f"""
{"="*80}
TERMINÉ: {service['name']} - {action.upper()}
Code de sortie: {return_code}
{"="*80}

"""
            self.update_console(end_message)
            
            # Mettre à jour le statut
            if return_code == 0:
                if action == "start" or action == "install":
                    service["status"] = "active"
                    self.update_status_indicator(service, True)
                elif action == "uninstall":
                    service["status"] = "inactive"
                    self.update_status_indicator(service, False)
            else:
                self.update_console(f"⚠ Le script s'est terminé avec des erreurs (code {return_code})\n\n")
            
        except Exception as e:
            self.update_console(f"ERREUR SYSTÈME: {str(e)}\n\n", error=True)
            self.root.after(0, self.hide_progress_bar)
    
    def update_status_indicator(self, service, is_active):
        if "indicator" in service:
            status_color = COLORS["nord14"] if is_active else COLORS["nord11"]
            service["indicator"].delete("all")
            service["indicator"].create_oval(2, 2, 18, 18, fill=status_color, outline="")
    
    def update_console(self, text, error=False):
        # Thread-safe update
        self.root.after(0, self._update_console, text, error)
    
    def _update_console(self, text, error):
        self.console.config(state=tk.NORMAL)
        
        if error:
            self.console.tag_configure("error", foreground=COLORS["nord11"])
            self.console.insert(tk.END, text, "error")
        else:
            self.console.insert(tk.END, text)
            
        self.console.see(tk.END)
        self.console.config(state=tk.DISABLED)

# ===============================================================================
# POINT D'ENTRÉE PRINCIPAL
# ===============================================================================

if __name__ == "__main__":
    # Valider la configuration AVANT de créer l'interface
    print("Validation de la configuration...")
    
    is_valid, variables, error_msg = validate_configuration()
    
    if not is_valid:
        # Afficher l'erreur dans le terminal
        print("\n" + "="*80)
        print("ERREUR DE CONFIGURATION")
        print("="*80)
        print(f"\n{error_msg}\n")
        print("L'interface ne peut pas démarrer sans une configuration valide.")
        print("Vérifiez le fichier: scripts/common/variables.sh")
        print("\n" + "="*80)
        
        # Sortir avec un code d'erreur
        sys.exit(1)
    
    # Si la configuration est valide, créer l'interface
    print("Configuration validée, lancement de l'interface...")
    
    try:
        root = tk.Tk()
        app = MaxLinkApp(root, variables)
        root.mainloop()
    except Exception as e:
        print(f"\nErreur lors du démarrage de l'interface: {e}")
        sys.exit(2)