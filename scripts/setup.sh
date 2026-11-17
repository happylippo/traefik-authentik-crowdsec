#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker ist nicht installiert." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 ist nicht verfügbar." >&2
  exit 1
fi
for command_name in openssl python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name wird für die Einrichtung benötigt." >&2
    exit 1
  fi
done

if [[ ! -f .env ]]; then
  cp .env.sample .env
  echo ".env aus .env.sample angelegt. Prüfe darin bei Bedarf Hostnamen und Netzwerke."
fi

# Compose-Dateien verwenden absolute Bind-Mount-Pfade, unabhängig vom
# Verzeichnis, aus dem first_install.sh gestartet wurde.
sed -i "/^ABSOLUTE_PATH=/d" .env
printf 'ABSOLUTE_PATH=%s\n' "$PROJECT_DIR" >> .env

set_secret() {
  local name="$1"
  local value
  value="$(sed -n "s/^${name}=//p" .env | head -n 1)"
  if [[ -z "$value" || "$value" == "__GENERATE__" ]]; then
    value="$(openssl rand -hex 32)"
    if grep -q "^${name}=" .env; then
      sed -i "s|^${name}=.*|${name}=${value}|" .env
    else
      printf '%s=%s\n' "$name" "$value" >> .env
    fi
  fi
}

set_secret AUTHENTIK_SECRET_KEY
set_secret PG_PASS
set_secret BOUNCER_KEY_TRAEFIK
chmod 600 .env

BOUNCER_KEY="$(sed -n 's/^BOUNCER_KEY_TRAEFIK=//p' .env | head -n 1)"
if [[ ! "$BOUNCER_KEY" =~ ^[a-fA-F0-9]+$ ]]; then
  echo "BOUNCER_KEY_TRAEFIK muss ein hexadezimaler Schlüssel sein." >&2
  exit 1
fi

mkdir -p \
  data/crowdsec/config \
  data/crowdsec/data \
  data/crowdsec/data/crs-plugins/custom \
  data/traefik/dynamic_conf \
  data/traefik/certs \
  data/traefik/logs \
  data/crowdsec-manager/config \
  data/crowdsec-manager/logs \
  data/authentik/media \
  data/authentik/certs \
  data/authentik/custom-templates

touch data/crowdsec/allowlist.txt
chmod 600 data/crowdsec/allowlist.txt

copy_sample() {
  local source="$1"
  local destination="$2"
  if [[ ! -e "$destination" ]]; then
    cp "$source" "$destination"
  fi
}

copy_sample data/traefik/traefik.yml.sample data/traefik/traefik.yml
copy_sample data/crowdsec/.env.sample data/crowdsec/.env

# CrowdSec reads mounted log files and does not need Docker API access.
# Remove the legacy setting from existing installations as well.
sed -i '/^[[:space:]]*DOCKER_HOST=/d' data/crowdsec/.env
# These CrowdSec-to-socket-proxy addresses are no longer used.
sed -i '/^CROWDSEC_SOCKET_PROXY_IPV[46]=/d' .env
copy_sample data/crowdsec/acquis.yaml.sample data/crowdsec/acquis.yaml
copy_sample data/crowdsec/appsec.yaml.sample data/crowdsec/appsec.yaml
copy_sample data/crowdsec/crs-plugins/custom/http-version-before.conf data/crowdsec/data/crs-plugins/custom/http-version-before.conf
copy_sample data/traefik/.env.sample data/traefik/.env

while IFS= read -r -d '' sample; do
  destination="${sample%.sample}"
  if [[ "$sample" == "data/traefik/dynamic_conf/crowdsec.yml.sample" ]]; then
    continue
  fi
  copy_sample "$sample" "$destination"
done < <(find data/traefik/dynamic_conf -maxdepth 1 -type f -name '*.sample' -print0)

TZ_VALUE="$(sed -n 's/^TZ=//p' .env | head -n 1)"
BOUNCER_KEY_VALUE="$(sed -n 's/^BOUNCER_KEY_TRAEFIK=//p' .env | head -n 1)"
render_env_placeholders() {
  local file="$1"
  local temp_file
  temp_file="$(mktemp "${file}.XXXXXX")"
  TZ_VALUE="$TZ_VALUE" BOUNCER_KEY_VALUE="$BOUNCER_KEY_VALUE" awk '
    {
      gsub(/\$TZ/, ENVIRON["TZ_VALUE"])
      gsub(/\$BOUNCER_KEY_TRAEFIK/, ENVIRON["BOUNCER_KEY_VALUE"])
      print
    }
  ' "$file" > "$temp_file"
  cat "$temp_file" > "$file"
  rm -f "$temp_file"
}
render_env_placeholders data/traefik/.env
render_env_placeholders data/crowdsec/.env
chmod 600 data/traefik/.env
chmod 600 data/crowdsec/.env

for acme_file in \
  data/traefik/certs/acme.json \
  data/traefik/certs/acme_cloudflare.json \
  data/traefik/certs/acme_desec.json; do
  if [[ ! -f "$acme_file" ]]; then
    umask 077
    printf '{}\n' > "$acme_file"
  fi
  chmod 600 "$acme_file"
done

if [[ ! -f data/traefik/dynamic_conf/crowdsec.yml ]]; then
  BOUNCER_KEY="$(sed -n 's/^BOUNCER_KEY_TRAEFIK=//p' .env | head -n 1)"
  umask 077
  sed "s/__BOUNCER_KEY_TRAEFIK__/${BOUNCER_KEY}/" \
    data/traefik/dynamic_conf/crowdsec.yml.sample \
    > data/traefik/dynamic_conf/crowdsec.yml
