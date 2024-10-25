#!/bin/bash

CERT_PATH="/etc/letsencrypt/live/XXXXXX.com/fullchain.pem"

while [ ! -f "$CERT_PATH" ]; do
  echo "Waiting for SSL certificates to be generated..."
  sleep 5
done

echo "Certificates found. Starting Nginx..."
nginx -g 'daemon off;'
