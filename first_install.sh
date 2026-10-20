#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker ist nicht installiert oder nicht im PATH." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 ist nicht verfügbar." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Der Docker-Daemon ist nicht erreichbar. Starte Docker oder prüfe deine Berechtigungen." >&2
  exit 1
fi
for command_name in openssl sed; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name wird für die Erstinstallation benötigt." >&2
    exit 1
  fi
done

if [[ ! -t 0 ]]; then
  echo "Die Erstinstallation benötigt eine interaktive Konsole für die Konfigurationsabfragen." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.sample" "$PROJECT_DIR/.env"
fi
chmod 600 "$PROJECT_DIR/.env"

env_get() {
  local file="$1"
  local key="$2"
  awk -v prefix="${key}=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$file"
}

env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temp_file
  temp_file="$(mktemp "${file}.XXXXXX")"
  FIRST_INSTALL_VALUE="$value" awk -v key="$key" '
    BEGIN { prefix = key "="; value = ENVIRON["FIRST_INSTALL_VALUE"] }
    index($0, prefix) == 1 {
      if (!updated) print prefix value
      updated = 1
      next
    }
    { print }
    END { if (!updated) print prefix value }
  ' "$file" > "$temp_file"
  chmod 600 "$temp_file"
  mv "$temp_file" "$file"
}

prompt_env() {
  local key="$1"
  local label="$2"
  local current answer
  current="$(env_get "$PROJECT_DIR/.env" "$key")"
  read -r -p "$label [$current]: " answer
  if [[ -n "$answer" ]]; then
    env_set "$PROJECT_DIR/.env" "$key" "$answer"
  fi
}

echo
echo "Traefik TLS-Einstellungen"
current_resolver="$(env_get "$PROJECT_DIR/.env" SERVICES_TRAEFIK_LABELS_TRAEFIK_CERTRESOLVER)"
case "$current_resolver" in
  cloudflare_resolver|desec_resolver) resolver_default="$current_resolver" ;;
  *) resolver_default=cloudflare_resolver ;;
esac
echo "[1] Cloudflare DNS (cloudflare_resolver)"
echo "[2] deSEC DNS (desec_resolver)"
echo "[3] Let's Encrypt TLS-ALPN (letsencrypt)"
read -r -p "Zertifikat-Resolver [$resolver_default]: " resolver_answer
resolver_answer="${resolver_answer:-$resolver_default}"
case "$resolver_answer" in
  1|cloudflare|cloudflare_resolver) resolver=cloudflare_resolver ;;
  2|desec|desec_resolver) resolver=desec_resolver ;;
  3|letsencrypt) resolver=letsencrypt ;;
  *)
    echo "Unbekannter Resolver: $resolver_answer" >&2
    echo "Erlaubt sind cloudflare_resolver, desec_resolver oder letsencrypt." >&2
    exit 1
    ;;
esac
env_set "$PROJECT_DIR/.env" SERVICES_TRAEFIK_LABELS_TRAEFIK_CERTRESOLVER "$resolver"
if [[ "$resolver" == "letsencrypt" ]]; then
  echo "Hinweis: Der konfigurierte TLS-ALPN-Resolver kann keine Wildcard-Zertifikate ausstellen."
  echo "Für *.example.de benötigst du Cloudflare oder deSEC mit DNS-API-Token."
fi

prompt_env TRAEFIK_CERT_EMAIL "E-Mail-Adresse für ACME-Zertifikate"
cert_email="$(env_get "$PROJECT_DIR/.env" TRAEFIK_CERT_EMAIL)"
if [[ ! "$cert_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "Bitte eine gültige E-Mail-Adresse für die Zertifikate angeben." >&2
  exit 1
fi

prompt_env TRAEFIK_CERT_DOMAIN "Zertifikats-Domain (z. B. example.de)"
prompt_env TRAEFIK_CERT_WILDCARD "Wildcard-Domain (z. B. *.example.de)"
prompt_env AUTHENTIK_HOST "Authentik-Hostname"
prompt_env TRAEFIK_HOST "Traefik-Dashboard-Hostname"
prompt_env CROWDSEC_MANAGER_HOST "CrowdSec-Manager-Hostname"

echo
echo "CrowdSec CAPTCHA-Einstellungen"
current_captcha_provider="$(env_get "$PROJECT_DIR/.env" CAPTCHA_PROVIDER)"
case "$current_captcha_provider" in
  hcaptcha|recaptcha|turnstile) captcha_provider_default="$current_captcha_provider" ;;
  *) captcha_provider_default=none ;;
