#!/bin/bash

#####################################################################
# AUTOMATISCHES BACKUP-SCRIPT MIT FSARCHIVER UND VERSIONIERUNG
#####################################################################
# Dieses Script erstellt automatisierte Backups von Dateisystemen
# mit fsarchiver und unterstützt:
# - UUID-basierte Erkennung von lokalen Backup-Laufwerken
# - Netzwerk-Laufwerke (SMB/CIFS, NFS) über Netzwerk-Pfad-Erkennung
# - Intelligente Auswahl des optimalen Backup-Laufwerks
# - Automatische Versionierung mit konfigurierbarer Anzahl zu behaltender Versionen
# - Verschlüsselte Archive (optional)
# - E-Mail-Benachrichtigungen mit konfigurierbaren Nachrichten
# - Ausschluss bestimmter Pfade vom Backup
# - ZSTD-Kompression mit konfigurierbarem Level
# - Backup-Validierung (Dateigrösse und Existenz)
# - Schutz vor Backup auf das gleiche Laufwerk wie die Quelle
# - Umgang mit temporären fsarchiver Mount-Points
# - SSMTP-Konfigurationsprüfung
# - Korrekte Behandlung von Unterbrechungen (CTRL+C, SIGTERM, etc.)
#####################################################################

#####################################################################
# BENUTZER-KONFIGURATION
#####################################################################

# Backup-Parameter Konfiguration
# Format: BACKUP_PARAMETERS["Backup Name"]="Backup-Datei-Basis-Name:Mount-Point oder Gerätepfad für Backup"
# WICHTIG: Der Backup-Datei-Name ist nur der Basis-Name. Das Script fügt automatisch
# einen Zeitstempel hinzu für die Versionierung (z.B. backup-efi-20250625-123456.fsa)
declare -A BACKUP_PARAMETERS
BACKUP_PARAMETERS["EFI"]="backup-efi:/boot/efi"
BACKUP_PARAMETERS["System"]="backup-root:/"

# BACKUP_PARAMETERS["DATA"]="backup-data:/media/username/DATA"  # Beispiel - auskommentiert

# UUID-Array für lokale Backup-Laufwerke und Netzwerk-Pfade für Netzwerk-Laufwerke
# 
# LOKALE LAUFWERKE:
# Fügen Sie hier die UUIDs Ihrer lokalen Backup-Laufwerke hinzu
# Um die UUID eines Laufwerks zu finden, verwenden Sie den Befehl:
# lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT
#
# NETZWERK-LAUFWERKE:
# Fügen Sie hier die Netzwerk-Pfade Ihrer gemounteten Netzwerk-Laufwerke hinzu
# Format für SMB/CIFS: "//server/share" oder "//ip-adresse/share"
# Format für NFS: "server:/path" oder "ip-adresse:/path"
# 
# Das Script erkennt automatisch ob es sich um ein lokales Laufwerk (UUID) oder
# ein Netzwerk-Laufwerk (enthält Schrägstriche) handelt.
#
# WICHTIG FÜR NETZWERK-LAUFWERKE:
# - Das Netzwerk-Laufwerk muss bereits gemountet sein bevor das Script ausgeführt wird
# - Das Script prüft ob das Netzwerk-Laufwerk verfügbar und beschreibbar ist
# - Verwenden Sie den exakten Pfad wie er von findmnt angezeigt wird
BACKUP_DRIVE_UUIDS=(
    "12345678-1234-1234-1234-123456789abc"     # Local USB drive (UUID) - REPLACE WITH YOUR UUID
    "//your-server.local/backup"               # SMB network drive - REPLACE WITH YOUR PATH
    # "192.168.1.100:/mnt/backup"              # NFS network drive example - UNCOMMENT AND EDIT
)

# Versionierung Konfiguration
# Anzahl der zu behaltenden Backup-Versionen pro Backup-Typ
# Das Script erstellt zeitgestempelte Backups (z.B. backup-efi-20250625-123456.fsa)
# und behält die neuesten X Versionen. Ältere Versionen werden automatisch gelöscht.
# 
# AUSWAHL DES BACKUP-LAUFWERKS BEI MEHREREN VERFÜGBAREN LAUFWERKEN:
# Das Script vergleicht das jeweils neueste Backup jeden Typs auf allen verfügbaren
# Laufwerken (lokal und Netzwerk) und wählt das Laufwerk aus, dessen neustes Backup 
# am ältesten ist. Dies stellt sicher, dass das Laufwerk verwendet wird, das am 
# dringendsten ein Update benötigt.
VERSIONS_TO_KEEP=1

# Backup-Log-Datei Speicherort
BACKUP_LOG="/var/log/fsarchiver-bkp.log"

# Passwort-Datei Speicherort (OPTIONAL)
# Zur Erhöhung der Sicherheit sollte diese Datei auf einem verschlüsselten Volume 
# mit nur-Root-Zugriff gespeichert werden
# Kommentieren Sie diese Zeile aus, um Backups ohne Verschlüsselung zu erstellen
# PASSWORD_FILE="/root/backup-password.txt"

# E-Mail-Konfiguration für Benachrichtigungen
# Setzen Sie den Benutzer für den E-Mail-Versand. Das Script verwendet ssmtp.
# Denken Sie daran, /etc/ssmtp/ssmtp.conf zu bearbeiten und folgende Optionen zu setzen:
## mailhub=ihr-mailserver.tld:587
## hostname=ihr-gewünschter-hostname
## FromLineOverride=YES                    ### Wichtig, damit das Script den korrekten Absendernamen setzen kann
## UseSTARTTLS=YES                         ### Standard für Mail-Versand über Port 587
## UseTLS=NO
## AuthUser=ihr-benutzername@ihre-domain.tld
## AuthPass=ihr-email-account-passwort
MAIL_FROM="backup-system <backup@your-domain.tld>"
MAIL_TO="admin@your-domain.tld"
MAIL_SUBJECT_ERROR="[FEHLER] Fehler bei der Datensicherung von $(hostname)"
MAIL_SUBJECT_SUCCESS="[ERFOLG] Datensicherung von $(hostname) erfolgreich abgeschlossen"
MAIL_SUBJECT_INTERRUPTED="[ABBRUCH] Datensicherung von $(hostname) wurde unterbrochen"

# E-Mail-Inhalt Konfiguration
# Verfügbare Platzhalter: {BACKUP_DATE}, {RUNTIME_MIN}, {RUNTIME_SEC}, {ERROR_DETAILS}
MAIL_BODY_SUCCESS="Datensicherung erfolgreich abgeschlossen am: {BACKUP_DATE}\nLaufzeit: {RUNTIME_MIN} Minuten und {RUNTIME_SEC} Sekunden."
MAIL_BODY_ERROR="Datensicherung fehlgeschlagen!\n\nBackup-Start: {BACKUP_DATE}\nLaufzeit: {RUNTIME_MIN} Minuten und {RUNTIME_SEC} Sekunden.\n\nFEHLERBERICHT:\n{ERROR_DETAILS}"
MAIL_BODY_INTERRUPTED="Datensicherung wurde unterbrochen!\n\nBackup-Start: {BACKUP_DATE}\nUnterbrochen nach: {RUNTIME_MIN} Minuten und {RUNTIME_SEC} Sekunden.\n\nDie Datensicherung wurde durch Benutzereingriff (CTRL+C) oder Systemsignal beendet.\nUnvollständige Backup-Dateien wurden entfernt."

