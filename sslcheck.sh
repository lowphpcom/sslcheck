#!/bin/bash
set -u

dir_path="/root/.acme.sh"
acme_bin="/root/.acme.sh/acme.sh"

THRESH_IP_DAYS=2
THRESH_DOMAIN_DAYS=3

SSL_BASE="/usr/local/nginx/ssl"


IP_SSL_DIR="$SSL_BASE/default"

FLAG="/tmp/acme_renew_need_restart_nginx.flag"
rm -f "$FLAG"

log() { echo -e "$*"; }

is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

nginx_stop_if_running() {
  if systemctl is-active --quiet nginx; then
    systemctl stop nginx
  fi
}

nginx_start_if_not_running() {
  if ! systemctl is-active --quiet nginx; then   
    systemctl start nginx
  fi
}

get_cert_end_time() {
  local host="$1"
  if is_ip "$host"; then
    echo | timeout 5 openssl s_client -connect "$host:443" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | awk -F= '{print $2}'
  else
    echo | timeout 5 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | awk -F= '{print $2}'
  fi
}

days_left_from_endtime() {
  local end_time="$1"
  local end_ts now_ts
  end_ts=$(date -d "$end_time" +%s 2>/dev/null || true)
  [ -z "${end_ts:-}" ] && return 1
  now_ts=$(date -u +%s)
  echo $(( (end_ts - now_ts) / 86400 ))
}

install_cert_to_dir() {
  local domain="$1"
  local ssl_dir="$2"

  mkdir -p "$ssl_dir"

  "$acme_bin" --install-cert -d "$domain" \
    --ecc \
    --key-file       "$ssl_dir/key.pem" \
    --fullchain-file "$ssl_dir/cert.pem" \
    --ca-file        "$ssl_dir/ca.pem" \
    --reloadcmd      "true" || true

  if [ -s "$ssl_dir/key.pem" ] && [ -s "$ssl_dir/cert.pem" ] && [ -s "$ssl_dir/ca.pem" ]; then
    return 0
  fi
  return 1
}

while IFS= read -r -d '' full; do
  dir="$(basename "$full")"
  primary="${dir%_ecc}"
  end_time="$(get_cert_end_time "$primary")"
  if [ -z "${end_time:-}" ]; then
    continue
  fi

  left_days="$(days_left_from_endtime "$end_time" || true)"
  if [ -z "${left_days:-}" ]; then
    continue
  fi

  log "  📅 Expiration Date: $end_time"
  log "  ⏳ Days remaining: $left_days"

  if is_ip "$primary"; then
    if [ "$left_days" -lt "$THRESH_IP_DAYS" ]; then
      nginx_stop_if_running
      issue_ok=0
      if "$acme_bin" --issue --server letsencrypt -d "$primary" \
          --certificate-profile shortlived --standalone \
          --keylength ec-256 --force; then
        issue_ok=1
      fi
      nginx_start_if_not_running
      if [ "$issue_ok" -eq 1 ]; then
       install_cert_to_dir "$primary" "$IP_SSL_DIR";
      fi
    fi

  else
    if [ "$left_days" -lt "$THRESH_DOMAIN_DAYS" ]; then
      if "$acme_bin" --renew -d "$primary" --ecc --force; then
        ssl_dir="$SSL_BASE/$primary"
        install_cert_to_dir "$primary" "$ssl_dir";
      fi
    fi
  fi

done < <(find "$dir_path" -maxdepth 1 -type d -name "*_ecc" -print0)

if [ -f "$FLAG" ]; then 
  systemctl restart nginx
  rm -f "$FLAG"
fi