esac
echo "[1] Deaktiviert (CAPTCHA-Challenges werden ohne Provider abgewiesen)"
echo "[2] hCaptcha"
echo "[3] reCAPTCHA"
echo "[4] Cloudflare Turnstile"
read -r -p "CAPTCHA-Provider [$captcha_provider_default]: " captcha_provider_answer
captcha_provider_answer="${captcha_provider_answer:-$captcha_provider_default}"
case "${captcha_provider_answer,,}" in
  1|none|deaktiviert|aus) captcha_provider= ;;
  2|hcaptcha) captcha_provider=hcaptcha ;;
  3|recaptcha|reCAPTCHA) captcha_provider=recaptcha ;;
  4|turnstile|cloudflare) captcha_provider=turnstile ;;
  *)
    echo "Unbekannter CAPTCHA-Provider: $captcha_provider_answer" >&2
    echo "Erlaubt sind none, hcaptcha, recaptcha oder turnstile." >&2
    exit 1
    ;;
esac
env_set "$PROJECT_DIR/.env" CAPTCHA_PROVIDER "$captcha_provider"

if [[ -n "$captcha_provider" ]]; then
  captcha_site_key="$(env_get "$PROJECT_DIR/.env" CAPTCHA_SITE_KEY)"
  read -r -p "CAPTCHA-Site-Key${captcha_site_key:+ [gespeichert]}: " captcha_site_key_answer
  if [[ -n "$captcha_site_key_answer" ]]; then
    captcha_site_key="$captcha_site_key_answer"
    env_set "$PROJECT_DIR/.env" CAPTCHA_SITE_KEY "$captcha_site_key"
  fi
  if [[ -z "$captcha_site_key" ]]; then
    echo "Für $captcha_provider ist ein CAPTCHA-Site-Key erforderlich." >&2
    exit 1
  fi

  captcha_secret_key="$(env_get "$PROJECT_DIR/.env" CAPTCHA_SECRET_KEY)"
  read -r -s -p "CAPTCHA-Secret-Key (Eingabe bleibt verborgen; leer behält den gespeicherten Schlüssel): " captcha_secret_key_answer
  echo
  if [[ -n "$captcha_secret_key_answer" ]]; then
    captcha_secret_key="$captcha_secret_key_answer"
    env_set "$PROJECT_DIR/.env" CAPTCHA_SECRET_KEY "$captcha_secret_key"
  fi
  if [[ -z "$captcha_secret_key" ]]; then
    echo "Für $captcha_provider ist ein CAPTCHA-Secret-Key erforderlich." >&2
    exit 1
  fi
else
  env_set "$PROJECT_DIR/.env" CAPTCHA_SITE_KEY ""
  env_set "$PROJECT_DIR/.env" CAPTCHA_SECRET_KEY ""
fi

read -r -p "Cloudflare-Proxy-IP-Netze als Forwarded Headers vertrauen? [j/N]: " cloudflare_forwarded_answer
case "${cloudflare_forwarded_answer,,}" in
  j|ja|y|yes) use_cloudflare_forwarded_headers=true ;;
  ""|n|nein|no) use_cloudflare_forwarded_headers=false ;;
  *)
    echo "Bitte mit ja oder nein antworten." >&2
    exit 1
    ;;
esac

traefik_config="$PROJECT_DIR/data/traefik/traefik.yml"
if [[ ! -f "$traefik_config" ]]; then
  cp "$PROJECT_DIR/data/traefik/traefik.yml.sample" "$traefik_config"
fi

# Keep the ACME contact address in sync for all configured certificate resolvers.
cert_email_yaml="${cert_email//\'/\'\'}"
cert_email_yaml="'$cert_email_yaml'"
email_temp_config="$(mktemp "${traefik_config}.XXXXXX")"
if ! CERT_EMAIL_YAML="$cert_email_yaml" awk '
  /^[[:space:]]*email:/ {
    prefix = substr($0, 1, index($0, "email:") - 1)
    print prefix "email: " ENVIRON["CERT_EMAIL_YAML"]
    replaced++
    next
  }
  { print }
  END { if (replaced == 0) exit 42 }
' "$traefik_config" > "$email_temp_config"; then
  rm -f "$email_temp_config"
  echo "In $traefik_config wurde keine certificatesResolvers-E-Mail-Einstellung gefunden; Datei nicht geändert." >&2
  exit 1
fi
cat "$email_temp_config" > "$traefik_config"
rm -f "$email_temp_config"