# Pfade die vom Backup ausgeschlossen werden sollen
# 
# WICHTIG: WIE FSARCHIVER AUSSCHLÜSSE FUNKTIONIEREN:
# =====================================================
# 
# fsarchiver verwendet Shell-Wildcards (Glob-Patterns) für Ausschlüsse.
# Die Patterns werden gegen den VOLLSTÄNDIGEN PFAD vom ROOT des gesicherten Dateisystems verglichen.
# 
# CASE-SENSITIVITY (GROSS-/KLEINSCHREIBUNG):
# ==========================================
# Die Patterns sind CASE-SENSITIVE (unterscheiden Gross-/Kleinschreibung)!
# - "*/cache/*" findet NICHT "*/Cache/*" oder "*/CACHE/*"
# - Für beide Varianten: "*/[Cc]ache/*" oder separate Patterns verwenden
# - Häufige Varianten: cache/Cache, temp/Temp, tmp/Tmp, log/Log
# 
# BEISPIELE:
# ---------
# Für einen Pfad wie: /home/user/.var/app/com.adobe.Reader/cache/fontconfig/file.txt
# 
# ✗ FALSCH: "/cache/*"           - Matcht NICHT, da /cache nicht am Root liegt
# ✗ FALSCH: "cache/*"            - Matcht NICHT, da es nicht den vollständigen Pfad abdeckt  
# ✓ RICHTIG: "*/cache/*"         - Matcht JEDE cache-Directory auf jeder Ebene
# ✓ RICHTIG: "/home/*/cache/*"   - Matcht cache-Directories in jedem Benutzerverzeichnis
# ✓ RICHTIG: "*/.var/*/cache/*"  - Matcht spezielle .var-Anwendungscaches
# ✓ RICHTIG: "*[Cc]ache*"        - Matcht sowohl "cache" als auch "Cache"
# 
# WEITERE PATTERN-BEISPIELE:
# -------------------------
# "*.tmp"              - Alle .tmp Dateien
# "/tmp/*"             - Alles im /tmp Verzeichnis
# "*/logs/*"           - Alle logs-Verzeichnisse auf jeder Ebene
# "/var/log/*"         - Alles in /var/log
# "*/.cache/*"         - Alle .cache-Verzeichnisse (häufig in Benutzerverzeichnissen)
# "*/Trash/*"          - Papierkorb-Verzeichnisse
# "*~"                 - Backup-Dateien (mit ~ am Ende)
# "*/tmp/*"            - Alle tmp-Verzeichnisse
# "*/.thumbnails/*"    - Thumbnail-Caches
# 
# PERFORMANCE-TIPP:
# -----------------
# Spezifische Patterns sind effizienter als sehr allgemeine Patterns.
# Verwenden Sie "*/cache/*" statt "*cache*" wenn möglich.
# Allgemeine Patterns vor spezifischen Patterns verwenden.
#
# KONSOLIDIERTE LINUX-AUSSCHLUSS-LISTE:
# =====================================
EXCLUDE_PATHS=(
    # ===========================================
    # CACHE-VERZEICHNISSE (ALLE VARIANTEN)
    # ===========================================
    
    # Allgemeine Cache-Verzeichnisse (deckt die meisten Browser und Apps ab)
    "*/cache/*"                     # Alle cache-Verzeichnisse (Kleinschreibung)
    "*/Cache/*"                     # Alle Cache-Verzeichnisse (Grossschreibung)  
    "*/.cache/*"                    # Versteckte Cache-Verzeichnisse (Linux-Standard)
    "*/.Cache/*"                    # Versteckte Cache-Verzeichnisse (Grossschreibung)
    "*/caches/*"                    # Plural-Form cache-Verzeichnisse
    "*/Caches/*"                    # Plural-Form Cache-Verzeichnisse (Grossschreibung)
    "*/cache2/*"                    # Browser Cache2-Verzeichnisse (Firefox, etc.)
    
    # Spezifische Cache-Verzeichnisse (robustere Patterns)
    "/root/.cache/*"                # Root-Benutzer Cache (spezifisch)
    "/home/*/.cache/*"              # Alle Benutzer-Cache-Verzeichnisse (spezifisch)
    "*/mesa_shader_cache/*"         # Mesa GPU Shader Cache
    
    # Spezielle Cache-Typen
    "*/.thumbnails/*"               # Thumbnail-Caches
    "*/thumbnails/*"                # Thumbnail-Caches (ohne Punkt)
    "*/GrShaderCache/*"             # Graphics Shader Cache (Browser/Games)
    "*/GPUCache/*"                  # GPU-Cache (Browser)
    "*/ShaderCache/*"               # Shader-Cache (Games/Graphics)
    "*/Code\ Cache/*"               # Code Cache (Chrome/Chromium/Electron Apps)
    
    # ===========================================
    # TEMPORÄRE VERZEICHNISSE UND DATEIEN
    # ===========================================
    
    # Standard temporäre Verzeichnisse
    "/tmp/*"                        # Temporäre Dateien
    "/var/tmp/*"                    # Variable temporäre Dateien
    "*/tmp/*"                       # Alle tmp-Verzeichnisse
    "*/Tmp/*"                       # Alle Tmp-Verzeichnisse (Grossschreibung)
    "*/temp/*"                      # Alle temp-Verzeichnisse
    "*/Temp/*"                      # Alle Temp-Verzeichnisse (Grossschreibung)
    "*/TEMP/*"                      # Alle TEMP-Verzeichnisse (Grossschreibung)
    "*/.temp/*"                     # Versteckte temp-Verzeichnisse
    "*/.Temp/*"                     # Versteckte Temp-Verzeichnisse (Grossschreibung)
    
    # Browser-spezifische temporäre Verzeichnisse
    "*/Greaselion/Temp/*"           # Brave Browser Greaselion Temp-Verzeichnisse
    "*/BraveSoftware/*/Cache/*"     # Brave Browser Cache
    "*/BraveSoftware/*/cache/*"     # Brave Browser cache (Kleinschreibung)
    
    # Temporäre Dateien
    "*.tmp"                         # Temporäre Dateien
    "*.temp"                        # Temporäre Dateien
    "*.TMP"                         # Temporäre Dateien (Grossschreibung)
    "*.TEMP"                        # Temporäre Dateien (Grossschreibung)
    
    # ===========================================
    # LOG-VERZEICHNISSE UND DATEIEN
    # ===========================================
    
    # System-Logs
    "/var/log/*"                    # System-Log-Dateien (allgemein)
    "/var/log/journal/*"            # SystemD Journal Logs (können sehr gross werden)
    "*/logs/*"                      # Alle log-Verzeichnisse
    "*/Logs/*"                      # Alle Log-Verzeichnisse (Grossschreibung)
    
    # Log-Dateien
    "*.log"                         # Log-Dateien
    "*.log.*"                       # Rotierte Log-Dateien
    "*.LOG"                         # Log-Dateien (Grossschreibung)
    "*/.xsession-errors*"           # X-Session-Logs
    "*/.wayland-errors*"            # Wayland-Session-Logs
    
    # ===========================================
    # SYSTEM-CACHE UND SPOOL
    # ===========================================
    
    # HINWEIS: Alle /var/cache/* Patterns sind durch */cache/* abgedeckt
    "/var/spool/*"                  # Spool-Verzeichnisse (Druckjobs, etc.)
    
    # ===========================================
    # MOUNT-POINTS UND VIRTUELLE DATEISYSTEME
    # ===========================================
    
    # Externe Laufwerke und Mount-Points
    "/media/*"                      # Externe Laufwerke
    "/mnt/*"                        # Mount-Points
    "/run/media/*"                  # Moderne Mount-Points
    
    # Virtuelle Dateisysteme (sollten nicht in Backups)
    "/proc/*"                       # Prozess-Informationen
    "/sys/*"                        # System-Informationen  
    "/dev/*"                        # Geräte-Dateien
    "/run/*"                        # Laufzeit-Informationen
    "/var/run/*"                    # Runtime Variable Files (meist symlink zu /run)
    "/var/lock/*"                   # Lock Files (meist symlink zu /run/lock)
    
    # ===========================================
    # ENTWICKLUNG UND BUILD-VERZEICHNISSE
    # ===========================================
    
    # Node.js und JavaScript
    "*/node_modules/*"              # Node.js-Pakete
    "*/.npm/*"                      # NPM-Cache
    "*/.yarn/*"                     # Yarn-Cache
    
    # Rust
    "*/target/debug/*"              # Rust Debug Builds
    "*/target/release/*"            # Rust Release Builds
    "*/.cargo/registry/*"           # Rust Cargo Registry Cache
    
    # Go
    "*/.go/pkg/*"                   # Go Package Cache
    
    # Build-Verzeichnisse (allgemein)
    "*/target/*"                    # Rust/Java-Build-Verzeichnisse (allgemein)
    "*/build/*"                     # Build-Verzeichnisse
    "*/Build/*"                     # Build-Verzeichnisse (Grossschreibung)
    "*/.gradle/*"                   # Gradle-Cache
    "*/.m2/repository/*"            # Maven-Repository
    
    # Python
    "*/__pycache__/*"               # Python-Cache
    "*/.pytest_cache/*"             # Pytest-Cache
    "*.pyc"                         # Python-Compiled-Dateien
    
    # ===========================================
    # CONTAINER UND VIRTUALISIERUNG
    # ===========================================
    
    "/var/lib/docker/*"             # Docker-Daten
    "/var/lib/containers/*"         # Podman/Container-Daten
    
    # ===========================================
    # FLATPAK UND SNAP CACHE-VERZEICHNISSE
    # ===========================================
    
    # Flatpak Repository und Cache (sicher ausschliessbar - können neu heruntergeladen werden)
    "/var/lib/flatpak/repo/*"       # OSTree Repository Objects (wie Git Objects)
    "/var/lib/flatpak/.refs/*"      # OSTree References
    "/var/lib/flatpak/system-cache/*" # System Cache
    "/var/lib/flatpak/user-cache/*" # User Cache
    
    # Flatpak App-spezifische Caches (Benutzer-Verzeichnisse)
    "/home/*/.var/app/*/cache/*"    # App-spezifische Caches
    "/home/*/.var/app/*/Cache/*"    # App-spezifische Caches (Grossschreibung)
    "/home/*/.var/app/*/.cache/*"   # Versteckte Caches in Apps
    "*/.var/app/*/cache/*"          # Alle Flatpak App-Caches
    "*/.var/app/*/Cache/*"          # Alle Flatpak App-Caches (Grossschreibung)
    
    # Snap Cache-Verzeichnisse
    "/var/lib/snapd/cache/*"        # Snap Cache
    "/home/*/snap/*/common/.cache/*" # Snap App-Caches
    
    # OPTIONAL - Wenn Sie Flatpak Apps nicht neu installieren möchten, 
    # kommentieren Sie diese Zeilen aus:
    # "/var/lib/flatpak/runtime/*"  # Runtime-Umgebungen (können neu installiert werden)
    # "/var/lib/flatpak/app/*"      # Installierte Apps (können neu installiert werden)
    
    # ===========================================
    # BACKUP- UND ALTE DATEIEN
    # ===========================================
    
    # Backup-Dateien
    "*~"                            # Backup-Dateien (Editor-Backups - immer ausschliessen)
    
    # Backup-Dateien (OPTIONAL - auskommentieren wenn Backup-Dateien behalten werden sollen)
    # "*.bak"                       # Backup-Dateien
    # "*.BAK"                       # Backup-Dateien (Grossschreibung)
    # "*.backup"                    # Backup-Dateien
    # "*.BACKUP"                    # Backup-Dateien (Grossschreibung)
    # "*.old"                       # Alte Dateien
    # "*.OLD"                       # Alte Dateien (Grossschreibung)
    
    # ===========================================
    # PAPIERKORB (OPTIONAL - auskommentiert, da Papierkorb standardmässig gesichert werden soll)
    # ===========================================
    
    # HINWEIS: Papierkorb-Verzeichnisse sind standardmässig NICHT ausgeschlossen,
    # da sie wichtige gelöschte Dateien enthalten können, die wiederhergestellt werden müssen.
    # Entkommentieren Sie diese Zeilen nur wenn Sie sicher sind, dass der Papierkorb 
    # nicht gesichert werden soll:
    
    # "*/.Trash/*"                  # Papierkorb
    # "*/Trash/*"                   # Papierkorb (ohne Punkt)
    # "*/.local/share/Trash/*"      # Papierkorb (moderne Linux-Location)
    # "*/RecycleBin/*"              # Windows-Style Papierkorb (falls vorhanden)
    
    # ===========================================
    # SWAP-DATEIEN
    # ===========================================
    
    "/swapfile"                     # Standard-Swap-Datei
    "/swap.img"                     # Alternative Swap-Datei
    "*.swap"                        # Swap-Dateien
    "*.SWAP"                        # Swap-Dateien (Grossschreibung)
    
    # ===========================================
    # SONSTIGE HÄUFIGE AUSSCHLÜSSE
    # ===========================================
    
    # Sonstige häufige Ausschlüsse
    # HINWEIS: Spezifische Flatpak/Snap-Cache-Patterns sind redundant, da bereits durch 
    # */cache/* und */.cache/* abgedeckt
    
    # Lock- und Socket-Dateien
    "*/.X11-unix/*"                 # X11-Sockets
    "*/lost+found/*"                # Lost+Found-Verzeichnisse
    "*/.gvfs/*"                     # GVFS-Mount-Points
    
    # Multimedia-Caches
    "*/.dvdcss/*"                   # DVD-CSS-Cache
    "*/.mplayer/*"                  # MPlayer-Cache
    "*/.adobe/Flash_Player/*"       # Flash-Player-Cache
    
    # Verschlüsselte Verzeichnisse wenn unmounted
    "*/.ecryptfs/*"                 # eCryptFS
    
    # ===========================================
    # GROssE IMAGE-DATEIEN (OPTIONAL - auskommentiert da sie sehr gross sein können)
    # ===========================================
    
    # HINWEIS: Diese Patterns sind auskommentiert, da Image-Dateien oft wichtige
    # Daten enthalten können. Entkommentieren Sie diese nur wenn Sie sicher sind,
    # dass diese Dateien nicht gesichert werden sollen:
    
    # "*.iso"                       # ISO Image Files 
    # "*.img"                       # Disk Image Files
    # "*.vdi"                       # VirtualBox Images (können sehr gross sein)
    # "*.vmdk"                      # VMware Images (können sehr gross sein)
    
    # Games und Steam (spezifische Caches/Logs die nicht durch */cache/* abgedeckt werden)
    "*/.steam/steam/logs/*"         # Steam-Logs
    "*/.steam/steam/dumps/*"        # Steam-Crash-Dumps
    "*/.local/share/Steam/logs/*"   # Steam-Logs (alternative Location)
)

