#!/usr/bin/env bash
###############################################################################
# Script de backup "robuste" via rclone (SFTP):
# - Lit ses variables dans .env
# - Crée une archive tar (sans recompression) en streaming
# - Envoie l'archive via rclone rcat (SFTP)
# - Limite la sollicitation CPU/disk (nice, ionice, --bwlimit)
# - Conserve N versions (rotation)
# - En cas d'erreur ou backup vide, envoie un email via Mailtrap API (curl)
# - Lock pour éviter l'exécution concurrente
#
# Prérequis :
#   apt-get install rclone
#   # si vous voulez la lecture JSON pour la taille : apt-get install jq


# ======> apt-get install curl

#.ENV 
# --- Paramètres SFTP/rclone ---
#SFTP_HOST=
#SFTP_PORT="22"
#SFTP_USER=
# rclone obscure XXXXXX
#SFTP_PASS=
#SFTP_REMOTE_DIR=
#KEEP_VERSIONS="5"       # Nombre de versions à conserver
#BACKUP_SOURCE=
#MAILTRAP_API_TOKEN=
#ALERT_EMAIL=
#FROM_EMAIL=
# --- Autres options (éventuellement) ---
#LOG_FILE="/var/log/rclone_sftp_backup.log"
#MAX_RETRIES=3
#RETRY_DELAY=30

###############################################################################

set -e
set -o pipefail

####################### 1) Chargement configuration  ##########################
CONFIG_FILE="${1:-../.env}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERROR] Fichier .env introuvable : $CONFIG_FILE"
  exit 1
fi
source "$CONFIG_FILE"

# Variables par défaut
: "${LOG_FILE:="/var/log/rclone_sftp_backup_${CONFIG_FILE##*/}.log"}"
: "${MAX_RETRIES:=3}"
: "${RETRY_DELAY:=30}"
: "${KEEP_VERSIONS:=5}"

# Vérification des variables essentielles
: "${SFTP_HOST:?Variable SFTP_HOST non définie dans .env}"
: "${SFTP_PORT:?Variable SFTP_PORT non définie dans .env}"
: "${SFTP_USER:?Variable SFTP_USER non définie dans .env}"
: "${SFTP_PASS:?Variable SFTP_PASS non définie dans .env}"
: "${SFTP_REMOTE_DIR:?Variable SFTP_REMOTE_DIR non définie dans .env}"
: "${BACKUP_SOURCE:?Variable BACKUP_SOURCE non définie dans .env}"
: "${ALERT_EMAIL:?Variable ALERT_EMAIL non définie dans .env}"
: "${FROM_EMAIL:?Variable FROM_EMAIL non définie dans .env}"
: "${MAILTRAP_API_TOKEN:?Variable MAILTRAP_API_TOKEN non définie dans .env}"

####################### 2) Lockfile ###########################################
LOCKFILE="/tmp/rclone_sftp_backup_${CONFIG_FILE##*/}.lock"

cleanup_old_lock() {
  if [ -f "$LOCKFILE" ]; then
    local LOCK_MTIME
    LOCK_MTIME=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
    local CURRENT_TIME
    CURRENT_TIME=$(date +%s)
    local LOCK_MAX_AGE_SECONDS=$((7 * 24 * 3600))
    local AGE=$((CURRENT_TIME - LOCK_MTIME))
    if [ $AGE -gt $LOCK_MAX_AGE_SECONDS ]; then
      echo "[INFO] Lockfile trop ancien, on vérifie si un process tar/rclone tourne."
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

# On verrouille le script pour éviter les exécutions concurrentes
exec 200>"$LOCKFILE"
flock -n 200 || {
  echo "[ERROR] Script déjà en cours d'exécution. Abandon."
  exit 1
}

####################### 3) Redirection des logs ################################
exec > >(tee -a "$LOG_FILE") 2>&1
echo "======================================================================="
echo "[INFO] Début du script : $(date)"
echo "[INFO] BACKUP_SOURCE  : $BACKUP_SOURCE"
echo "[INFO] SFTP REMOTE    : $SFTP_HOST:$SFTP_PORT/$SFTP_REMOTE_DIR"
echo "[INFO] Garde $KEEP_VERSIONS versions max"

####################### 4) Fonction envoi d'alerte via Mailtrap API ###########
send_error_mail() {
  local subject="$1"
  local body="$2"
  echo "[INFO] Envoi d'une alerte à $ALERT_EMAIL via Mailtrap..."
  curl --location --request POST "https://send.api.mailtrap.io/api/send" \
    --header "Authorization: Bearer $MAILTRAP_API_TOKEN" \
    --header "Content-Type: application/json" \
    --data-raw "{
      \"from\": {
        \"email\": \"${FROM_EMAIL}\",
        \"name\": \"Server Backup\"
      },
      \"to\": [
        {\"email\": \"${ALERT_EMAIL}\"}
      ],
      \"subject\": \"${subject}\",
      \"text\": \"${body}\",
      \"category\": \"Backup Notification\"
    }" || true
}

