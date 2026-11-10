#!/usr/bin/env bash
set -euo pipefail

# Skriver om ZAPs SARIF-rapport så GitHub code scanning godtar den og viser den ryddig.
#
# 1. Ett funn per regel. ZAP lager ett funn per adresse, så samme feil kommer mange ganger.
#    Her slås de sammen til ett funn per ZAP-regel, med alle adressene listet i meldingen
#    (med angrep og bevis der ZAP har det).
# 2. Pseudosti. GitHub krever at funn peker på en fil i repoet. Hvert funn får stien
#    dast/<regel-id>-<regelnavn>. Stien finnes ikke, og det er greit.
# 3. Alvorlighetsgrad. ZAPs risiko (High/Medium/Low) settes som security-severity på regelen,
#    så GitHub viser High, Medium eller Low i stedet for Error, Warning eller Note.
#    Informational får ingen security-severity og vises som Note.
#
# Bruk: sarif-for-github.sh <zap-report.sarif>   (filen skrives om på stedet, krever jq)

FILE="${1:?Bruk: sarif-for-github.sh <sarif-fil>}"
if [[ ! -f "$FILE" ]]; then
  echo "Fant ikke SARIF-fil: $FILE" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "jq mangler" >&2; exit 1; }

MAX_URLS="${ZAP_SARIF_MAX_URLS:-100}"
# Sett Tool navn
TOOL_NAME="${ZAP_SARIF_TOOL_NAME:-ZAP DAST}"

TMP="$(mktemp)"
jq --argjson maxUrls "$MAX_URLS" --arg toolName "$TOOL_NAME" '
  def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
  def trunc($n): if length > $n then .[:$n] + "…" else . end;
  def oneline: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
  def rank: {"error": 3, "warning": 2, "note": 1, "none": 0}[.] // 0;
  # GitHub: 7.0-8.9 = High, 4.0-6.9 = Medium, 0.1-3.9 = Low. Informational får ingen.
  def severity: {"error": "8.0", "warning": "5.5", "note": "2.0"}[.];

  .runs[] |= (
    (.tool.driver.rules // []) as $rules
    | ([ $rules[] | {key: .id, value: .} ] | from_entries) as $rulemap
    | .results = (
        (.results // [])
        | group_by(.ruleId)
        | map(
            . as $group
            | $group[0].ruleId as $rid
            | ($rulemap[$rid] // {}) as $rule
            | ($rule.name // $group[0].message.text // $rid) as $name
            | ([ $group[] | (.level // "none") ] | max_by(rank)) as $level
            | ([ $rule.relationships[]? | select(.target.toolComponent.name == "CWE")
                 | "CWE-" + (.target.id | tostring) ] | unique) as $cwes
            | ($rule.fullDescription.text // $group[0].message.text // $name | oneline) as $desc
            | ([ $group[] | . as $r | (.locations // [])[] | {
                  url:      (.physicalLocation.artifactLocation.uri // ""),
                  attack:   (.properties.attack // "" | oneline),
                  evidence: (.physicalLocation.region.snippet.text // "" | oneline),
                  info:     ($r.message.text // "" | oneline)
                } | select(.url != "") ]
               | unique_by([.url, .attack])) as $hits
            | ([ $hits[].url ] | unique | length) as $nUrls
            | ($hits | .[:$maxUrls]) as $shown
            | ([ $shown[]
                 | "- " + .url
                   + (if .attack != "" then "  [angrep: " + (.attack | trunc(120)) + "]" else "" end)
                   + (if .evidence != "" then "  [bevis: " + (.evidence | trunc(160)) + "]" else "" end)
                   + (if .info != "" and .info != $desc then "  [info: " + (.info | trunc(200)) + "]" else "" end)
               ] | join("\n")) as $list
            | ($desc
               + (if ($cwes | length) > 0 then "\n\n" + ($cwes | join(", ")) else "" end)
               + "\n\nFunnet på " + ($nUrls | tostring) + " adresse" + (if $nUrls == 1 then "" else "r" end) + ":\n"
               + $list
               + (if ($hits | length) > $maxUrls then "\n- … og " + (($hits | length) - $maxUrls | tostring) + " til (se HTML-rapporten)" else "" end)
              ) as $text
            | {
                ruleId: $rid,
                level: $level,
                message: { text: $text, markdown: $text },
                locations: [ {
                  physicalLocation: {
                    artifactLocation: { uri: ("dast/" + $rid + "-" + ($name | slug)), uriBaseId: "%SRCROOT%" },
                    region: { startLine: 1 }
                  }
                } ],
                properties: { urls: ([ $hits[].url ] | unique), cwe: $cwes }
              }
          )
      )
    | .tool.driver.name = $toolName
    | .tool.driver.rules = ($rules | map(
        (.defaultConfiguration.level // "none") as $l
        | .properties = ((.properties // {})
            + { tags: (((.properties.tags // []) + ["security", "dast"]) | unique) }
            + (if ($l | severity) then { "security-severity": ($l | severity) } else {} end))
      ))
  )
' "$FILE" > "$TMP"
mv "$TMP" "$FILE"
echo "SARIF tilpasset code scanning: $FILE ($(jq '[.runs[].results | length] | add // 0' "$FILE") funn, ett per regel)"