# ZSTD-Komprimierungslevel (0-22)
# 0 = keine Komprimierung, 1 = schnellste/schlechteste Komprimierung, 22 = langsamste/beste Komprimierung
# Standard ist 3. Werte über 19 gelten als "Ultra"-Einstellungen und sollten vorsichtig verwendet werden.
ZSTD_COMPRESSION_VALUE=5

#####################################################################
# SYSTEM-FUNKTIONEN UND HILFSFUNKTIONEN
#####################################################################

# Farbcodes für formatierte Ausgabe
RED='\033[1;31;43m'     # Fetter roter Text auf gelbem Hintergrund für maximale Sichtbarkeit von Fehlern
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Globale Variablen für Fehlerbehandlung und Signal-Behandlung
ERROR=0
ERROR_MSG=""
SCRIPT_INTERRUPTED=false
CURRENT_BACKUP_FILE=""
CURRENT_FSARCHIVER_PID=""

# Prüfung ob das Script als root ausgeführt wird
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Das Script muss als root ausgeführt werden. Beende...${NC}"
   exit 1
fi

#####################################################################
# SIGNAL-BEHANDLUNG UND AUFRÄUMFUNKTIONEN
#####################################################################

# Funktion zum Aufräumen bei Unterbrechung
cleanup_on_interrupt() {
    echo -e "\n${YELLOW}Backup-Unterbrechung erkannt...${NC}"
    SCRIPT_INTERRUPTED=true
    ERROR=1
    ERROR_MSG+="Backup wurde durch Benutzereingriff oder Systemsignal unterbrochen.\n"
    
    # Versuche fsarchiver-Prozess zu beenden, falls noch aktiv
    if [[ -n "$CURRENT_FSARCHIVER_PID" ]]; then
        echo -e "${YELLOW}Beende fsarchiver-Prozess (PID: $CURRENT_FSARCHIVER_PID)...${NC}"
        kill -TERM "$CURRENT_FSARCHIVER_PID" 2>/dev/null
        sleep 2
        # Falls der Prozess immer noch läuft, force kill
        if kill -0 "$CURRENT_FSARCHIVER_PID" 2>/dev/null; then
            echo -e "${YELLOW}Erzwinge Beendigung von fsarchiver-Prozess...${NC}"
            kill -KILL "$CURRENT_FSARCHIVER_PID" 2>/dev/null
        fi
        CURRENT_FSARCHIVER_PID=""
    fi
    
    # Entferne unvollständige Backup-Datei
    if [[ -n "$CURRENT_BACKUP_FILE" && -f "$CURRENT_BACKUP_FILE" ]]; then
        echo -e "${YELLOW}Entferne unvollständige Backup-Datei: $(basename "$CURRENT_BACKUP_FILE")${NC}"
        rm -f "$CURRENT_BACKUP_FILE"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Unvollständige Backup-Datei entfernt${NC}"
        else
            echo -e "${RED}✗ Fehler beim Entfernen der unvollständigen Backup-Datei${NC}"
            ERROR_MSG+="Fehler beim Entfernen der unvollständigen Backup-Datei: $CURRENT_BACKUP_FILE\n"
        fi
        CURRENT_BACKUP_FILE=""
    fi
    
    # Bereinige fsarchiver Mount-Points bei Unterbrechung
    echo -e "${YELLOW}Bereinige fsarchiver Mount-Points nach Unterbrechung...${NC}"
    cleanup_fsarchiver_mounts true
    
    # Log-Eintrag für Unterbrechung
    if [[ -n "$BACKUP_LOG" ]]; then
        echo "Backup unterbrochen: $(date +%d.%B.%Y,%T)" >> "$BACKUP_LOG"
    fi
    
    echo -e "${YELLOW}Aufräumen abgeschlossen. Script wird beendet.${NC}"
}

# Funktion zum Senden der Abbruch-E-Mail und Beenden
send_interrupted_mail_and_exit() {
    # Laufzeit berechnen
    if [[ -n "$TIME_START" ]]; then
        TIME_DIFF=$(($(date +"%s")-${TIME_START}))
        RUNTIME_MINUTES=$((${TIME_DIFF} / 60))
        RUNTIME_SECONDS=$((${TIME_DIFF} % 60))
    else
        RUNTIME_MINUTES=0
        RUNTIME_SECONDS=0
    fi
    
    # Abbruch-E-Mail senden
    local mail_body="${MAIL_BODY_INTERRUPTED}"
    mail_body="${mail_body//\{BACKUP_DATE\}/${BACKUP_START_DATE:-$(date +%d.%B.%Y,%T)}}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_INTERRUPTED\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t 2>/dev/null
    echo -e "${YELLOW}Abbruch-E-Mail versendet${NC}"
    
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}BACKUP WURDE UNTERBROCHEN${NC}"
    echo -e "${RED}Laufzeit: $RUNTIME_MINUTES Minuten und $RUNTIME_SECONDS Sekunden${NC}"
    echo -e "${RED}========================================${NC}"
    
    exit 130  # Standard Exit-Code für SIGINT
}

# Signal Handler einrichten
# Behandelt SIGINT (Ctrl+C), SIGTERM (Beendigung), und SIGHUP (Terminal closed)
trap 'cleanup_on_interrupt; send_interrupted_mail_and_exit' SIGINT SIGTERM SIGHUP

