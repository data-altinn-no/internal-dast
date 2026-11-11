#!/usr/bin/env bash
set -euo pipefail

# ZAP API-skann med Automation Framework (plans/zap-api.yaml).
# Kjører likt lokalt og i CI. Krever docker, curl og jq.
#
# Nødvendige variabler (fra .env eller miljøet):
#   API_PROJECT, API_BASE, OPENAPI_SPEC_URL, TOKEN_URL, TOKEN_BASIC_AUTH,
#   APIM_SUBSCRIPTION_KEY
# Valgfrie:
#   ZAP_IMAGE, ZAP_DOCKER_MEMORY

ZAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ZAP_DIR"

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

: "${API_PROJECT:?Mangler API_PROJECT (navn på det som skannes, brukes i rapportstien)}"
: "${API_BASE:?Mangler API_BASE (base-URL som skal skannes)}"
: "${OPENAPI_SPEC_URL:?Mangler OPENAPI_SPEC_URL (URL til OpenAPI/Swagger-spec)}"
: "${TOKEN_URL:?Mangler TOKEN_URL (endepunkt som returnerer bearer-token)}"
: "${TOKEN_BASIC_AUTH:?Mangler TOKEN_BASIC_AUTH ('Basic <base64>')}"
: "${APIM_SUBSCRIPTION_KEY:?Mangler APIM_SUBSCRIPTION_KEY (subscription key for API Management, sendes som Ocp-Apim-Subscription-Key)}"
: "${ZAP_IMAGE:=zaproxy/zap-stable}"
: "${ZAP_DOCKER_MEMORY:=8g}"   # ZAP setter Java-heap til 1/4 av vertens minne, så grensen må ha god margin

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
OUT_DIR="zap-output/${API_PROJECT}/${TS}"
mkdir -p "$OUT_DIR"
chmod a+w "$OUT_DIR"                       # ZAP kjører som egen bruker i containeren
export ZAP_REPORT_DIR="/zap/wrk/${OUT_DIR}"

echo "Henter token fra ${TOKEN_URL%%\?*}"
TOKEN="$(curl -fsS -H "Authorization: ${TOKEN_BASIC_AUTH}" "${TOKEN_URL}" | tr -d '\r\n')"
if [[ -z "$TOKEN" ]]; then
  echo "Token-endepunktet returnerte tomt svar" >&2
  exit 1
fi
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::add-mask::${TOKEN}"
fi
export TOKEN

# Henter OpenAPI-spec og retter eksempler som har både value og externalValue.
# OpenAPI tillater bare ett av dem, og ZAP stopper importen hvis begge finnes.
# Regel: det som er tomt fjernes. Har begge innhold, beholdes value.
# Bare objekter under "examples" endres. Filen lagres i rapportmappen og blir med i artifacten.
command -v jq >/dev/null || { echo "jq mangler" >&2; exit 1; }
SPEC_FILE="${OUT_DIR}/openapi.json"
echo "Henter OpenAPI-spec fra ${OPENAPI_SPEC_URL%%\?*}"
if ! curl -fsS "${OPENAPI_SPEC_URL}" | jq '
  def blank: . == null or . == "" or . == {} or . == [];
  def fix_example:
    if type == "object" and has("value") and has("externalValue") then
      if (.value | blank) and (.externalValue | blank) then del(.value, .externalValue)
      elif (.externalValue | blank) then del(.externalValue)
      elif (.value | blank) then del(.value)
      else del(.externalValue)
      end
    else . end;
  walk(if type == "object" and (.examples | type) == "object"
       then .examples |= map_values(fix_example)
       else . end)
' > "$SPEC_FILE"; then
  echo "Klarte ikke å hente eller lese OpenAPI-spec (må være JSON): ${OPENAPI_SPEC_URL%%\?*}" >&2
  exit 1
fi
export OPENAPI_SPEC_FILE="/zap/wrk/${SPEC_FILE}"

echo "Starter ZAP (${ZAP_IMAGE}), rapport til ${OUT_DIR}"
set +e
docker run --rm --memory "$ZAP_DOCKER_MEMORY" \
  -v "${ZAP_DIR}/plans:/zap/wrk/plans:ro" \
  -v "${ZAP_DIR}/zap-output:/zap/wrk/zap-output" \
  -e TOKEN -e APIM_SUBSCRIPTION_KEY -e API_BASE -e OPENAPI_SPEC_FILE -e ZAP_REPORT_DIR \
  "$ZAP_IMAGE" zap.sh -cmd -autorun /zap/wrk/plans/zap-api.yaml
status=$?
set -e

# ZAP legger egen filendelse på SARIF-rapporten. Gi den fast navn for upload-sarif.
for sarif in "${OUT_DIR}"/zap-report.sarif.*; do
  if [[ -e "$sarif" ]]; then
    mv -f "$sarif" "${OUT_DIR}/zap-report.sarif"
  fi
done

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "ZAP_REPORT_DIR=${OUT_DIR}" >> "$GITHUB_ENV"
fi

case "$status" in
  0) echo "Ferdig: ingen funn over terskelen i planen. Rapport: ${OUT_DIR}" ;;
  1) echo "Ferdig: funn på eller over terskelen i planen (exitStatus). Rapport: ${OUT_DIR}" >&2 ;;
  2) echo "Ferdig med advarsler fra planen (se loggen over). Rapport: ${OUT_DIR}"; status=0 ;;
  *) echo "ZAP avsluttet med exit-kode ${status}" >&2 ;;
esac
exit "$status"
