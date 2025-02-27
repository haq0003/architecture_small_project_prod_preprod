#!/usr/bin/env bash
###############################################################################
# Script de backup "robuste" via rclone (SFTP):
# - Lit ses variables dans .env
# - Crée une archive tar.gz en streaming
# - Envoie l'archive via rclone rcat (SFTP)
# - Conserve N versions (rotation)
# - En cas d'échec ou de backup vide, envoie un email d'alerte avec `sendmail`
# - Lock pour éviter l'exécution concurrente
###############################################################################

set -e
set -o pipefail

####################### 1) Chargement configuration  ##########################
CONFIG_FILE="../.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Fichier .env introuvable à l'emplacement : $CONFIG_FILE"
  exit 1
fi

# On charge les variables définies dans .env
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Valeurs par défaut si non définies dans .env
: "${LOG_FILE:="/var/log/rclone_sftp_backup.log"}"
: "${MAX_RETRIES:=3}"
: "${RETRY_DELAY:=30}"
: "${KEEP_VERSIONS:=5}"

# Contrôle de présence des variables essentielles
: "${SFTP_HOST:?Variable SFTP_HOST non définie dans .env}"
: "${SFTP_PORT:?Variable SFTP_PORT non définie dans .env}"
: "${SFTP_USER:?Variable SFTP_USER non définie dans .env}"
: "${SFTP_PASS:?Variable SFTP_PASS non définie dans .env}"
: "${SFTP_REMOTE_DIR:?Variable SFTP_REMOTE_DIR non définie dans .env}"
: "${BACKUP_SOURCE:?Variable BACKUP_SOURCE non définie dans .env}"
: "${ALERT_EMAIL:?Variable ALERT_EMAIL non définie dans .env}"

####################### 2) Lockfile pour exécution unique #####################
LOCKFILE="/tmp/rclone_sftp_backup.lock"
cleanup_old_lock() {
  if [ -f "$LOCKFILE" ]; then
      local LOCK_MTIME
      LOCK_MTIME=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
      local CURRENT_TIME
      CURRENT_TIME=$(date +%s)
      local LOCK_MAX_AGE_SECONDS=$((7 * 24 * 3600))  # 7 jours, paramétrable
      local AGE=$((CURRENT_TIME - LOCK_MTIME))
      if [ $AGE -gt $LOCK_MAX_AGE_SECONDS ]; then
          echo "[INFO] Lockfile trop ancien. On vérifie si un process tar/rclone tourne."
          if pgrep -f "tar|rclone" >/dev/null 2>&1; then
              echo "[WARN] Un process tar/rclone est actif, on garde le lock."
          else
              echo "[INFO] Aucun process actif, on supprime le lock obsolète."
              rm -f "$LOCKFILE"
          fi
      fi
  fi
}
cleanup_old_lock

# Tente d'obtenir un verrou
exec 200>"$LOCKFILE"
flock -n 200 || {
  echo "[ERROR] Script déjà en cours d'exécution. Abandon."
  exit 1
}

####################### 3) Redirection des logs ################################
# On logge tout (stdout + stderr) dans LOG_FILE, et on affiche à l'écran aussi
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================================="
echo "[INFO] Début du script : $(date)"
echo "[INFO] Lecture des paramètres depuis $CONFIG_FILE"
echo "[INFO] BACKUP_SOURCE  : $BACKUP_SOURCE"
echo "[INFO] SFTP REMOTE    : $SFTP_HOST:$SFTP_PORT/$SFTP_REMOTE_DIR"
echo "[INFO] Fichier de log : $LOG_FILE"
echo "[INFO] Garde $KEEP_VERSIONS versions max"

####################### 4) Fonction d'envoi d'email d'alerte (sendmail) ########
send_error_mail() {
  local subject="$1"
  local body="$2"

  # Construire l'email avec les en-têtes et le corps,
  # puis l'envoyer à sendmail via STDIN
  /usr/sbin/sendmail -t <<EOF
From: ${FROM_EMAIL:-"backup-script@example.com"}
To: ${ALERT_EMAIL}
Subject: $subject

$body
EOF
}

####################### 5) Configuration du remote rclone ######################
REMOTE_NAME="sftp_backup"

# Optionnel: vous pouvez définir un fichier rclone.conf si besoin
export RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf"

# Force la config du remote "sftp_backup" par variables d'environnement
export RCLONE_CONFIG_SFTP_BACKUP_TYPE="sftp"
export RCLONE_CONFIG_SFTP_BACKUP_HOST="$SFTP_HOST"
export RCLONE_CONFIG_SFTP_BACKUP_USER="$SFTP_USER"
export RCLONE_CONFIG_SFTP_BACKUP_PASS="$SFTP_PASS"
export RCLONE_CONFIG_SFTP_BACKUP_PORT="$SFTP_PORT"