####################### 5) Config remote rclone (SFTP) ########################
REMOTE_NAME="sftp_backup"
export RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf"
export RCLONE_CONFIG_SFTP_BACKUP_TYPE="sftp"
export RCLONE_CONFIG_SFTP_BACKUP_HOST="$SFTP_HOST"
export RCLONE_CONFIG_SFTP_BACKUP_USER="$SFTP_USER"
export RCLONE_CONFIG_SFTP_BACKUP_PASS="$SFTP_PASS"
export RCLONE_CONFIG_SFTP_BACKUP_PORT="$SFTP_PORT"

if ! rclone mkdir "${REMOTE_NAME}:$SFTP_REMOTE_DIR"; then
  echo "[ERROR] Échec création dossier distant $SFTP_REMOTE_DIR."
  send_error_mail "Backup Error: mkdir" \
    "Impossible de créer le répertoire $SFTP_REMOTE_DIR sur $SFTP_HOST."
  exit 1
fi

####################### 6) Nom d'archive + upload streaming ####################
TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
ARCHIVE_NAME="backup-${TIMESTAMP}.tar"
REMOTE_PATH="$SFTP_REMOTE_DIR/$ARCHIVE_NAME"

attempt=1
success=false
while [ $attempt -le $MAX_RETRIES ]; do
  echo "[INFO] Tentative #$attempt : création et upload tar => rclone => SFTP"

  # ici on évite le -z pour ne pas recomprimer si ce sont des images
  if ionice -c2 -n7 nice -n 10 tar -cf - "$BACKUP_SOURCE" \
    | rclone rcat "${REMOTE_NAME}:$REMOTE_PATH" --bwlimit 2M
  then
    echo "[INFO] Transfert réussi (tentative #$attempt)."
    success=true
    break
  else
    echo "[ERROR] Échec tentative #$attempt."
    ((attempt++))
    if [ $attempt -le $MAX_RETRIES ]; then
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

####################### 7) Vérification de la taille du backup #################
SIZE_INFO=$(rclone size "${REMOTE_NAME}:$REMOTE_PATH" 2>/dev/null || true)
REMOTE_SIZE=$(echo "$SIZE_INFO" \
  | grep "Total size" \
  | grep -oE '[0-9]+' \
  | paste -sd "" -)

# (Si vous préférez le JSON + jq pour un entier unique, faites:)
# SIZE_INFO=$(rclone size "${REMOTE_NAME}:$REMOTE_PATH" --json 2>/dev/null || true)
# REMOTE_SIZE=$(echo "$SIZE_INFO" | jq -r '.bytes')

if [ -z "$REMOTE_SIZE" ] || [ "$REMOTE_SIZE" -eq 0 ]; then
  echo "[ERROR] L'archive est vide (0 octets)."
  rclone delete "${REMOTE_NAME}:$REMOTE_PATH" || true
  send_error_mail "Backup Error (Empty)" \
    "L'archive $ARCHIVE_NAME est vide (0 octets). Fichier supprimé et alerte envoyée."
  exit 1
else
  echo "[INFO] Taille de l'archive finale : $REMOTE_SIZE octets."
fi

####################### 8) Rotation des anciennes versions #####################
echo "[INFO] Rotation : on ne garde que $KEEP_VERSIONS backups."

ALL_BACKUPS=$(
  rclone lsf "${REMOTE_NAME}:$SFTP_REMOTE_DIR" --files-only --format "n" \
  | grep -E 'backup-[0-9]{8}-[0-9]{6}\.tar(\.gz)?' \
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
      echo "[WARN] Impossible de supprimer $oldfile."
    }
  done <<< "$OLD_BACKUPS"
else
  echo "[INFO] $COUNT backups, <= $KEEP_VERSIONS. Pas de suppression."
fi

####################### 9) Fin ###############################################
echo "[INFO] Sauvegarde finalisée avec succès : $ARCHIVE_NAME"
echo "[INFO] Fin du script : $(date)"
echo "======================================================================="

# Décommenter si vous souhaitez supprimer le fichier lock après coup:
# rm -f "$LOCKFILE"

exit 0
