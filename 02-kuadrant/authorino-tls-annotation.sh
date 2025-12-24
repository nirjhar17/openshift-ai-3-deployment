#!/bin/bash
# Add TLS annotation to Authorino service
# This enables OpenShift's service-ca operator to generate TLS certificates
#
# Usage: bash authorino-tls-annotation.sh

set -e

echo "Adding TLS annotation to Authorino service..."

oc annotate svc authorino-authorino-authorization -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-tls \
  --overwrite

echo "Waiting for certificate generation..."
sleep 10

echo "Verifying TLS secret..."
oc get secret authorino-tls -n kuadrant-system

echo "TLS annotation added successfully!"
echo ""
echo "Note: This creates the 'authorino-tls' secret with TLS certificates."
echo "The ODH Model Controller's EnvoyFilter expects TLS when connecting to Authorino."

