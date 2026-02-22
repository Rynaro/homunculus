#!/bin/sh
set -e

# Ensure the data directory exists and is writable by the app user.
# Named Docker volumes are created as root; the app runs as homunculus (UID 1000).
mkdir -p /app/data
chown -R homunculus:homunculus /app/data

exec gosu homunculus "$@"
