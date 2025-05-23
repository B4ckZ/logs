import tkinter as tk
from tkinter import scrolledtext, messagebox
import subprocess
import os
import threading
from datetime import datetime
import re

# Couleurs du thème Nord - Interface principale
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
            print(f"ATTENTION: Fichier variables.sh non trouvé: {variables_file}")
            self._load_default_variables()
            return
        
        try:
            with open(variables_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # Parser les variables bash (format VARIABLE="valeur" ou VARIABLE=valeur)
            pattern = r'^([A-Z_][A-Z0-9_]*)=(["\']?)([^"\']*)\2'
            
            for line in content.split('\n'):
                line = line.strip()
                # Ignorer les commentaires et lignes vides
                if line.startswith('#') or not line:
                    continue
                
                match = re.match(pattern, line)
                if match:
                    var_name = match.group(1)
                    var_value = match.group(3)
                    self.variables[var_name] = var_value
            
            # Parser les arrays (format ARRAY=("val1" "val2" "val3"))
            array_pattern = r'^([A-Z_][A-Z0-9_]*)\s*=\s*\((.*?)\)'
            for match in re.finditer(array_pattern, content, re.MULTILINE | re.DOTALL):
                var_name = match.group(1)
                array_content = match.group(2)
                # Extraire les valeurs entre guillemets
                values = re.findall(r'"([^"]*)"', array_content)
                self.variables[var_name] = values
            
            print(f"Variables chargées: {len(self.variables)} éléments")
            
        except Exception as e:
            print(f"Erreur lors du chargement de variables.sh: {e}")
            self._load_default_variables()
    
    def _load_default_variables(self):
        """Charge des variables par défaut si le fichier n'existe pas"""
        self.variables = {
            'MAXLINK_VERSION': '2.0',
            'MAXLINK_BUILD': 'Build 2025.01',
            'MAXLINK_COPYRIGHT': '© 2025 WERIT. Tous droits réservés.',
            'MAXLINK_COMPANY': 'WERIT',
            'MAXLINK_PROJECT_NAME': 'MaxLink',
            'SYSTEM_USER': 'max',
            'WIFI_SSID': 'Max',
            'AP_SSID': 'MaxLink-NETWORK',
            'SERVICES_LIST': [
                "update:Update RPI:active",
                "ap:Network AP:active", 
                "nginx:NginX Web:inactive",
                "mqtt:MQTT BKR:inactive"
            ]
        }
        print("Variables par défaut chargées")
    
    def get(self, key, default=None):
        """Récupère une variable avec valeur par défaut"""
        return self.variables.get(key, default)
    
    def get_window_title(self):
        """Construit le titre de la fenêtre depuis les variables"""
        version = self.get('MAXLINK_VERSION', '2.0')
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
        
        # Fallback si aucun service défini
        if not services:
            services = [
                {"id": "update", "name": "Update RPI", "status": "active"},
                {"id": "ap", "name": "Network AP", "status": "active"},
                {"id": "nginx", "name": "NginX Web", "status": "inactive"},
                {"id": "mqtt", "name": "MQTT BKR", "status": "inactive"}
            ]
        
        return services
    
    def print_loaded_variables(self):
        """Affiche les variables chargées pour debug"""
        print("\n=== VARIABLES CHARGÉES ===")
        for key, value in sorted(self.variables.items()):
            if isinstance(value, list):
                print(f"{key}: {value}")
            else:
                print(f"{key}: {value}")
        print("========================\n")

class MaxLinkApp:
    def __init__(self, root):
        self.root = root
        
        # Chemins et initialisation
        self.base_path = os.path.dirname(os.path.abspath(__file__))
        
        # NOUVEAU: Charger les variables centralisées
        self.variables = VariablesManager(self.base_path)
        
        # Debug: afficher les variables chargées
        self.variables.print_loaded_variables()
        
        # Configuration de la fenêtre avec variables
        self.root.title(self.variables.get_window_title())
        self.root.geometry("1200x700")
        self.root.configure(bg=COLORS["nord0"])
        
        # NOUVEAU : Vérifier si on est en mode root
        self.root_mode = self.check_root_mode()
        
        # Charger les services depuis les variables
        self.services = self.variables.get_services_list()
        self.selected_service = self.services[0] if self.services else None
        
        # Créer l'interface
        self.create_interface()
        
    def check_root_mode(self):
        """Vérifier si l'interface est lancée avec les privilèges root"""
        # Vérifier le fichier de session
        session_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.maxlink_session')
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
            # Sur Linux/Unix
            if hasattr(os, 'geteuid'):
                return os.geteuid() == 0
            # Sur Windows - vérifier si on est administrateur
            else:
                import ctypes
                try:
                    return ctypes.windll.shell32.IsUserAnAdmin() != 0
                except:
                    # Si on ne peut pas vérifier, considérer comme non-privilégié
                    return False
        except:
            # En cas d'erreur, mode développement sur Windows
            return True  # Pour les tests sur Windows
        
    def create_interface(self):
        # Conteneur principal
        main = tk.Frame(self.root, bg=COLORS["nord0"], padx=15, pady=15)
        main.pack(fill="both", expand=True)
        
        # Panneau gauche (services + boutons)
        self.left_frame = tk.Frame(main, bg=COLORS["nord1"], width=350)
        self.left_frame.pack_propagate(False)
        self.left_frame.pack(side="left", fill="both", padx=(0, 15))
        
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
        services_title.pack(pady=(0, 15))
        
        # NOUVEAU : Indicateur de mode privilégié adapté au système avec variables
        import platform
        is_windows = (platform.system() == "Windows")
        
        if is_windows:
            privilege_text = "Mode: Test Windows"
            privilege_color = COLORS["nord15"]
        else:
            privilege_text = "Mode Privilégié: ◦ ACTIF" if self.root_mode else "Mode Privilégié: ⦿ INACTIF"
            privilege_color = COLORS["nord14"] if self.root_mode else COLORS["nord11"]
        
        privilege_label = tk.Label(
            services_frame,
            text=privilege_text,
            font=("Arial", 10, "bold"),
            bg=COLORS["nord1"],
            fg=privilege_color
        )
        privilege_label.pack(pady=(0, 10))
        

        
        # Créer les éléments de service
        for service in self.services:
            self.create_service_item(services_frame, service)
        
        # Zone des boutons d'action
        buttons_frame = tk.Frame(self.left_frame, bg=COLORS["nord1"], padx=15, pady=20)
        buttons_frame.pack(fill="x")
        
        # Créer les boutons d'action
        self.create_action_buttons(buttons_frame)
        
        # Panneau droit (console)
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
        console_title.pack(pady=(0, 10))
        
        self.console = scrolledtext.ScrolledText(
            console_frame, 
            bg=COLORS["nord0"], 
            fg=COLORS["nord6"],
            font=("Monospace", 11),
            wrap=tk.WORD
        )
        self.console.pack(fill="both", expand=True)
        
        # Message d'accueil dans la console AVEC VARIABLES
        self.create_welcome_message()
        
        # Appliquer la sélection initiale
        self.update_selection()
    
    def create_welcome_message(self):
        """Crée le message d'accueil simplifié"""
        import platform
        is_windows = (platform.system() == "Windows")
        
        if is_windows:
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
        for widget in [frame]:
            widget.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
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
            # Couleur plus visible pour la sélection
            border_color = COLORS["nord8"] if is_selected else COLORS["nord1"]
            service["frame"].config(highlightbackground=border_color, highlightcolor=border_color)
            
    def run_action(self, action):
        if not self.selected_service:
            return
            
        service = self.selected_service
        service_id = service["id"]
        
        # Détecter le système
        import platform
        is_windows = (platform.system() == "Windows")
        
        # Sur Windows : juste vérifier que l'interface s'ouvre (pas d'exécution)
        if is_windows:
            # NOUVEAU: Message avec variables
            project_name = self.variables.get('MAXLINK_PROJECT_NAME', 'MaxLink')
            messagebox.showinfo(
                f"Mode Test Windows - {project_name}",
                f"Interface testée avec succès !\n\n"
                f"Action simulée : {action.upper()}\n"
                f"Service : {service['name']}\n"
                f"ID Service : {service_id}\n\n"
                f"Configuration chargée :\n"
                f"• Projet: {project_name}\n"
                f"• Version: {self.variables.get('MAXLINK_VERSION', 'N/A')}\n"
                f"• Build: {self.variables.get('MAXLINK_BUILD', 'N/A')}\n\n"
                f"Pour utilisation réelle :\n"
                f"• Transférez sur Raspberry Pi Linux\n"
                f"• Lancez avec : sudo bash config.sh"
            )
            return
            
        # Sur Linux : vérifier le mode privilégié avant d'exécuter
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
                f"⦿ ATTENTION ⦿\n\n"
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
                self.update_console(f"Désinstallation de {service['name']} [{service_id}] annulée par l'utilisateur.\n\n")
                return
        
        # Nouveau chemin basé sur les sous-dossiers
        script_path = f"scripts/{action}/{service_id}_{action}.sh"
        
        # Afficher l'action dans la console AVEC VARIABLES
        project_name = self.variables.get('MAXLINK_PROJECT_NAME', 'MaxLink')
        action_header = f"""
{"="*80}
{project_name.upper()} - EXÉCUTION: {service['name']} - {action.upper()}
{"="*80}
Service ID: {service_id}
Script: {script_path}
Logs détaillés: logs/{service_id}_{action}.log
Mode privilégié: ◦ ACTIF
Utilisateur système: {self.variables.get('SYSTEM_USER', 'max')}
Configuration: variables.sh chargée
{"="*80}

"""
        self.update_console(action_header)
        
        # Exécuter le script en arrière-plan
        threading.Thread(target=self.execute_script, args=(script_path, service, action), daemon=True).start()
    
    def get_timestamp(self):
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    def execute_script(self, script_path, service, action):
        try:
            # Construire le chemin complet du script
            full_script_path = os.path.join(self.base_path, script_path)
            
            # Vérifier si le script existe
            if not os.path.exists(full_script_path):
                self.update_console(f"ERREUR: Script {script_path} non trouvé\n")
                self.update_console(f"Chemin recherché: {full_script_path}\n\n")
                return
                
            # MODIFICATION CRITIQUE : Exécuter directement sans sudo
            # Car on est déjà root grâce au lancement avec sudo bash config.sh
            cmd = f"bash {full_script_path}"
            
            self.update_console(f"Exécution de la commande: {cmd}\n")
            
            # Afficher les informations de privilèges selon le système
            try:
                if hasattr(os, 'getuid'):
                    # Linux/Unix
                    self.update_console(f"Mode privilégié: ◦ ACTIF (UID={os.getuid()})\n")
                    self.update_console(f"Utilisateur cible: {self.variables.get('SYSTEM_USER', 'max')}\n\n")
                else:
                    # Windows
                    self.update_console(f"Mode privilégié: ◦ ACTIF (Windows)\n\n")
            except:
                self.update_console(f"Mode privilégié: ◦ ACTIF\n\n")
            
            process = subprocess.Popen(
                cmd,
                shell=True,
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE, 
                text=True, 
                bufsize=1,
                # NOUVEAU : Préserver l'environnement root
                env=os.environ.copy()
            )
            
            # Afficher la sortie en temps réel
            for line in iter(process.stdout.readline, ''):
                if line:
                    self.update_console(line)
            
            for line in iter(process.stderr.readline, ''):
                if line:
                    self.update_console(line, error=True)
            
            # Attendre la fin du processus
            return_code = process.wait()
            
            # Message de fin avec statut ET VARIABLES
            project_name = self.variables.get('MAXLINK_PROJECT_NAME', 'MaxLink')
            end_message = f"""
{"="*80}
{project_name.upper()} - TERMINÉ: {service['name']} - {action.upper()}
Code de sortie: {return_code}
Logs complets: logs/{service['id']}_{action}.log
Configuration: {self.variables.get('MAXLINK_BUILD', 'Build 2025.01')}
{"="*80}

"""
            self.update_console(end_message)
            
            # Mettre à jour le statut (simulation)
            if return_code == 0:
                if action == "start" or action == "install":
                    service["status"] = "active"
                    self.update_status_indicator(service, True)
                elif action == "uninstall":
                    service["status"] = "inactive"
                    self.update_status_indicator(service, False)
            else:
                self.update_console(f"⦿ Le script s'est terminé avec des erreurs (code {return_code})\n")
                self.update_console("Consultez les logs pour plus de détails.\n\n")
            
        except Exception as e:
            self.update_console(f"ERREUR SYSTÈME: {str(e)}\n\n", error=True)
    
    def update_status_indicator(self, service, is_active):
        if "indicator" in service:
            status_color = COLORS["nord14"] if is_active else COLORS["nord11"]
            service["indicator"].delete("all")
            service["indicator"].create_oval(2, 2, 18, 18, fill=status_color, outline="")
    
    def update_console(self, text, error=False):
        # Utilisation de after pour la thread-safety
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

if __name__ == "__main__":
    root = tk.Tk()
    app = MaxLinkApp(root)
    root.mainloop()