# Funktion zur Überprüfung der SSMTP-Konfiguration
check_ssmtp_configuration() {
    echo -e "${BLUE}Überprüfe SSMTP-Konfiguration...${NC}"
    
    # Prüfen ob ssmtp installiert ist
    if ! command -v ssmtp &> /dev/null; then
        echo -e "${RED}FEHLER: ssmtp ist nicht installiert!${NC}"
        echo -e "${RED}Installieren Sie ssmtp mit folgendem Befehl:${NC}"
        echo -e "${YELLOW}sudo apt update && sudo apt install ssmtp${NC}"
        echo ""
        return 1
    fi
    
    # Prüfen ob Konfigurationsdatei existiert
    local config_file="/etc/ssmtp/ssmtp.conf"
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}FEHLER: SSMTP-Konfigurationsdatei nicht gefunden: $config_file${NC}"
        echo -e "${RED}Erstellen Sie die Konfigurationsdatei und fügen Sie folgende Einstellungen hinzu:${NC}"
        show_ssmtp_configuration_help
        return 1
    fi
    
    # Prüfen ob wichtige Konfigurationsparameter gesetzt sind
    local required_params=("mailhub" "AuthUser" "AuthPass")
    local missing_params=()
    
    for param in "${required_params[@]}"; do
        if ! grep -q "^$param=" "$config_file" 2>/dev/null; then
            missing_params+=("$param")
        fi
    done
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        echo -e "${RED}FEHLER: Fehlende SSMTP-Konfigurationsparameter in $config_file:${NC}"
        for param in "${missing_params[@]}"; do
            echo -e "${RED}  - $param${NC}"
        done
        echo ""
        echo -e "${RED}Fügen Sie die fehlenden Parameter hinzu:${NC}"
        show_ssmtp_configuration_help
        return 1
    fi
    
    # Prüfen ob Konfigurationsdatei lesbar ist
    if [[ ! -r "$config_file" ]]; then
        echo -e "${RED}FEHLER: SSMTP-Konfigurationsdatei ist nicht lesbar: $config_file${NC}"
        echo -e "${YELLOW}Stellen Sie sicher, dass die Datei die richtigen Berechtigungen hat:${NC}"
        echo -e "${YELLOW}sudo chmod 644 $config_file${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ SSMTP ist installiert und konfiguriert${NC}"
    return 0
}

# Funktion zur Anzeige der SSMTP-Konfigurationshilfe
show_ssmtp_configuration_help() {
    echo -e "${YELLOW}Bearbeiten Sie /etc/ssmtp/ssmtp.conf und setzen Sie folgende Optionen:${NC}"
    echo -e "${YELLOW}mailhub=ihr-mailserver.tld:587${NC}"
    echo -e "${YELLOW}hostname=ihr-gewünschter-hostname${NC}"
    echo -e "${YELLOW}FromLineOverride=YES${NC}"
    echo -e "${YELLOW}UseSTARTTLS=YES${NC}"
    echo -e "${YELLOW}UseTLS=NO${NC}"
    echo -e "${YELLOW}AuthUser=ihr-benutzername@ihre-domain.tld${NC}"
    echo -e "${YELLOW}AuthPass=ihr-email-account-passwort${NC}"
    echo ""
    echo -e "${YELLOW}Beispiel-Befehl zum Bearbeiten:${NC}"
    echo -e "${YELLOW}sudo nano /etc/ssmtp/ssmtp.conf${NC}"
}

# SSMTP-Konfiguration prüfen (Kritisch - Script bricht bei Fehlern ab)
if ! check_ssmtp_configuration; then
    echo -e "${RED}Kritischer Fehler: SSMTP ist nicht ordnungsgemäss installiert oder konfiguriert.${NC}"
    echo -e "${RED}E-Mail-Benachrichtigungen sind für dieses Backup-Script erforderlich.${NC}"
    echo -e "${RED}Script wird beendet.${NC}"
    exit 1
fi

#####################################################################
# FSARCHIVER MOUNT-POINT CLEANUP FUNKTIONEN
#####################################################################

# Funktion zum Finden aller fsarchiver Mount-Points
find_fsarchiver_mounts() {
    # Finde alle Mount-Points unter /tmp/fsa/ (mit -r für raw output ohne tree formatting)
    findmnt -n -r -o TARGET | grep "^/tmp/fsa/" 2>/dev/null | sort -r || true
}

# Funktion zum sauberen Unmounten von fsarchiver Mount-Points
cleanup_fsarchiver_mounts() {
    local force_cleanup="${1:-false}"
    
    echo -e "${BLUE}Suche nach fsarchiver Mount-Points...${NC}"
    
    local temp_mounts
    temp_mounts=$(find_fsarchiver_mounts)
    
    if [[ -z "$temp_mounts" ]]; then
        echo -e "${GREEN}✓ Keine fsarchiver Mount-Points gefunden${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Gefundene fsarchiver Mount-Points:${NC}"
    echo "$temp_mounts" | while read -r mount; do
        if [[ -n "$mount" ]]; then
            echo -e "${YELLOW}  - $mount${NC}"
        fi
    done
    
    if [[ "$force_cleanup" == "true" ]]; then
        echo -e "${BLUE}Automatisches Aufräumen der Mount-Points...${NC}"
        local cleanup_success=true
        
        # Mount-Points in umgekehrter Reihenfolge unmounten (tiefste zuerst)
        while IFS= read -r mount; do
            if [[ -n "$mount" ]]; then
                echo -e "${YELLOW}Unmounte: $mount${NC}"
                
                # Versuche normales umount
                if umount "$mount" 2>/dev/null; then
                    echo -e "${GREEN}  ✓ Erfolgreich unmountet${NC}"
                else
                    # Bei Fehlschlag: lazy umount versuchen
                    echo -e "${YELLOW}  - Normales umount fehlgeschlagen, versuche lazy umount...${NC}"
                    if umount -l "$mount" 2>/dev/null; then
                        echo -e "${GREEN}  ✓ Lazy umount erfolgreich${NC}"
                    else
                        # Bei weiterem Fehlschlag: force umount
                        echo -e "${YELLOW}  - Lazy umount fehlgeschlagen, versuche force umount...${NC}"
                        if umount -f "$mount" 2>/dev/null; then
                            echo -e "${GREEN}  ✓ Force umount erfolgreich${NC}"
                        else
                            echo -e "${RED}  ✗ Alle umount-Versuche fehlgeschlagen für: $mount${NC}"
                            cleanup_success=false
                        fi
                    fi
                fi
            fi
        done <<< "$temp_mounts"
        
        # Prüfe ob alle Mount-Points entfernt wurden
        sleep 1
        local remaining_mounts
        remaining_mounts=$(find_fsarchiver_mounts)
        
        if [[ -z "$remaining_mounts" ]]; then
            echo -e "${GREEN}✓ Alle fsarchiver Mount-Points erfolgreich entfernt${NC}"
            
            # Versuche auch leere /tmp/fsa Verzeichnisse zu entfernen
            if [[ -d "/tmp/fsa" ]]; then
                echo -e "${BLUE}Räume leere /tmp/fsa Verzeichnisse auf...${NC}"
                find /tmp/fsa -type d -empty -delete 2>/dev/null || true
                if [[ ! -d "/tmp/fsa" || -z "$(ls -A /tmp/fsa 2>/dev/null)" ]]; then
                    rmdir /tmp/fsa 2>/dev/null || true
                    echo -e "${GREEN}✓ /tmp/fsa Verzeichnis aufgeräumt${NC}"
                fi
            fi
            
            return 0
        else
            echo -e "${RED}✗ Einige Mount-Points konnten nicht entfernt werden:${NC}"
            echo "$remaining_mounts" | while read -r mount; do
                if [[ -n "$mount" ]]; then
                    echo -e "${RED}  - $mount${NC}"
                fi
            done
            return 1
        fi
    else
        echo -e "${YELLOW}Automatisches Aufräumen nicht aktiviert.${NC}"
        echo -e "${YELLOW}Zum manuellen Aufräumen führen Sie aus:${NC}"
        echo -e "${YELLOW}sudo umount /tmp/fsa/*/media/* 2>/dev/null || true${NC}"
        echo -e "${YELLOW}sudo umount /tmp/fsa/* 2>/dev/null || true${NC}"
        return 1
    fi
}

# Prüfung auf temporäre fsarchiver Mount-Points und automatisches Aufräumen
echo -e "${BLUE}Überprüfe temporäre fsarchiver Mount-Points...${NC}"
if ! cleanup_fsarchiver_mounts true; then
    echo -e "${YELLOW}Warnung: Einige fsarchiver Mount-Points konnten nicht automatisch entfernt werden.${NC}"
    echo -e "${YELLOW}Das kann zu Problemen führen. Bitte prüfen Sie manuell mit:${NC}"
    echo -e "${YELLOW}findmnt | grep /tmp/fsa${NC}"
    echo ""
    
    # Optional: Frage den Benutzer ob er trotzdem fortfahren möchte
    # echo -e "${YELLOW}Möchten Sie trotzdem fortfahren? (y/N): ${NC}"
    # read -r response
    # if [[ ! "$response" =~ ^[Yy]$ ]]; then
    #     echo -e "${RED}Backup abgebrochen.${NC}"
    #     exit 1
    # fi
fi

# Funktion zur Erstellung von zeitgestempelten Backup-Dateinamen
create_timestamped_filename() {
    local base_name="$1"
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    echo "${base_name}-${timestamp}.fsa"
}

# Funktion zum Finden aller Versionen einer Backup-Datei
find_backup_versions() {
    local backup_drive="$1"
    local base_name="$2"
    
    # Suche nach Dateien mit dem Muster: base_name-YYYYMMDD-HHMMSS.fsa
    find "$backup_drive" -maxdepth 1 -name "${base_name}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].fsa" -type f 2>/dev/null | sort -r
}

