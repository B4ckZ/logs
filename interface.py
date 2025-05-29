import tkinter as tk
from tkinter import scrolledtext, messagebox
import subprocess
import os
import sys
import threading
from datetime import datetime
import re
import json
import logging
from pathlib import Path

# ===============================================================================
# CONFIGURATION DU LOGGING UNIFIÉ
# ===============================================================================

# Configuration du logging pour correspondre au système bash
base_dir = Path(__file__).resolve().parent
log_dir = base_dir / "logs" / "python"
log_dir.mkdir(parents=True, exist_ok=True)

# Nom du script pour le logging
script_name = "interface"
log_file = log_dir / f"{script_name}.log"

# Format identique aux scripts bash : [timestamp] [level] [script] message
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] [interface] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    handlers=[
        logging.FileHandler(log_file, mode='a', encoding='utf-8'),
        logging.StreamHandler()  # Console aussi
    ]
)
logger = logging.getLogger('interface')

# Header de démarrage dans le log
def log_startup():
    with open(log_file, 'a') as f:
        f.write("\n")
        f.write("="*80 + "\n")
        f.write(f"DÉMARRAGE: {script_name}\n")
        f.write(f"Description: Interface graphique MaxLink Admin Panel\n")
        f.write(f"Date: {datetime.now().strftime('%c')}\n")
        f.write(f"Utilisateur: {os.environ.get('USER', 'unknown')}\n")
        f.write(f"Répertoire: {os.getcwd()}\n")
        f.write("="*80 + "\n")
        f.write("\n")
    logger.info("Interface MaxLink démarrée")

# ===============================================================================
# CONFIGURATION
# ===============================================================================

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
    "nord14": "#A3BE8C", # Vert / Succès
    "nord15": "#B48EAD", # Violet / Tester
}

# ===============================================================================
# POPUP DE CONFIRMATION PERSONNALISÉE
# ===============================================================================

