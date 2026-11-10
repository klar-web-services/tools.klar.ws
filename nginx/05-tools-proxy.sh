#!/bin/sh
# Runs on every container start, before the nginx image renders its templates.
set -eu

: "${S3_ORIGIN:?set S3_ORIGIN to the bucket URL}"

# Start with an empty cache, so restarting the proxy drops whatever it cached.
rm -rf /var/cache/nginx/tools/*