# Funktion zum Finden der neuesten Version einer Backup-Datei
find_latest_backup_version() {
    local backup_drive="$1"
    local base_name="$2"
    
    find_backup_versions "$backup_drive" "$base_name" | head -n1
}

# Funktion zum Bereinigen alter Backup-Versionen
cleanup_old_backups() {
    local backup_drive="$1"
    local base_name="$2"
    local keep_versions="$3"
    
    echo -e "${BLUE}Bereinige alte Backup-Versionen für $base_name (behalte $keep_versions Versionen)...${NC}"
    
    local versions
    versions=$(find_backup_versions "$backup_drive" "$base_name")
    
    if [[ -z "$versions" ]]; then
        echo -e "${YELLOW}Keine existierenden Backup-Versionen gefunden für $base_name${NC}"
        return 0
    fi
    
    local version_count
    version_count=$(echo "$versions" | wc -l)
    
    if [[ $version_count -le $keep_versions ]]; then
        echo -e "${GREEN}✓ Alle $version_count Versionen werden behalten${NC}"
        return 0
    fi
    
    local versions_to_delete
    versions_to_delete=$(echo "$versions" | tail -n +$((keep_versions + 1)))
    
    echo -e "${YELLOW}Lösche $(echo "$versions_to_delete" | wc -l) alte Versionen:${NC}"
    
    while IFS= read -r old_version; do
        if [[ -n "$old_version" ]]; then
            echo -e "${YELLOW}  - Lösche: $(basename "$old_version")${NC}"
            rm -f "$old_version"
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}    ✓ Erfolgreich gelöscht${NC}"
            else
                echo -e "${RED}    ✗ Fehler beim Löschen${NC}"
                ERROR=1
                ERROR_MSG+="Fehler beim Löschen alter Backup-Version: $old_version\n"
            fi
        fi
    done <<< "$versions_to_delete"
}

show_available_drives() {
    echo -e "${YELLOW}Verfügbare Laufwerke zur Backup-Konfiguration:${NC}"
    echo -e "${BLUE}Verwenden Sie folgenden Befehl um alle lokalen Laufwerke anzuzeigen:${NC}"
    echo "lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT"
    echo ""
    echo -e "${BLUE}Verwenden Sie folgenden Befehl um alle Netzwerk-Laufwerke anzuzeigen:${NC}"
    echo "findmnt -t nfs,nfs4,cifs -o TARGET,SOURCE,FSTYPE,OPTIONS"
    echo ""
    echo -e "${BLUE}Formatierte Ausgabe der verfügbaren lokalen Laufwerke:${NC}"
    
    # Header
    printf "%-36s | %-12s | %-8s | %-8s | %-12s | %-20s | %s\n" "UUID" "LABEL" "NAME" "SIZE GB" "VENDOR" "MODEL" "MOUNTPOINT"
    printf "%s\n" "$(printf '=%.0s' {1..120})"
    
    # Laufwerke auflisten mit formatierter Ausgabe
    while IFS= read -r line; do
        if [[ $line =~ ^[├└│]?─?([a-zA-Z0-9]+)[[:space:]]+([a-f0-9-]*)[[:space:]]*([^[:space:]]*)[[:space:]]*([0-9.,]+[KMGT]?)[[:space:]]*([^[:space:]]*)[[:space:]]*([^[:space:]]*)[[:space:]]*(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            uuid="${BASH_REMATCH[2]}"
            label="${BASH_REMATCH[3]}"
            size="${BASH_REMATCH[4]}"
            vendor="${BASH_REMATCH[5]}"
            model="${BASH_REMATCH[6]}"
            mountpoint="${BASH_REMATCH[7]}"
            
            # Konvertiere Grösse zu GB wenn möglich
            if [[ $size =~ ^([0-9.,]+)([KMGT])$ ]]; then
                num="${BASH_REMATCH[1]//,/.}"
                unit="${BASH_REMATCH[2]}"
                case $unit in
                    K) size_gb=$(echo "scale=1; $num / 1024 / 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    M) size_gb=$(echo "scale=1; $num / 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    G) size_gb="$num" ;;
                    T) size_gb=$(echo "scale=1; $num * 1024" | bc -l 2>/dev/null || echo "$size") ;;
                    *) size_gb="$size" ;;
                esac
            else
                size_gb="$size"
            fi
            
            # Nur Zeilen mit UUID anzeigen (echte Partitionen)
            if [[ -n "$uuid" && "$uuid" != "-" ]]; then
                printf "%-36s | %-12s | %-8s | %-8s | %-12s | %-20s | %s\n" \
                    "$uuid" "$label" "$name" "$size_gb" "$vendor" "$model" "$mountpoint"
            fi
        fi
    done < <(lsblk -o NAME,UUID,LABEL,SIZE,VENDOR,MODEL,MOUNTPOINT 2>/dev/null)
    
    echo ""
    echo -e "${BLUE}Verfügbare Netzwerk-Laufwerke:${NC}"
    findmnt -t nfs,nfs4,cifs -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || echo "Keine Netzwerk-Laufwerke gemountet"
}

# Funktion um Gerätepfad für einen Mount-Point zu ermitteln
get_device_path() {
    local mount_point="$1"
    
    # Prüfen ob findmnt Befehl verfügbar ist
    if ! command -v findmnt &> /dev/null; then
        echo "Fehler: findmnt Befehl nicht gefunden. Dieses Script benötigt findmnt um ordnungsgemäss zu funktionieren." >&2
        echo "Sie können es installieren mit: 'sudo apt update && sudo apt install util-linux'" >&2
        return 1
    fi
    
    findmnt -no SOURCE "$mount_point"
}

# Funktion um Backup-Laufwerk anhand der UUID oder Netzwerk-Pfad zu finden
find_backup_drive_by_uuid() {
    local identifier="$1"
    
    # Prüfen ob es sich um einen Netzwerk-Pfad handelt (enthält Schrägstriche)
    if [[ "$identifier" == *"/"* ]]; then
        # Netzwerk-Laufwerk: Suche nach Mount-Point für den Netzwerk-Pfad
        local mount_point
        mount_point=$(findmnt -n -o TARGET -S "$identifier" 2>/dev/null)
        
        if [[ -n "$mount_point" && -d "$mount_point" ]]; then
            echo "$mount_point"
            return 0
        else
            return 1
        fi
    else
        # Lokales Laufwerk: UUID-basierte Suche (ursprüngliche Logik)
        local device_path=""
        local mount_points=""
        local best_mount_point=""
        
        # Suche nach dem Gerät mit der angegebenen UUID
        device_path=$(blkid -U "$identifier" 2>/dev/null)
        
        if [[ -z "$device_path" ]]; then
            return 1
        fi
        
        # Alle Mount-Points für das Gerät finden
        mount_points=$(findmnt -n -o TARGET "$device_path" 2>/dev/null | tr '\n' ' ')
        
        if [[ -z "$mount_points" ]]; then
            return 1
        fi
        
        # Den besten Mount-Point auswählen (bevorzuge reale Mount-Points über temporäre)
        for mount_point in $mount_points; do
            # Überspringe fsarchiver temporäre Mount-Points
            if [[ "$mount_point" =~ ^/tmp/fsa/ ]]; then
                continue
            fi
            
            # Bevorzuge Mount-Points unter /media/, /mnt/, oder /run/media/
            if [[ "$mount_point" =~ ^(/media/|/mnt/|/run/media/) ]]; then
                best_mount_point="$mount_point"
                break
            fi
            
            # Falls kein bevorzugter Mount-Point gefunden wurde, verwende den ersten nicht-temporären
            if [[ -z "$best_mount_point" ]]; then
                best_mount_point="$mount_point"
            fi
        done
        
        if [[ -n "$best_mount_point" ]]; then
            echo "$best_mount_point"
            return 0
        else
            return 1
        fi
    fi
}