fi

# These values are installer-managed and written as plain YAML scalars.
CAPTCHA_PROVIDER="$(sed -n 's/^CAPTCHA_PROVIDER=//p' .env | head -n 1)"
CAPTCHA_SITE_KEY="$(sed -n 's/^CAPTCHA_SITE_KEY=//p' .env | head -n 1)"
CAPTCHA_SECRET_KEY="$(sed -n 's/^CAPTCHA_SECRET_KEY=//p' .env | head -n 1)"
CAPTCHA_PROVIDER_VALUE="$CAPTCHA_PROVIDER" \
CAPTCHA_SITE_KEY_VALUE="$CAPTCHA_SITE_KEY" \
CAPTCHA_SECRET_KEY_VALUE="$CAPTCHA_SECRET_KEY" \
awk '
  /^          captchaProvider:/ {
    value = ENVIRON["CAPTCHA_PROVIDER_VALUE"]
    print "          captchaProvider:" (value == "" ? "" : " " value)
    next
  }
  /^          captchaSiteKey:/ {
    value = ENVIRON["CAPTCHA_SITE_KEY_VALUE"]
    print "          captchaSiteKey:" (value == "" ? "" : " " value)
    next
  }
  /^          captchaSecretKey:/ {
    value = ENVIRON["CAPTCHA_SECRET_KEY_VALUE"]
    print "          captchaSecretKey:" (value == "" ? "" : " " value)
    next
  }
  { print }
' data/traefik/dynamic_conf/crowdsec.yml > data/traefik/dynamic_conf/crowdsec.yml.tmp
mv data/traefik/dynamic_conf/crowdsec.yml.tmp data/traefik/dynamic_conf/crowdsec.yml
chmod 600 data/traefik/dynamic_conf/crowdsec.yml

echo "Starte CrowdSec zur Registrierung des Traefik-Bouncers ..."
./scripts/compose.sh up -d crowdsec

crowdsec_ready=false
for _ in $(seq 1 60); do
  if ./scripts/compose.sh exec -T crowdsec cscli bouncers list >/dev/null 2>&1; then
    crowdsec_ready=true
    break
  fi
  sleep 2
done

if [[ "$crowdsec_ready" != "true" ]]; then
  echo "CrowdSec wurde nicht rechtzeitig betriebsbereit." >&2
  ./scripts/compose.sh logs crowdsec
  exit 1
fi

# Centralized AllowLists require CrowdSec 1.6.8 or newer. The entries file is
# bind-mounted read-only; the AllowList itself persists in CrowdSec's database.
allowlist_name="installer_trusted_ips"
if [[ -s data/crowdsec/allowlist.txt ]]; then
  if ! ./scripts/compose.sh exec -T crowdsec cscli allowlists inspect "$allowlist_name" >/dev/null 2>&1; then
    ./scripts/compose.sh exec -T crowdsec cscli allowlists create "$allowlist_name" \
      --description "Trusted IP addresses and networks configured by the installer"
  fi
  existing_entries="$(./scripts/compose.sh exec -T crowdsec cscli allowlists inspect "$allowlist_name" --output json)"
  allowlist_missing_file="$(mktemp)"
  trap 'rm -f "$allowlist_missing_file"' EXIT
  ALLOWLIST_FILE=data/crowdsec/allowlist.txt \
  ALLOWLIST_JSON="$existing_entries" \
  python3 - "$allowlist_missing_file" <<'PY'
import json
import os
import sys

with open(os.environ["ALLOWLIST_FILE"], encoding="utf-8") as source:
    requested = list(dict.fromkeys(line.strip() for line in source if line.strip()))
data = json.loads(os.environ["ALLOWLIST_JSON"])

present = set()
def collect_strings(value):
    if isinstance(value, dict):
        for nested in value.values():
            collect_strings(nested)
    elif isinstance(value, list):
        for nested in value:
            collect_strings(nested)
    elif isinstance(value, str):
        present.add(value)

collect_strings(data)
with open(sys.argv[1], "w", encoding="utf-8") as output:
    for value in requested:
        if value not in present:
            output.write(value + "\n")
PY

mapfile -t allowlist_missing < "$allowlist_missing_file"
if ((${#allowlist_missing[@]})); then
  ./scripts/compose.sh exec -T crowdsec cscli allowlists add \
    "$allowlist_name" "${allowlist_missing[@]}"
fi
echo "CrowdSec-AllowList eingerichtet ($(wc -l < data/crowdsec/allowlist.txt | tr -d ' ') Einträge konfiguriert)."
rm -f "$allowlist_missing_file"
trap - EXIT
else
  echo "CrowdSec-AllowList übersprungen (keine Einträge konfiguriert)."
fi

./scripts/compose.sh exec -T crowdsec cscli bouncers delete TRAEFIK --ignore-missing >/dev/null
./scripts/compose.sh exec -T crowdsec cscli bouncers add TRAEFIK --key "$BOUNCER_KEY" >/dev/null

echo "Starte den Stack ..."
./scripts/compose.sh up -d --remove-orphans
echo "Stack gestartet. Authentik: https://$(sed -n 's/^AUTHENTIK_HOST=//p' .env | head -n 1)"
echo "Traefik-Dashboard: https://$(sed -n 's/^TRAEFIK_HOST=//p' .env | head -n 1)"
echo "CrowdSec-Manager: https://$(sed -n 's/^CROWDSEC_MANAGER_HOST=//p' .env | head -n 1)"
