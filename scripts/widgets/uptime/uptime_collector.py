#!/usr/bin/env python3
"""
Collecteur passif pour le widget Uptime
Ce widget utilise les données publiées par servermonitoring
"""

import sys
import time
import logging

# Ce widget n'a pas de collecteur actif
# Il lit les données du topic rpi/system/uptime publié par servermonitoring

if __name__ == "__main__":
    logging.info("Widget Uptime est passif - pas de collecteur actif")
    # Le service va s'arrêter immédiatement
    sys.exit(0)