# Funktion um das beste verfügbare Backup-Laufwerk zu finden
find_best_backup_drive() {
    local available_drives=()
    local best_drive=""
    local oldest_newest_backup=999999999999
    
    echo -e "${BLUE}Suche nach konfigurierten Backup-Laufwerken (lokal und Netzwerk)...${NC}" >&2
    
    # Prüfen ob UUID-Array konfiguriert ist
    if [[ ${#BACKUP_DRIVE_UUIDS[@]} -eq 0 ]]; then
        echo -e "${RED}FEHLER: Keine Backup-Laufwerk UUIDs/Netzwerk-Pfade konfiguriert!${NC}" >&2
        echo -e "${YELLOW}Bitte fügen Sie UUIDs oder Netzwerk-Pfade zu BACKUP_DRIVE_UUIDS Array hinzu.${NC}" >&2
        echo "" >&2
        show_available_drives >&2
        return 1
    fi
    
    # Durchsuche alle konfigurierten Identifikatoren (UUIDs und Netzwerk-Pfade)
    for identifier in "${BACKUP_DRIVE_UUIDS[@]}"; do
        if [[ -n "$identifier" && "$identifier" != "#"* ]]; then  # Ignoriere leere und auskommentierte Zeilen
            local mount_path
            mount_path=$(find_backup_drive_by_uuid "$identifier")
            if [[ $? -eq 0 && -n "$mount_path" ]]; then
                available_drives+=("$mount_path")
                if [[ "$identifier" == *"/"* ]]; then
                    echo -e "${GREEN}✓ Netzwerk-Backup-Laufwerk gefunden: $mount_path (Netzwerk-Pfad: $identifier)${NC}" >&2
                else
                    echo -e "${GREEN}✓ Lokales Backup-Laufwerk gefunden: $mount_path (UUID: $identifier)${NC}" >&2
                fi
            fi
        fi
    done
    
    # Prüfen ob Laufwerke gefunden wurden
    if [[ ${#available_drives[@]} -eq 0 ]]; then
        echo -e "${RED}FEHLER: Keine der konfigurierten Backup-Laufwerke sind verfügbar!${NC}" >&2
        echo -e "${YELLOW}Konfigurierte Identifikatoren:${NC}" >&2
        for identifier in "${BACKUP_DRIVE_UUIDS[@]}"; do
            if [[ -n "$identifier" && "$identifier" != "#"* ]]; then
                if [[ "$identifier" == *"/"* ]]; then
                    echo "  - $identifier (Netzwerk-Pfad)" >&2
                else
                    echo "  - $identifier (UUID)" >&2
                fi
            fi
        done
        echo "" >&2
        show_available_drives >&2
        return 1
    fi
    
    # Wenn nur ein Laufwerk verfügbar ist, verwende es
    if [[ ${#available_drives[@]} -eq 1 ]]; then
        printf "%s" "${available_drives[0]}"
        return 0
    fi
    
    # Wenn mehrere Laufwerke verfügbar sind, finde das mit dem ältesten "neuesten" Backup
    echo -e "${YELLOW}Mehrere Backup-Laufwerke verfügbar. Analysiere Backup-Versionen...${NC}" >&2
    
    for drive in "${available_drives[@]}"; do
        local newest_backup_on_drive=0
        
        echo -e "${BLUE}Analysiere Laufwerk: $drive${NC}" >&2
        
        # Prüfe alle konfigurierten Backup-Typen auf diesem Laufwerk
        for backup_name in "${!BACKUP_PARAMETERS[@]}"; do
            IFS=':' read -r backup_base_name source <<< "${BACKUP_PARAMETERS[$backup_name]}"
            
            local latest_version
            latest_version=$(find_latest_backup_version "$drive" "$backup_base_name")
            
            if [[ -n "$latest_version" && -f "$latest_version" ]]; then
                local file_time
                file_time=$(stat -c %Y "$latest_version" 2>/dev/null)
                if [[ $? -eq 0 && $file_time -gt $newest_backup_on_drive ]]; then
                    newest_backup_on_drive=$file_time
                fi
                echo -e "${GREEN}  ✓ $backup_name: $(basename "$latest_version") ($(date -d @$file_time '+%d.%m.%Y %H:%M:%S' 2>/dev/null))${NC}" >&2
            else
                echo -e "${YELLOW}  - $backup_name: Keine Backups gefunden${NC}" >&2
            fi
        done
        
        # Prüfe ob dieses Laufwerk das älteste "neueste" Backup hat
        if [[ $newest_backup_on_drive -lt $oldest_newest_backup ]]; then
            oldest_newest_backup=$newest_backup_on_drive
            best_drive="$drive"
        fi
        
        if [[ $newest_backup_on_drive -eq 0 ]]; then
            echo -e "${YELLOW}  → Laufwerk hat keine Backups (wird bevorzugt gewählt)${NC}" >&2
        else
            echo -e "${BLUE}  → Neustes Backup vom: $(date -d @$newest_backup_on_drive '+%d.%m.%Y %H:%M:%S' 2>/dev/null)${NC}" >&2
        fi
    done
    
    if [[ -n "$best_drive" ]]; then
        if [[ $oldest_newest_backup -eq 0 ]]; then
            echo -e "${GREEN}Verwende Backup-Laufwerk: $best_drive (keine vorherigen Backups)${NC}" >&2
        else
            echo -e "${GREEN}Verwende Backup-Laufwerk: $best_drive (ältestes neuestes Backup vom $(date -d @$oldest_newest_backup '+%d.%m.%Y %H:%M:%S' 2>/dev/null))${NC}" >&2
        fi
        printf "%s" "$best_drive"
        return 0
    else
        echo -e "${RED}Fehler bei der Auswahl des Backup-Laufwerks${NC}" >&2
        return 1
    fi
}

# Funktion um zu prüfen ob Backup-Laufwerk nicht das gleiche wie die Quell-Laufwerke ist
validate_backup_drive() {
    local backup_drive_path="$1"
    
    echo -e "${BLUE}Validiere Backup-Laufwerk...${NC}"
    
    # Prüfen ob der Pfad existiert und gemountet ist
    if [[ ! -d "$backup_drive_path" ]]; then
        echo -e "${RED}FEHLER: Backup-Laufwerk-Pfad existiert nicht: $backup_drive_path${NC}"
        return 1
    fi
    
    # Prüfen ob es sich um ein Netzwerk-Laufwerk handelt
    local fstype
    fstype=$(findmnt -n -o FSTYPE "$backup_drive_path" 2>/dev/null)
    
    case "$fstype" in
        "nfs"|"nfs4")
            echo -e "${GREEN}✓ NFS-Netzwerk-Laufwerk erkannt${NC}"
            
            # Teste Zugriff auf NFS-Laufwerk
            if ! timeout 10 ls "$backup_drive_path" >/dev/null 2>&1; then
                echo -e "${RED}FEHLER: NFS-Laufwerk nicht zugänglich oder Timeout${NC}"
                return 1
            fi
            
            # Teste Schreibberechtigung
            local test_file="$backup_drive_path/.backup-test-$$"
            if timeout 10 touch "$test_file" 2>/dev/null; then
                rm -f "$test_file" 2>/dev/null
                echo -e "${GREEN}✓ NFS-Laufwerk ist beschreibbar${NC}"
            else
                echo -e "${RED}FEHLER: Keine Schreibberechtigung auf NFS-Laufwerk${NC}"
                return 1
            fi
            
            echo -e "${GREEN}✓ NFS-Backup-Laufwerk Validierung erfolgreich${NC}"
            return 0
            ;;
        "cifs")
            echo -e "${GREEN}✓ CIFS/SMB-Netzwerk-Laufwerk erkannt${NC}"
            
            # Teste Zugriff auf CIFS-Laufwerk
            if ! timeout 10 ls "$backup_drive_path" >/dev/null 2>&1; then
                echo -e "${RED}FEHLER: CIFS-Laufwerk nicht zugänglich oder Timeout${NC}"
                return 1
            fi
            
            # Teste Schreibberechtigung
            local test_file="$backup_drive_path/.backup-test-$$"
            if timeout 10 touch "$test_file" 2>/dev/null; then
                rm -f "$test_file" 2>/dev/null
                echo -e "${GREEN}✓ CIFS-Laufwerk ist beschreibbar${NC}"
            else
                echo -e "${RED}FEHLER: Keine Schreibberechtigung auf CIFS-Laufwerk${NC}"
                return 1
            fi
            
            echo -e "${GREEN}✓ CIFS-Backup-Laufwerk Validierung erfolgreich${NC}"
            return 0
            ;;
        *)
            # Lokales Laufwerk - ursprüngliche Validierung
            echo -e "${GREEN}✓ Lokales Backup-Laufwerk erkannt${NC}"
            
            # UUID des Backup-Laufwerks ermitteln
            local backup_drive_uuid
            backup_drive_uuid=$(findmnt -n -o UUID "$backup_drive_path" 2>/dev/null)
            
            if [[ -z "$backup_drive_uuid" ]]; then
                echo -e "${RED}FEHLER: Konnte UUID des Backup-Laufwerks nicht ermitteln: $backup_drive_path${NC}"
                echo -e "${YELLOW}Versuche alternative Methoden...${NC}"
                
                # Alternative: UUID über das gemountete Gerät ermitteln
                local device_path
                device_path=$(findmnt -n -o SOURCE "$backup_drive_path" 2>/dev/null)
                if [[ -n "$device_path" ]]; then
                    backup_drive_uuid=$(blkid -s UUID -o value "$device_path" 2>/dev/null)
                fi
                
                if [[ -z "$backup_drive_uuid" ]]; then
                    echo -e "${RED}FEHLER: UUID konnte auch mit alternativen Methoden nicht ermittelt werden${NC}"
                    echo -e "${YELLOW}Backup-Laufwerk-Pfad: $backup_drive_path${NC}"
                    echo -e "${YELLOW}Gerätepfad: ${device_path:-'nicht gefunden'}${NC}"
                    return 1
                fi
            fi
            
            echo -e "${GREEN}✓ Backup-Laufwerk UUID: $backup_drive_uuid${NC}"
            
            # Prüfen ob eine der Quellen auf dem gleichen Laufwerk liegt
            for name in "${!BACKUP_PARAMETERS[@]}"; do
                IFS=':' read -r backup_file source <<< "${BACKUP_PARAMETERS[$name]}"
                
                if [[ $source != /dev/* ]]; then
                    local source_uuid
                    source_uuid=$(findmnt -n -o UUID "$source" 2>/dev/null)
                    
                    if [[ -n "$source_uuid" && "$source_uuid" == "$backup_drive_uuid" ]]; then
                        echo -e "${RED}FEHLER: Backup-Laufwerk ist das gleiche wie Quell-Laufwerk!${NC}"
                        echo -e "${RED}Quelle '$source' (UUID: $source_uuid) ist auf dem gleichen Laufwerk wie das Backup-Ziel '$backup_drive_path'${NC}"
                        echo -e "${YELLOW}Sie können nicht auf das gleiche Laufwerk sichern, von dem Sie sichern!${NC}"
                        echo ""
                        show_available_drives
                        return 1
                    fi
                fi
            done
            
            echo -e "${GREEN}✓ Lokales Backup-Laufwerk Validierung erfolgreich${NC}"
            return 0
            ;;
    esac
}

# Funktion zum Senden einer Fehler-E-Mail bei kritischen Fehlern
send_critical_error_mail() {
    local error_message="$1"
    local runtime_min="${2:-0}"
    local runtime_sec="${3:-0}"
    
    error_body="${MAIL_BODY_ERROR}"
    error_body="${error_body//\{BACKUP_DATE\}/${BACKUP_START_DATE:-$(date +%d.%B.%Y,%T)}}"
    error_body="${error_body//\{RUNTIME_MIN\}/$runtime_min}"
    error_body="${error_body//\{RUNTIME_SEC\}/$runtime_sec}"
    error_body="${error_body//\{ERROR_DETAILS\}/$error_message}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_ERROR\nTo: $MAIL_TO\n\n$error_body" | ssmtp -t 2>/dev/null
}

# Backup-Laufwerk finden und setzen
BACKUP_DRIVE_PATH=$(find_best_backup_drive)
if [[ $? -ne 0 || -z "$BACKUP_DRIVE_PATH" ]]; then
    ERROR=1
    ERROR_MSG+="Kein geeignetes Backup-Laufwerk (lokal oder Netzwerk) gefunden.\n"
    echo -e "${RED}Kritischer Fehler: Kein Backup-Laufwerk verfügbar. Script wird beendet.${NC}"
    
    # Fehler-E-Mail senden
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

echo -e "${GREEN}Backup-Laufwerk erfolgreich gefunden: $BACKUP_DRIVE_PATH${NC}"

# Backup-Laufwerk validieren (nicht das gleiche wie Quell-Laufwerke bei lokalen Laufwerken)
if ! validate_backup_drive "$BACKUP_DRIVE_PATH"; then
    ERROR=1
    ERROR_MSG+="Backup-Laufwerk Validierung fehlgeschlagen.\n"
    echo -e "${RED}Kritischer Fehler: Backup-Laufwerk Validierung fehlgeschlagen. Script wird beendet.${NC}"
    
    # Fehler-E-Mail senden
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

#####################################################################
# BACKUP-PARAMETER VERARBEITUNG
#####################################################################

# Backup-Parameter verarbeiten und Pfade aktualisieren
echo -e "${BLUE}Konfiguriere Backup-Parameter...${NC}"
for name in "${!BACKUP_PARAMETERS[@]}"; do
    IFS=':' read -r backup_base_name source <<< "${BACKUP_PARAMETERS[$name]}"
    
    # Zeitgestempelten Backup-Dateinamen erstellen
    timestamped_filename=$(create_timestamped_filename "$backup_base_name")
    full_backup_path="$BACKUP_DRIVE_PATH/$timestamped_filename"
    
    if [[ $source == /dev/* ]]; then
        device=$source
    else
        if [ ! -d "$source" ]; then
            ERROR=1
            ERROR_MSG+="Mount-Point $source existiert nicht oder ist nicht zugänglich\n"
            echo -e "${RED}Fehler: Mount-Point $source existiert nicht oder ist nicht zugänglich${NC}" >&2
            continue
        fi
        
        device=$(get_device_path "$source")
        if [ -z "$device" ]; then
            ERROR=1
            ERROR_MSG+="Konnte Gerätepfad für $source nicht ermitteln\n"
            echo -e "${RED}Fehler: Konnte Gerätepfad für $source nicht ermitteln${NC}" >&2
            continue
        fi
    fi
    
    # Format für Backup-Parameter: "vollständiger_pfad:gerät:basis_name"
    BACKUP_PARAMETERS[$name]="$full_backup_path:$device:$backup_base_name"
    echo -e "${GREEN}Konfiguriertes Backup: $name${NC}"
    echo -e "${GREEN}  - Datei: $timestamped_filename${NC}"
    echo -e "${GREEN}  - Gerät: $device${NC}"
    echo -e "${GREEN}  - Basis-Name: $backup_base_name${NC}"
done

# Prüfen ob Konfigurationsfehler aufgetreten sind
if [ "$ERROR" -eq 1 ]; then
    echo -e "${RED}Fehler bei der Konfiguration aufgetreten:${NC}" >&2
    echo -e "$ERROR_MSG" >&2
    send_critical_error_mail "$ERROR_MSG" 0 0
    exit 1
fi

#####################################################################
# PASSWORT-KONFIGURATION (OPTIONAL)
#####################################################################

# Archive-Passwort aus externer Datei laden (falls konfiguriert)
FSPASS=""
USE_ENCRYPTION=false

if [[ -n "${PASSWORD_FILE:-}" ]]; then
    echo -e "${BLUE}Prüfe Verschlüsselungskonfiguration...${NC}"
    
    if [ ! -f "$PASSWORD_FILE" ]; then
        echo -e "${RED}Fehler: Passwort-Datei $PASSWORD_FILE nicht gefunden.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Passwort-Datei $PASSWORD_FILE nicht gefunden.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    if [ ! -r "$PASSWORD_FILE" ]; then
        echo -e "${RED}Fehler: Passwort-Datei $PASSWORD_FILE ist nicht lesbar.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Passwort-Datei $PASSWORD_FILE ist nicht lesbar.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    FSPASS=$(cat "$PASSWORD_FILE" | tr -d '\n')

    if [ -z "$FSPASS" ]; then
        echo -e "${RED}Fehler: Passwort-Datei $PASSWORD_FILE ist leer.${NC}" >&2
        ERROR=1
        ERROR_MSG+="Passwort-Datei $PASSWORD_FILE ist leer.\n"
        send_critical_error_mail "$ERROR_MSG" 0 0
        exit 1
    fi

    export FSPASS
    USE_ENCRYPTION=true
    echo -e "${GREEN}✓ Verschlüsselung aktiviert${NC}"
else
    echo -e "${YELLOW}ℹ Verschlüsselung deaktiviert (PASSWORD_FILE nicht konfiguriert)${NC}"
fi

#####################################################################
# BACKUP-FUNKTIONEN
#####################################################################

# Hauptfunktion für die Durchführung eines Backups
do_backup() {
    local backup_file="$1"
    local device="$2"
    
    # Setze aktuelle Backup-Datei für Signal-Handler
    CURRENT_BACKUP_FILE="$backup_file"
    
    echo -e "${BLUE}Sichere Gerät: $device${NC}" | tee -a $BACKUP_LOG
    ls -l "$device" >> $BACKUP_LOG 2>&1
    lsblk "$device" >> $BACKUP_LOG 2>&1
    
    # fsarchiver Befehl je nach Verschlüsselungskonfiguration
    if [[ "$USE_ENCRYPTION" == true ]]; then
        fsarchiver "${EXCLUDE_STATEMENTS[@]}" -o -v -A -j$(nproc) -Z$ZSTD_COMPRESSION_VALUE -c "${FSPASS}" savefs "$backup_file" "$device" 2>&1 | tee -a $BACKUP_LOG &
    else
        fsarchiver "${EXCLUDE_STATEMENTS[@]}" -o -v -A -j$(nproc) -Z$ZSTD_COMPRESSION_VALUE savefs "$backup_file" "$device" 2>&1 | tee -a $BACKUP_LOG &
    fi
    
    # PID des fsarchiver-Prozesses für Signal-Handler speichern
    CURRENT_FSARCHIVER_PID=$!
    
    # Warten auf fsarchiver-Prozess
    wait $CURRENT_FSARCHIVER_PID
    local fsarchiver_exit_code=$?
    
    # fsarchiver-PID zurücksetzen (fertig)
    CURRENT_FSARCHIVER_PID=""
    
    # Prüfen ob das Script unterbrochen wurde
    if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
        echo -e "${YELLOW}Backup wurde unterbrochen während der Verarbeitung von $device${NC}"
        return 1
    fi
    
    # Prüfen auf fsarchiver Exit-Code
    if [[ $fsarchiver_exit_code -ne 0 ]]; then
        echo -e "${RED}fsarchiver beendet mit Exit-Code: $fsarchiver_exit_code${NC}"
        ERROR=1
        ERROR_MSG+="fsarchiver Exit-Code $fsarchiver_exit_code für Gerät $device\n"
    fi
    
    check_backup_errors "$device" "$backup_file"
    
    # Nach dem Backup: Prüfe auf neue fsarchiver Mount-Points und räume sie auf
    echo -e "${BLUE}Prüfe auf fsarchiver Mount-Points nach Backup...${NC}"
    local post_backup_mounts
    post_backup_mounts=$(find_fsarchiver_mounts)
    
    if [[ -n "$post_backup_mounts" ]]; then
        echo -e "${YELLOW}Neue fsarchiver Mount-Points nach Backup erkannt - räume auf...${NC}"
        if ! cleanup_fsarchiver_mounts true; then
            echo -e "${YELLOW}Warnung: Einige Mount-Points konnten nicht automatisch entfernt werden${NC}"
            ERROR_MSG+="Warnung: fsarchiver Mount-Points nach Backup von $device konnten nicht vollständig entfernt werden\n"
        fi
    else
        echo -e "${GREEN}✓ Keine fsarchiver Mount-Points nach Backup vorhanden${NC}"
    fi
    
    # Backup-Datei zurücksetzen (fertig)
    CURRENT_BACKUP_FILE=""
    
    return $fsarchiver_exit_code
}

# Funktion zur Überprüfung von Backup-Fehlern
check_backup_errors() {
    local BKP_SOURCE="$1"
    local BKP_FILE="$2"

    # Sicherstellen dass die BACKUP_LOG Variable verfügbar ist
    if [ -z "$BACKUP_LOG" ]; then
        ERROR_MSG+="[ $BACKUP_LOG ] ist leer nach Backup von [ $BKP_SOURCE ]. Etwas stimmt nicht. Bitte prüfen Sie die Logs und den gesamten Backup-Prozess."
        return 1
    fi

    local LOG_OUTPUT
    LOG_OUTPUT=$(tail -n 5 "$BACKUP_LOG" | egrep -i "(files with errors)|\b(cannot|warning|error|errno|Errors detected)\b")

    # Prüfe auf Fehler in der Log-Ausgabe
    local has_errors=false
    if  [[ ${LOG_OUTPUT,,} =~ (^|[[:space:]])("cannot"|"warning"|"error"|"errno"|"errors detected")([[:space:]]|$) ]]; then
        has_errors=true
        ERROR=1
        ERROR_MSG+="Fehler beim Backup von [ $BKP_SOURCE ] erkannt:\n$LOG_OUTPUT\n"
    elif [[ $LOG_OUTPUT =~ regfiles=([0-9]+),\ directories=([0-9]+),\ symlinks=([0-9]+),\ hardlinks=([0-9]+),\ specials=([0-9]+) ]]; then
        for val in "${BASH_REMATCH[@]:1}"; do
            if [ "$val" -ne 0 ]; then
                has_errors=true
                ERROR=1
                ERROR_MSG+="Fehler beim Backup von [ $BKP_SOURCE ] erkannt:\n$LOG_OUTPUT\n"
                break
            fi
        done
    fi
    
    # Prüfe ob die Backup-Datei tatsächlich erstellt wurde
    if [[ ! -f "$BKP_FILE" ]]; then
        has_errors=true
        ERROR=1
        ERROR_MSG+="Backup-Datei wurde nicht erstellt: $BKP_FILE\n"
        echo -e "${RED}✗ Backup-Datei nicht gefunden: $BKP_FILE${NC}"
    else
        # Prüfe die Grösse der Backup-Datei (mindestens 1 MB)
        local file_size
        file_size=$(stat -c%s "$BKP_FILE" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            if [[ $file_size -lt 1048576 ]]; then  # 1 MB = 1048576 Bytes
                has_errors=true
                ERROR=1
                ERROR_MSG+="Backup-Datei ist zu klein ($(( file_size / 1024 )) KB): $BKP_FILE\n"
                echo -e "${RED}✗ Backup-Datei zu klein: $BKP_FILE ($(( file_size / 1024 )) KB)${NC}"
            else
                echo -e "${GREEN}✓ Backup-Datei erstellt: $(basename "$BKP_FILE") ($(( file_size / 1024 / 1024 )) MB)${NC}"
            fi
        else
            has_errors=true
            ERROR=1
            ERROR_MSG+="Konnte Grösse der Backup-Datei nicht ermitteln: $BKP_FILE\n"
            echo -e "${RED}✗ Konnte Backup-Datei-Grösse nicht ermitteln: $BKP_FILE${NC}"
        fi
    fi
    
    # Gesamtergebnis ausgeben
    if [[ "$has_errors" == true ]]; then
        echo -e "${RED}✗ Backup von $BKP_SOURCE fehlgeschlagen${NC}"
    else
        echo -e "${GREEN}✓ Backup von $BKP_SOURCE erfolgreich${NC}"
    fi
}

#####################################################################
# HAUPTPROGRAMM - BACKUP DURCHFÜHRUNG
#####################################################################

# Ausschluss-Anweisungen für fsarchiver als Array generieren
EXCLUDE_STATEMENTS=()
for path in "${EXCLUDE_PATHS[@]}"; do
  EXCLUDE_STATEMENTS+=("--exclude=$path")
done

# Backup-Startzeit erfassen
TIME_START=$(date +"%s")
BACKUP_START_DATE=$(date +%d.%B.%Y,%T)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}BACKUP-PROZESS GESTARTET${NC}"
echo -e "${GREEN}Start: $BACKUP_START_DATE${NC}"
echo -e "${GREEN}========================================${NC}"

# Log-Datei initialisieren
if [[ -e $BACKUP_LOG ]]; then
    rm -f $BACKUP_LOG
fi
touch $BACKUP_LOG

echo "Backup gestartet: $BACKUP_START_DATE" >> $BACKUP_LOG

# Backup-Jobs durch Iteration über das assoziative Array ausführen
for KEY in $(echo "${!BACKUP_PARAMETERS[@]}" | tr ' ' '\n' | sort -n); do
    # Prüfen ob Script unterbrochen wurde
    if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
        echo -e "${YELLOW}Script-Unterbrechung erkannt. Stoppe weitere Backups.${NC}"
        break
    fi
    
    IFS=':' read -r BKP_IMAGE_FILE SOURCE_DEVICE BKP_BASE_NAME <<< "${BACKUP_PARAMETERS[$KEY]}"
    echo -e "${BLUE}Starte Backup: $KEY${NC}"
    
    if do_backup "$BKP_IMAGE_FILE" "$SOURCE_DEVICE"; then
        # Nach erfolgreichem Backup: Alte Versionen bereinigen (nur wenn nicht unterbrochen)
        if [[ "$SCRIPT_INTERRUPTED" == false && $ERROR -eq 0 ]]; then
            cleanup_old_backups "$BACKUP_DRIVE_PATH" "$BKP_BASE_NAME" "$VERSIONS_TO_KEEP"
        fi
    else
        echo -e "${RED}Backup von $KEY fehlgeschlagen oder wurde unterbrochen${NC}"
        if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
            break
        fi
    fi
done

#####################################################################
# ABSCHLUSS UND E-MAIL-BENACHRICHTIGUNG
#####################################################################

# Laufzeit berechnen
TIME_DIFF=$(($(date +"%s")-${TIME_START}))
RUNTIME_MINUTES=$((${TIME_DIFF} / 60))
RUNTIME_SECONDS=$((${TIME_DIFF} % 60))

echo -e "${GREEN}========================================${NC}"

# Prüfen ob Script unterbrochen wurde
if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
    echo -e "${RED}BACKUP WURDE UNTERBROCHEN${NC}"
    echo -e "${RED}Laufzeit: $RUNTIME_MINUTES Minuten und $RUNTIME_SECONDS Sekunden${NC}"
    echo -e "${RED}========================================${NC}"
    
    # Abbruch-E-Mail
    mail_body="${MAIL_BODY_INTERRUPTED}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_INTERRUPTED\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${YELLOW}Abbruch-E-Mail versendet${NC}"
    
    exit 130  # Standard Exit-Code für SIGINT
elif [ "$ERROR" -eq 1 ]; then
    echo -e "${RED}BACKUP ABGESCHLOSSEN MIT FEHLERN${NC}"
    echo -e "${GREEN}Ende: $(date +%d.%B.%Y,%T)${NC}"
    echo -e "${GREEN}Laufzeit: $RUNTIME_MINUTES Minuten und $RUNTIME_SECONDS Sekunden${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Fehler-E-Mail
    mail_body="${MAIL_BODY_ERROR}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    mail_body="${mail_body//\{ERROR_DETAILS\}/$ERROR_MSG}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_ERROR\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${YELLOW}Fehler-E-Mail versendet${NC}"
else
    echo -e "${GREEN}BACKUP ERFOLGREICH ABGESCHLOSSEN${NC}"
    echo -e "${GREEN}Ende: $(date +%d.%B.%Y,%T)${NC}"
    echo -e "${GREEN}Laufzeit: $RUNTIME_MINUTES Minuten und $RUNTIME_SECONDS Sekunden${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Erfolgs-E-Mail
    mail_body="${MAIL_BODY_SUCCESS}"
    mail_body="${mail_body//\{BACKUP_DATE\}/$BACKUP_START_DATE}"
    mail_body="${mail_body//\{RUNTIME_MIN\}/$RUNTIME_MINUTES}"   
    mail_body="${mail_body//\{RUNTIME_SEC\}/$RUNTIME_SECONDS}"
    
    echo -e "From: $MAIL_FROM\nSubject: $MAIL_SUBJECT_SUCCESS\nTo: $MAIL_TO\n\n$mail_body" | ssmtp -t
    echo -e "${GREEN}Erfolgs-E-Mail versendet${NC}"
fi

# Script mit entsprechendem Exit-Code beenden
if [[ "$SCRIPT_INTERRUPTED" == true ]]; then
    exit 130  # Standard Exit-Code für SIGINT
elif [ "$ERROR" -eq 1 ]; then
    exit 1
else
    exit 0
fi