class StyledConfirmDialog:
    """Dialogue de confirmation avec le style Nord"""
    
    def __init__(self, parent, title, message):
        self.result = False
        logger.debug(f"Création dialogue: {title}")
        
        # Créer la fenêtre
        self.dialog = tk.Toplevel(parent)
        self.dialog.title(title)
        self.dialog.configure(bg=COLORS["nord0"])
        
        # Rendre modale
        self.dialog.transient(parent)
        self.dialog.grab_set()
        
        # Taille et position
        width, height = 500, 200
        x = (self.dialog.winfo_screenwidth() // 2) - (width // 2)
        y = (self.dialog.winfo_screenheight() // 2) - (height // 2)
        self.dialog.geometry(f"{width}x{height}+{x}+{y}")
        
        # Désactiver le redimensionnement
        self.dialog.resizable(False, False)
        
        # Créer le contenu
        self.create_content(message)
        
        # Focus
        self.dialog.focus_set()
        
        # Bind Escape
        self.dialog.bind('<Escape>', lambda e: self.on_no())
        self.dialog.bind('<Return>', lambda e: self.on_yes())
    
    def create_content(self, message):
        # Frame principal
        main_frame = tk.Frame(self.dialog, bg=COLORS["nord1"], padx=30, pady=30)
        main_frame.pack(fill="both", expand=True, padx=2, pady=2)
        
        # Icône et message
        msg_frame = tk.Frame(main_frame, bg=COLORS["nord1"])
        msg_frame.pack(fill="both", expand=True)
        
        # Icône d'interrogation
        icon_label = tk.Label(
            msg_frame,
            text="?",
            font=("Arial", 36, "bold"),
            fg=COLORS["nord8"],
            bg=COLORS["nord1"]
        )
        icon_label.pack(side="left", padx=(0, 20))
        
        # Message
        msg_label = tk.Label(
            msg_frame,
            text=message,
            font=("Arial", 14),
            fg=COLORS["nord6"],
            bg=COLORS["nord1"],
            wraplength=350,
            justify="left"
        )
        msg_label.pack(side="left", fill="both", expand=True)
        
        # Séparateur
        separator = tk.Frame(main_frame, height=2, bg=COLORS["nord3"])
        separator.pack(fill="x", pady=20)
        
        # Boutons
        btn_frame = tk.Frame(main_frame, bg=COLORS["nord1"])
        btn_frame.pack(fill="x")
        
        # Style des boutons
        btn_style = {
            "font": ("Arial", 14, "bold"),
            "width": 10,
            "borderwidth": 0,
            "highlightthickness": 0,
            "cursor": "hand2",
            "pady": 8
        }
        
        # Bouton OUI
        yes_btn = tk.Button(
            btn_frame,
            text="OUI",
            bg=COLORS["nord14"],
            fg=COLORS["nord0"],
            command=self.on_yes,
            **btn_style
        )
        yes_btn.pack(side="right", padx=(10, 0))
        
        # Bouton NON
        no_btn = tk.Button(
            btn_frame,
            text="NON",
            bg=COLORS["nord11"],
            fg=COLORS["nord6"],
            command=self.on_no,
            **btn_style
        )
        no_btn.pack(side="right")
    
    def on_yes(self):
        self.result = True
        logger.debug("Dialogue: réponse OUI")
        self.dialog.destroy()
    
    def on_no(self):
        self.result = False
        logger.debug("Dialogue: réponse NON")
        self.dialog.destroy()
    
    def show(self):
        """Affiche le dialogue et retourne le résultat"""
        self.dialog.wait_window()
        return self.result

# ===============================================================================
# GESTIONNAIRE DE VARIABLES
# ===============================================================================

class VariablesManager:
    """Gestionnaire pour charger et utiliser les variables de variables.sh"""
    
    def __init__(self, base_path):
        self.base_path = base_path
        self.variables = {}
        logger.info("Initialisation du gestionnaire de variables")
        self.load_variables()
    
    def load_variables(self):
        """Charge les variables depuis le fichier variables.sh"""
        variables_file = os.path.join(self.base_path, "scripts", "common", "variables.sh")
        
        if not os.path.exists(variables_file):
            logger.error(f"Fichier variables.sh non trouvé: {variables_file}")
            raise FileNotFoundError(f"Fichier variables.sh non trouvé: {variables_file}")
        
        try:
            with open(variables_file, 'r') as f:
                content = f.read()
            
            # Parser les variables simples
            for line in content.split('\n'):
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    if line.startswith('export') or line.startswith('function') or '()' in line:
                        continue
                    
                    match = re.match(r'^([A-Z_][A-Z0-9_]*)="?([^"]*)"?$', line)
                    if match:
                        key = match.group(1)
                        value = match.group(2)
                        self.variables[key] = value
            
            # Parser SERVICES_LIST
            services = [
                "update:Update RPI:active",
                "ap:Network AP:active",
                "nginx:NginX Web:inactive",
                "mqtt:MQTT BKR:inactive",
                "mqtt_wgs:MQTT WGS:inactive"
            ]
            self.variables['SERVICES_LIST'] = services
            
            logger.info(f"Variables chargées: {len(self.variables)} variables")
                
        except Exception as e:
            logger.error(f"Erreur lors du chargement de variables.sh: {e}")
            raise Exception(f"Erreur lors du chargement de variables.sh: {e}")
    
    def get(self, key, default=None):
        """Récupère une variable avec valeur par défaut"""
        return self.variables.get(key, default)
    
    def get_window_title(self):
        """Construit le titre de la fenêtre"""
        version = self.get('MAXLINK_VERSION', '1.0')
        copyright_text = self.get('MAXLINK_COPYRIGHT', '© 2025 WERIT')
        return f"MaxLink™ Admin Panel V{version} - {copyright_text}"
    
    def get_services_list(self):
        """Parse la liste des services"""
        services_raw = self.get('SERVICES_LIST', [])
        services = []
        
        for service_def in services_raw:
            if isinstance(service_def, str):
                parts = service_def.split(':')
                if len(parts) == 3:
                    services.append({
                        "id": parts[0],
                        "name": parts[1], 
                        "status": parts[2]
                    })
        
        return services

# ===============================================================================
# APPLICATION PRINCIPALE
# ===============================================================================

class MaxLinkApp:
    def __init__(self, root, variables):
        self.root = root
        self.variables = variables
        
        logger.info("Initialisation de l'application MaxLink")
        
        # Chemins
        self.base_path = os.path.dirname(os.path.abspath(__file__))
        
        # Configuration de la fenêtre
        self.root.title(self.variables.get_window_title())
        self.root.geometry("1200x750")
        self.root.configure(bg=COLORS["nord0"])
        
        # Centrer la fenêtre
        self.center_window()
        
        # Vérifier le mode root
        self.root_mode = self.check_root_mode()
        logger.info(f"Mode root: {self.root_mode}")
        
        # Charger les services
        self.services = self.variables.get_services_list()
        self.selected_service = self.services[0] if self.services else None
        logger.info(f"Services chargés: {len(self.services)}")
        
        # Variables de progression
        self.progress_value = 0
        self.progress_max = 100
        
        # Thread d'exécution actuel
        self.current_process = None
        self.current_thread = None
        
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
        try:
            return os.geteuid() == 0
        except:
            return False
    
    def create_interface(self):
        # Conteneur principal
        main = tk.Frame(self.root, bg=COLORS["nord0"], padx=20, pady=20)
        main.pack(fill="both", expand=True)
        
        # Panneau gauche (services + boutons)
        self.left_frame = tk.Frame(main, bg=COLORS["nord1"], width=300)
        self.left_frame.pack_propagate(False)
        self.left_frame.pack(side="left", fill="both", padx=(0, 20))
        
        # Zone des services
        services_frame = tk.Frame(self.left_frame, bg=COLORS["nord1"], padx=20, pady=20)
        services_frame.pack(fill="both", expand=True)
        
        # Titre services
        services_title = tk.Label(
            services_frame,
            text="Services Disponibles",
            font=("Arial", 18, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        services_title.pack(pady=(0, 20))
        
        # Créer les services
        for service in self.services:
            self.create_service_item(services_frame, service)
        
        # Zone des boutons (3 boutons)
        buttons_frame = tk.Frame(self.left_frame, bg=COLORS["nord1"], padx=20, pady=20)
        buttons_frame.pack(fill="x")
        
        self.create_action_buttons(buttons_frame)
        
        # Panneau droit (console)
        right_frame = tk.Frame(main, bg=COLORS["nord1"])
        right_frame.pack(side="right", fill="both", expand=True)
        
        # Console
        console_frame = tk.Frame(right_frame, bg=COLORS["nord1"], padx=20, pady=20)
        console_frame.pack(fill="both", expand=True)
        
        # Titre console avec indicateur de privilèges
        console_title_frame = tk.Frame(console_frame, bg=COLORS["nord1"])
        console_title_frame.pack(fill="x", pady=(0, 10))
        
        console_title = tk.Label(
            console_title_frame,
            text="Console de Sortie",
            font=("Arial", 18, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        console_title.pack(side="left")
        
        # Indicateur de privilèges
        privilege_text = "Mode Privilégié: ACTIF" if self.root_mode else "Mode Privilégié: INACTIF"
        privilege_color = COLORS["nord14"] if self.root_mode else COLORS["nord11"]
        
        privilege_label = tk.Label(
            console_title_frame,
            text=privilege_text,
            font=("Arial", 12, "bold"),
            bg=COLORS["nord1"],
            fg=privilege_color
        )
        privilege_label.pack(side="right")
        
        self.console = scrolledtext.ScrolledText(
            console_frame, 
            bg=COLORS["nord0"], 
            fg=COLORS["nord6"],
            font=("Consolas", 11),
            wrap=tk.WORD
        )
        self.console.pack(fill="both", expand=True)
        
        # Barre de progression
        self.create_progress_bar(right_frame)
        
        # Message d'accueil
        self.console.insert(tk.END, f"Console prête - {privilege_text}\n\n")
        self.console.config(state=tk.DISABLED)
        
        # Sélection initiale
        self.update_selection()
    
    def create_progress_bar(self, parent):
        """Crée la barre de progression simplifiée"""
        self.progress_frame = tk.Frame(parent, bg=COLORS["nord1"], padx=20, pady=20)
        self.progress_frame.pack(fill="x", side="bottom")
        
        # Canvas pour la barre de progression
        self.progress_canvas = tk.Canvas(
            self.progress_frame,
            height=30,
            bg=COLORS["nord0"],
            highlightthickness=0
        )
        self.progress_canvas.pack(fill="x")
        
        # Masquer initialement
        self.progress_frame.pack_forget()
    
    def create_service_item(self, parent, service):
        """Crée un élément de service"""
        frame = tk.Frame(
            parent,
            bg=COLORS["nord1"],
            highlightthickness=3,
            padx=15,
            pady=15
        )
        frame.pack(fill="x", pady=10)
        
        frame.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
        # Nom du service
        label = tk.Label(
            frame, 
            text=service["name"],
            font=("Arial", 14, "bold"),
            bg=COLORS["nord1"],
            fg=COLORS["nord6"]
        )
        label.pack(side="left", fill="both", expand=True)
        label.bind("<Button-1>", lambda e, s=service: self.select_service(s))
        
        # Indicateur de statut
        status_color = COLORS["nord14"] if service["status"] == "active" else COLORS["nord11"]
        indicator = tk.Canvas(frame, width=20, height=20, bg=COLORS["nord1"], highlightthickness=0)
        indicator.pack(side="right", padx=10)
        indicator.create_oval(2, 2, 18, 18, fill=status_color, outline="")
        
        service["frame"] = frame
        service["indicator"] = indicator
    
    def create_action_buttons(self, parent):
        """Crée les boutons d'action"""
        button_style = {
            "font": ("Arial", 16, "bold"),
            "width": 20,
            "height": 2,
            "borderwidth": 0,
            "highlightthickness": 0,
            "cursor": "hand2"
        }
        
        # 3 boutons
        actions = [
            {"text": "Installer", "bg": COLORS["nord10"], "action": "install"},
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
            btn.pack(fill="x", pady=8)
    
    def select_service(self, service):
        """Sélectionne un service"""
        self.selected_service = service
        self.update_selection()
        logger.debug(f"Service sélectionné: {service['name']}")
    
    def update_selection(self):
        """Met à jour l'affichage de la sélection"""
        for service in self.services:
            is_selected = service == self.selected_service
            border_color = COLORS["nord8"] if is_selected else COLORS["nord1"]
            service["frame"].config(highlightbackground=border_color, highlightcolor=border_color)
    
    def show_progress_bar(self):
        """Affiche la barre de progression"""
        self.progress_frame.pack(fill="x", side="bottom")
        self.progress_value = 0
        self.update_progress_bar()
    
    def hide_progress_bar(self):
        """Masque la barre de progression"""
        self.progress_frame.pack_forget()
    
    def update_progress_bar(self, value=None):
        """Met à jour la barre de progression"""
        if value is not None:
            self.progress_value = value
        
        # Calculer les dimensions
        self.progress_canvas.update_idletasks()
        width = self.progress_canvas.winfo_width() - 20
        height = 20
        
        # Effacer et redessiner
        self.progress_canvas.delete("all")
        
        # Fond
        self.progress_canvas.create_rectangle(
            10, 5, width + 10, height + 5,
            fill=COLORS["nord3"], outline=""
        )
        
        # Barre de progression
        if self.progress_value > 0:
            filled_width = int(width * self.progress_value / self.progress_max)
            self.progress_canvas.create_rectangle(
                10, 5, filled_width + 10, height + 5,
                fill=COLORS["nord8"], outline=""
            )
        
        # Pourcentage au centre
        percentage = int(self.progress_value * 100 / self.progress_max)
        self.progress_canvas.create_text(
            width / 2 + 10, height / 2 + 5,
            text=f"{percentage}%",
            fill=COLORS["nord6"],
            font=("Arial", 10, "bold")
        )
    
    def run_action(self, action):
        """Exécute une action sur le service sélectionné"""
        if not self.selected_service:
            return
        
        logger.info(f"Exécution action: {action} sur {self.selected_service['name']}")
        
        # Vérifier les privilèges
        if not self.root_mode:
            logger.warning("Tentative d'exécution sans privilèges root")
            messagebox.showerror(
                "Privilèges insuffisants",
                "Cette interface doit être lancée avec sudo.\n\n"
                "Relancez avec : sudo bash config.sh"
            )
            return
        
        service = self.selected_service
        service_id = service["id"]
        
        # Confirmation pour désinstallation
        if action == "uninstall":
            dialog = StyledConfirmDialog(
                self.root,
                "Confirmation",
                f"Désinstaller {service['name']} ?\n\nCette action est irréversible."
            )
            if not dialog.show():
                logger.info("Désinstallation annulée par l'utilisateur")
                return
        
        # Script à exécuter
        script_path = f"scripts/{action}/{service_id}_{action}.sh"
        full_script_path = os.path.join(self.base_path, script_path)
        
        # Note spéciale pour "Tester"
        if action == "test":
            self.update_console(f"Note: Le test peut aussi démarrer le service si nécessaire.\n\n")
        
        # Afficher l'action
        self.update_console(f"""{"="*70}
ACTION: {service['name']} - {action.upper()}
{"="*70}
Script: {script_path}

""")
        
        logger.info(f"Exécution du script: {full_script_path}")
        self.show_progress_bar()
        
        # Exécuter en arrière-plan
        self.current_thread = threading.Thread(
            target=self.execute_script, 
            args=(full_script_path, service, action), 
            daemon=True
        )
        self.current_thread.start()
    
    def execute_script(self, script_path, service, action):
        """Exécute un script bash"""
        try:
            if not os.path.exists(script_path):
                self.update_console(f"ERREUR: Script non trouvé: {script_path}\n")
                logger.error(f"Script non trouvé: {script_path}")
                self.hide_progress_bar()
                return
            
            logger.info(f"Démarrage du processus: {script_path}")
            
            # Exécuter le script
            self.current_process = subprocess.Popen(
                ["bash", script_path],
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE, 
                text=True, 
                bufsize=1
            )
            
            # Lire la sortie en temps réel
            for line in iter(self.current_process.stdout.readline, ''):
                if line:
                    # Détecter les mises à jour de progression
                    if "PROGRESS:" in line:
                        progress_match = re.search(r'PROGRESS:(\d+):(.+)', line)
                        if progress_match:
                            progress_value = int(progress_match.group(1))
                            self.root.after(0, self.update_progress_bar, progress_value)
                    else:
                        self.update_console(line)
            
            # Erreurs
            for line in iter(self.current_process.stderr.readline, ''):
                if line:
                    self.update_console(line, error=True)
            
            # Attendre la fin
            return_code = self.current_process.wait()
            logger.info(f"Script terminé avec code: {return_code}")
            
            # Masquer la progression
            self.root.after(0, self.hide_progress_bar)
            
            # Message de fin
            self.update_console(f"""
{"="*70}
TERMINÉ: {service['name']} - {action.upper()}
Code de sortie: {return_code}
{"="*70}

""")
            
            # Mettre à jour le statut si succès
            if return_code == 0:
                if action in ["install", "test"]:
                    service["status"] = "active"
                    self.update_status_indicator(service, True)
                    logger.info(f"Service {service['name']} activé")
                elif action == "uninstall":
                    service["status"] = "inactive"
                    self.update_status_indicator(service, False)
                    logger.info(f"Service {service['name']} désactivé")
            
        except Exception as e:
            logger.error(f"Erreur lors de l'exécution: {str(e)}")
            self.update_console(f"ERREUR: {str(e)}\n", error=True)
            self.root.after(0, self.hide_progress_bar)
        finally:
            self.current_process = None
            self.current_thread = None
    
    def update_status_indicator(self, service, is_active):
        """Met à jour l'indicateur de statut"""
        if "indicator" in service:
            status_color = COLORS["nord14"] if is_active else COLORS["nord11"]
            service["indicator"].delete("all")
            service["indicator"].create_oval(2, 2, 18, 18, fill=status_color, outline="")
    
    def update_console(self, text, error=False):
        """Met à jour la console de manière thread-safe"""
        self.root.after(0, self._update_console, text, error)
    
    def _update_console(self, text, error):
        """Met à jour la console (appelé dans le thread principal)"""
        self.console.config(state=tk.NORMAL)
        
        if error:
            self.console.tag_configure("error", foreground=COLORS["nord11"])
            self.console.insert(tk.END, text, "error")
        else:
            self.console.insert(tk.END, text)
        
        self.console.see(tk.END)
        self.console.config(state=tk.DISABLED)

# ===============================================================================
# POINT D'ENTRÉE
# ===============================================================================

if __name__ == "__main__":
    # Log de démarrage
    log_startup()
    
    # Valider la configuration
    base_path = os.path.dirname(os.path.abspath(__file__))
    
    try:
        variables = VariablesManager(base_path)
        logger.info("Variables chargées avec succès")
    except Exception as e:
        logger.error(f"Erreur fatale: {e}")
        print(f"\nERREUR: {e}")
        print("Vérifiez le fichier scripts/common/variables.sh")
        sys.exit(1)
    
    # Créer l'interface
    try:
        root = tk.Tk()
        app = MaxLinkApp(root, variables)
        logger.info("Interface créée avec succès")
        root.mainloop()
    except Exception as e:
        logger.error(f"Erreur lors du démarrage de l'interface: {e}")
        print(f"\nErreur lors du démarrage: {e}")
        sys.exit(2)
    finally:
        # Footer de fin dans le log
        with open(log_file, 'a') as f:
            f.write("\n")
            f.write("="*80 + "\n")
            f.write(f"FIN: {script_name}\n")
            f.write(f"Date: {datetime.now().strftime('%c')}\n")
            f.write("="*80 + "\n")
            f.write("\n")
        logger.info("Interface fermée")