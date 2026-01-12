#!/bin/bash
set -u

dir_path="/root/.acme.sh"
acme_bin="/root/.acme.sh/acme.sh"

THRESH_IP_DAYS=2
THRESH_DOMAIN_DAYS=3

SSL_BASE="/usr/local/nginx/ssl"
IP_SSL_DIR="$SSL_BASE/default"


PREFER_LOCAL_CERT=1

USE_ALPN_FOR_IP=0

FLAG="/tmp/acme_renew_need_restart_nginx.flag"
rm -f "$FLAG"

log() { echo -e "[$(date '+%F %T')] $*"; }

is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

nginx_stop_if_running() {
  if systemctl is-active --quiet nginx; then
    log "🛑 Stopping nginx..."
    systemctl stop nginx
  fi
}

nginx_start_if_not_running() {
  if ! systemctl is-active --quiet nginx; then
    log "🚀 Starting nginx..."
    systemctl start nginx
  fi
}


get_end_time_from_file() {
  local cert_file="$1"
  [ -s "$cert_file" ] || return 1
  openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | awk -F= '{print $2}'
}


get_end_time_remote() {
  local host="$1"
  local connect_host="$host"
  
  if [ "${PREFER_LOCAL_CERT:-0}" -eq 1 ]; then
    :
  fi

  if is_ip "$host"; then
    timeout 5 bash -c "echo | openssl s_client -connect '$connect_host:443' 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null" | awk -F= '{print $2}'
  else
    timeout 5 bash -c "echo | openssl s_client -servername '$host' -connect '$connect_host:443' 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null" | awk -F= '{print $2}'
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

  log "📥 Installing cert to: $ssl_dir"
  "$acme_bin" --install-cert -d "$domain" \
    --ecc \
    --key-file       "$ssl_dir/key.pem" \
    --fullchain-file "$ssl_dir/cert.pem" \
    --ca-file        "$ssl_dir/ca.pem" \
    --reloadcmd      "true" || true

  if [ -s "$ssl_dir/key.pem" ] && [ -s "$ssl_dir/cert.pem" ] && [ -s "$ssl_dir/ca.pem" ]; then
    touch "$FLAG"
    log "✅ Installed OK: $domain"
    return 0
  fi

  log "❌ Install failed (files missing): $domain"
  return 1
}

log "🔎 Scanning acme.sh ECC dirs under: $dir_path"
found_any=0

while IFS= read -r -d '' full; do
  found_any=1
  dir="$(basename "$full")"
  primary="${dir%_ecc}"

  log ""
  log "=============================="
  log "📌 Target: $primary"

  end_time=""

  if [ "${PREFER_LOCAL_CERT:-0}" -eq 1 ]; then

    if is_ip "$primary"; then
      end_time="$(get_end_time_from_file "$IP_SSL_DIR/cert.pem" || true)"
      [ -n "$end_time" ] || log "⚠️ Local cert not found: $IP_SSL_DIR/cert.pem"
    else
      
      end_time="$(get_end_time_from_file "$SSL_BASE/$primary/cert.pem" || true)"
      [ -n "$end_time" ] || log "⚠️ Local cert not found: $SSL_BASE/$primary/cert.pem"
    fi
  fi


  if [ -z "${end_time:-}" ]; then
    end_time="$(get_end_time_remote "$primary" || true)"
    [ -n "$end_time" ] || log "⚠️ Remote probe failed for $primary"
  fi

  if [ -z "${end_time:-}" ]; then
    log "⏭️ Skip: cannot get end date for $primary"
    continue
  fi

  left_days="$(days_left_from_endtime "$end_time" || true)"
  if [ -z "${left_days:-}" ]; then
    log "⏭️ Skip: cannot parse end date: $end_time"
    continue
  fi

  log "  📅 Expiration Date: $end_time"
  log "  ⏳ Days remaining: $left_days"

  if is_ip "$primary"; then
    if [ "$left_days" -lt "$THRESH_IP_DAYS" ]; then
      log "🔁 IP cert needs renew (threshold=$THRESH_IP_DAYS)"
      nginx_stop_if_running

      issue_ok=0
      if [ "${USE_ALPN_FOR_IP:-0}" -eq 1 ]; then
        log "🌐 Issue via ALPN(443): $primary"
        if "$acme_bin" --issue --server letsencrypt -d "$primary" \
            --certificate-profile shortlived --alpn \
            --keylength ec-256 --force; then
          issue_ok=1
        fi
      else
        log "🌐 Issue via standalone(80): $primary"
        if "$acme_bin" --issue --server letsencrypt -d "$primary" \
            --certificate-profile shortlived --standalone \
            --keylength ec-256 --force; then
          issue_ok=1
        fi
      fi

      nginx_start_if_not_running

      if [ "$issue_ok" -eq 1 ]; then
        install_cert_to_dir "$primary" "$IP_SSL_DIR"
      fi
    fi
  else
    if [ "$left_days" -lt "$THRESH_DOMAIN_DAYS" ]; then
      log "🔁 Domain cert needs renew (threshold=$THRESH_DOMAIN_DAYS): $primary"
      if "$acme_bin" --renew -d "$primary" --ecc --force; then
        ssl_dir="$SSL_BASE/$primary"
        install_cert_to_dir "$primary" "$ssl_dir"
      else
        log "❌ Renew failed: $primary"
      fi
    fi
  fi

done < <(find "$dir_path" -maxdepth 1 -type d -name "*_ecc" -print0)

if [ "$found_any" -eq 0 ]; then
  log "⚠️ No *_ecc directories found under $dir_path"
fi

if [ -f "$FLAG" ]; then
  log "♻️ Restart nginx due to cert updates..."
  systemctl restart nginx
  rm -f "$FLAG"
  log "✅ nginx restarted."
else
  log "ℹ️ No cert installed. nginx restart not needed."
fi