replacement_file="$(mktemp)"
temp_config="$(mktemp "${traefik_config}.XXXXXX")"
trap 'rm -f "$replacement_file" "$temp_config"' EXIT

if [[ "$use_cloudflare_forwarded_headers" == true ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl wird benötigt, um die aktuellen Cloudflare-IP-Netze abzurufen." >&2
    exit 1
  fi
  cloudflare_download_dir="$(mktemp -d)"
  trap 'rm -rf "$cloudflare_download_dir"; rm -f "$replacement_file" "$temp_config"' EXIT
  if ! curl --fail --silent --show-error --location --max-time 20 \
    https://www.cloudflare.com/ips-v4 \
    --output "$cloudflare_download_dir/ips-v4" ||
    ! curl --fail --silent --show-error --location --max-time 20 \
      https://www.cloudflare.com/ips-v6 \
      --output "$cloudflare_download_dir/ips-v6"; then
    echo "Cloudflare-IP-Listen konnten nicht abgerufen werden." >&2
    exit 1
  fi
  if [[ ! -s "$cloudflare_download_dir/ips-v4" || ! -s "$cloudflare_download_dir/ips-v6" ]] ||
    grep -Evq '^[0-9A-Fa-f:.]+/[0-9]{1,3}$' "$cloudflare_download_dir/ips-v4" ||
    grep -Evq '^[0-9A-Fa-f:.]+/[0-9]{1,3}$' "$cloudflare_download_dir/ips-v6"; then
    echo "Die abgerufenen Cloudflare-IP-Listen sind leer oder haben ein unerwartetes Format." >&2
    exit 1
  fi
  {
    echo "    # BEGIN CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE"
    echo "    forwardedHeaders:"
    echo "      trustedIPs:"
    while IFS= read -r cidr || [[ -n "$cidr" ]]; do
      printf '        - "%s"\n' "$cidr"
    done < "$cloudflare_download_dir/ips-v4"
    while IFS= read -r cidr || [[ -n "$cidr" ]]; do
      printf '        - "%s"\n' "$cidr"
    done < "$cloudflare_download_dir/ips-v6"
    echo "    # END CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE"
  } > "$replacement_file"
else
  printf '    # __CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE__\n' > "$replacement_file"
fi

if ! awk -v replacement_file="$replacement_file" '
  function emit_replacement(line) {
    while ((getline line < replacement_file) > 0) print line
    close(replacement_file)
  }
  /# BEGIN CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE/ {
    inside_managed_block = 1
    found_marker = 1
    emit_replacement()
    next
  }
  /# END CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE/ {
    if (inside_managed_block) {
      inside_managed_block = 0
      next
    }
  }
  inside_managed_block { next }
  /# __CLOUDFLARE_FORWARDED_HEADERS_WEBSECURE__/ {
    found_marker = 1
    emit_replacement()
    next
  }
  { print }
  END { if (!found_marker) exit 42 }
' "$traefik_config" > "$temp_config"; then
  echo "In $traefik_config wurde die Cloudflare-Platzhalterstelle nicht gefunden; Datei nicht geändert." >&2
  exit 1
fi
cat "$temp_config" > "$traefik_config"
rm -f "$replacement_file" "$temp_config"
if [[ -n "${cloudflare_download_dir:-}" ]]; then
  rm -rf "$cloudflare_download_dir"
fi
trap - EXIT

traefik_env="$PROJECT_DIR/data/traefik/.env"
if [[ ! -f "$traefik_env" ]]; then
  cp "$PROJECT_DIR/data/traefik/.env.sample" "$traefik_env"
fi
chmod 600 "$traefik_env"

prompt_api_token() {
  local key="$1"
  local label="$2"
  local token current
  current="$(env_get "$traefik_env" "$key")"
  read -r -s -p "$label (Eingabe bleibt verborgen; leer behält den gespeicherten Token): " token
  echo
  if [[ -n "$token" ]]; then
    env_set "$traefik_env" "$key" "$token"
  elif [[ -z "$current" ]]; then
    echo "Für $resolver ist ein API-Token erforderlich." >&2
    exit 1
  fi
}

case "$resolver" in
  cloudflare_resolver)
    prompt_api_token CF_DNS_API_TOKEN "Cloudflare API-Token"
    ;;
  desec_resolver)
    prompt_api_token DESEC_TOKEN "deSEC API-Token"
    ;;
esac

echo "Richte den Stack ein und starte die Container ..."
exec "$PROJECT_DIR/scripts/setup.sh" "$@"
