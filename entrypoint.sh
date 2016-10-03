#!/bin/bash

set -eo pipefail

# Validate environment variables

MISSING=""

[ -z "${DOMAIN}" ] && MISSING="${MISSING} DOMAIN"
[ -z "${UPSTREAM}" ] && MISSING="${MISSING} UPSTREAM"


if [ "${MISSING}" != "" ]; then
  echo "Missing required environment variables:" >&2
  echo " ${MISSING}" >&2
  exit 1
  fi

#Processing DOMAIN into an array
DOMAINSARRAY=($(echo "${DOMAIN}" | awk -F ";" '{for(i=1;i<=NF;i++) print $i;}'))
echo "Provided domains"
printf "====> %s\n" "${DOMAINSARRAY[@]}"

#Processing UPSTREAM into an array
UPSTREAMARRAY=($(echo "${UPSTREAM}" | awk -F ";" '{for(i=1;i<=NF;i++) print $i;}'))
echo "Services to reverse-proxy"
printf "====> %s\n" "${UPSTREAMARRAY[@]}"

#The two arrays should have the same lenght
if [ "${#DOMAINSARRAY[@]}" != "${#UPSTREAMARRAY[@]}" ]; then
  echo "The number of domains must match the number of upstream services"
fi

# Default other parameters

SERVER=""
# [ -n "${STAGING:-}" ] && SERVER="--server https://acme-staging.api.letsencrypt.org/directory"

# Generate strong DH parameters for nginx, if they don't already exist.
# if [ ! -f /etc/ssl/dhparams.pem ]; then
#   if [ -f /cache/dhparams.pem ]; then
#     cp /cache/dhparams.pem /etc/ssl/dhparams.pem
#   else
#     openssl dhparam -out /etc/ssl/dhparams.pem 2048
#     # Cache to a volume for next time?
#     if [ -d /cache ]; then
#       cp /etc/ssl/dhparams.pem /cache/dhparams.pem
#     fi
#   fi
# fi

#create temp file storage
mkdir -p /var/cache/nginx
chown nginx:nginx /var/cache/nginx

mkdir -p /var/tmp/nginx
chown nginx:nginx /var/tmp/nginx

#create vhost directory
mkdir -p /etc/nginx/vhosts/

function escape_slashes() {
  echo $1 | sed 's_/_\\/_g'
}

# Process the nginx.conf with raw values of $DOMAIN and $UPSTREAM to ensure backward-compatibility
  dest="/etc/nginx/nginx.conf"
  echo "Rendering template of nginx.conf with settings:"
  SSL_CERT_KEY=${SSL_CERT_KEY:-/etc/nginx/ssl/domain.pem}
  SSL_DHPARAMS=${SSL_DHPARAMS:-/etc/ssl/dhparams.pem}
  SSL_CERT=${SSL_CERT:-/etc/nginx/ssl/chained.pem}
  echo "DOMAIN=${DOMAIN} UPSTREAM=${UPSTREAM} SSL_CERT=$SSL_CERT"
  echo "SSL_CERT_KEY=$SSL_CERT_KEY SSL_DHPARAMS=$SSL_DHPARAMS"
  sed -e "s/\${DOMAIN}/${DOMAIN}/g" \
      -e "s/\${UPSTREAM}/${UPSTREAM}/" \
      -e "s/\${SSL_CERT}/$(escape_slashes $SSL_CERT)/" \
      -e "s/\${SSL_CERT_KEY}/$(escape_slashes $SSL_CERT_KEY)/" \
      -e "s/\${SSL_DHPARAMS}/$(escape_slashes $SSL_DHPARAMS)/" \
      /templates/nginx.conf > "$dest"

# Process templates
upstreamId=0
for t in "${DOMAINSARRAY[@]}"
do
  dest="/etc/nginx/vhosts/$(basename "${t}").conf"
  src="/templates/vhost.tmpl.conf"

  if [ -r /configs/"${t}".conf ]; then
    echo "Manual configuration found for $t"
    src="/configs/${t}.conf"
  fi

  echo "Rendering template of $t in $dest"
  sed -e "s/\${DOMAIN}/${t}/g" \
      -e "s/\${UPSTREAM}/${UPSTREAMARRAY[upstreamId]}/" \
      -e "s/\${PATH}/${DOMAINSARRAY[0]}/" \
      -e "s/\${SSL_CERT}/$(escape_slashes $SSL_CERT)/" \
      -e "s/\${SSL_CERT_KEY}/$(escape_slashes $SSL_CERT_KEY)/" \
      -e "s/\${SSL_DHPARAMS}/$(escape_slashes $SSL_DHPARAMS)/" \
      "$src" > "$dest"

  upstreamId=$((upstreamId+1))
done

# Launch nginx in the foreground
/usr/sbin/nginx -g "daemon off;"
