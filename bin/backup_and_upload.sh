#!/bin/bash

# Variables
PROJECT_DIR="/home/XXXXXX/projects"
BACKUP_DIR="/home/XXXXXX"
MONTH=$(date +%m)
ARCHIVE_NAME="project-${MONTH}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
FTP_SERVER="XXXXXXXX-dc3.online.net"
CONFIG_FILE="/home/XXXXXX/projects/XXXXXX.com/.env"


# Source the .env file
if [ -f "${CONFIG_FILE}" ]; then
    set -o allexport
    source "${CONFIG_FILE}"
    set +o allexport
else
    echo "Error: Configuration file not found at ${CONFIG_FILE}."
    exit 1
fi

# Check if FTP_USER and FTP_PASS are set
if [ -z "${FTP_USER}" ] || [ -z "${FTP_PASS}" ]; then
    echo "Error: FTP_USER or FTP_PASS not set in the configuration file."
    exit 1
fi


# Create the archive
echo "Creating archive ${ARCHIVE_PATH} from ${PROJECT_DIR}..."
tar -czf "${ARCHIVE_PATH}" -C "$(dirname "${PROJECT_DIR}")" "$(basename "${PROJECT_DIR}")"

# Check if the archive was created successfully
if [ $? -ne 0 ]; then
    echo "Error: Failed to create archive."
    exit 1
fi
echo "Archive created successfully."

# Read the FTP password


# Upload the archive via FTP
echo "Uploading archive to FTP server..."

ftp -p -inv "${FTP_SERVER}" <<EOF
user ${FTP_USER} ${FTP_PASS}
put "${ARCHIVE_PATH}" "${ARCHIVE_NAME}"
bye
EOF

# Check if the FTP upload was successful
if [ $? -ne 0 ]; then
    echo "Error: FTP upload failed."
    exit 1
fi

echo "Archive uploaded successfully."

# Verify the file exists on the FTP server
echo "Verifying the uploaded file on the FTP server..."

FTP_OUTPUT=$(ftp -inv "${FTP_SERVER}" <<EOF
user ${FTP_USER} ${FTP_PASS}
ls
bye
EOF
)

if echo "${FTP_OUTPUT}" | grep -q "${ARCHIVE_NAME}"; then
    echo "Verification successful: ${ARCHIVE_NAME} exists on the FTP server."
else
    echo "Error: Verification failed. ${ARCHIVE_NAME} not found on the FTP server."
    exit 1
fi

echo "Backup and FTP upload completed successfully."