# Vérifier/créer le répertoire distant (mkdir ne renvoie pas d'erreur si déjà présent)
if ! rclone mkdir "${REMOTE_NAME}:$SFTP_REMOTE_DIR"; then
  echo "[ERROR] Échec création dossier distant $SFTP_REMOTE_DIR."
  send_error_mail "Backup Error: mkdir" \
    "Impossible de créer le répertoire distant $SFTP_REMOTE_DIR sur $SFTP_HOST."
  exit 1
fi

####################### 6) Génération du nom d'archive ########################
# Exemple : backup-20250301-120000.tar.gz
TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
ARCHIVE_NAME="backup-${TIMESTAMP}.tar.gz"  # Nom purement logique (pas stocké localement).
REMOTE_PATH="$SFTP_REMOTE_DIR/$ARCHIVE_NAME"

####################### 7) Création + envoi de l'archive en streaming ##########
attempt=1
success=false

while [ $attempt -le "${MAX_RETRIES:-3}" ]; do
  echo "[INFO] Tentative #$attempt : création de l'archive et upload via rclone (SFTP)"
  echo "[DEBUG] Commande : tar -czf - \"$BACKUP_SOURCE\" | rclone rcat \"${REMOTE_NAME}:$REMOTE_PATH\""

  if tar -czf - "$BACKUP_SOURCE" \
     | rclone rcat "${REMOTE_NAME}:$REMOTE_PATH"; then
    echo "[INFO] Transfert réussi (tentative #$attempt)."
    success=true
    break
  else
    echo "[ERROR] Échec tentative #$attempt."
    ((attempt++))
    if [ $attempt -le "${MAX_RETRIES:-3}" ]; then
      echo "[INFO] Réessai dans ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
    fi
  fi
done

if [ "$success" != "true" ]; then
  echo "[ERROR] Toutes les tentatives ont échoué."
  send_error_mail "Backup Error (rclone)" \
    "Toutes les tentatives de création/upload de l'archive ont échoué sur $SFTP_HOST."
  exit 1
fi

####################### 8) Vérification de la taille du backup ################
SIZE_INFO=$(rclone size "${REMOTE_NAME}:$REMOTE_PATH" 2>/dev/null || true)
# Exemple de sortie: "Total objects: 1\nTotal size: 12345 (12.056 KiB)"

# Extraire la taille en octets
REMOTE_SIZE=$(echo "$SIZE_INFO" | grep "Total size" | grep -oE '[0-9]+' || echo 0)

if [ -z "$REMOTE_SIZE" ] || [ "$REMOTE_SIZE" -eq 0 ]; then
  echo "[ERROR] L'archive sur le serveur est vide (0 octets)."
  # On supprime ce fichier distant inutile
  rclone delete "${REMOTE_NAME}:$REMOTE_PATH" || true

  send_error_mail "Backup Error (Empty)" \
    "L'archive $ARCHIVE_NAME a été créée mais semble vide (0 octets). Suppression et alerte."
  exit 1
else
  echo "[INFO] Taille de l'archive : $REMOTE_SIZE octets."
fi

####################### 9) Rotation des anciennes versions #####################
echo "[INFO] Rotation des backups, on ne garde que $KEEP_VERSIONS fichiers."
ALL_BACKUPS=$(
  rclone lsf "${REMOTE_NAME}:$SFTP_REMOTE_DIR" --files-only --format "t" \
    | grep -E 'backup-[0-9]{8}-[0-9]{6}\.tar\.gz' \
    | sort
)
COUNT=$(echo "$ALL_BACKUPS" | wc -l | awk '{print $1}')

if [ "$COUNT" -gt "$KEEP_VERSIONS" ]; then
  TO_REMOVE=$((COUNT - KEEP_VERSIONS))
  echo "[INFO] Il y a $COUNT backups. On supprime $TO_REMOVE plus ancien(s)."

  OLD_BACKUPS=$(echo "$ALL_BACKUPS" | head -n "$TO_REMOVE")

  while IFS= read -r oldfile; do
    echo "[INFO] Suppression de l'ancien backup : $oldfile"
    rclone delete "${REMOTE_NAME}:$SFTP_REMOTE_DIR/$oldfile" || {
      echo "[WARN] Impossible de supprimer $oldfile (on continue)."
    }
  done <<< "$OLD_BACKUPS"
else
  echo "[INFO] Nombre total de backups ($COUNT) <= $KEEP_VERSIONS. Pas de suppression."
fi

####################### 10) Fin / Succès #######################################
echo "[INFO] Sauvegarde finalisée avec succès : $ARCHIVE_NAME"
echo "[INFO] Fin du script : $(date)"
echo "======================================================================="
exit 0
