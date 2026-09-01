#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
resources_dir="$project_root/Sources/Switch/Resources"
localizable_catalog="$resources_dir/Localizable.xcstrings"
info_catalog="$resources_dir/InfoPlist.xcstrings"
locale_stub="$resources_dir/zh-Hans.lproj/.gitkeep"
derived_data_path="${1:-}"

fail() {
    echo "localization validation failed: $*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "$localizable_catalog" ]] || fail "missing $localizable_catalog"
[[ -f "$info_catalog" ]] || fail "missing $info_catalog"
[[ -f "$locale_stub" ]] || fail "missing Simplified Chinese locale stub"

jq empty "$localizable_catalog"
jq empty "$info_catalog"
jq -e '.sourceLanguage == "en" and .version == "1.0" and (.strings | type == "object")' \
    "$localizable_catalog" >/dev/null
jq -e '.sourceLanguage == "en" and .version == "1.0" and (.strings | type == "object")' \
    "$info_catalog" >/dev/null

# Accept both a direct stringUnit and plural/device variations. Every localized leaf
# must be explicitly translated and non-empty.
incomplete_catalog_entries="$(jq -r '
    def complete:
        ([.. | objects | .stringUnit? // empty]) as $units
        | ($units | length) > 0
          and ($units | all(
              .state == "translated"
              and (.value | type == "string" and length > 0)
          ));
    .strings | to_entries[]
    | select(.value.shouldTranslate != false)
    | select(
        ((.value.localizations.en // {}) | complete | not)
        or ((.value.localizations["zh-Hans"] // {}) | complete | not)
      )
    | .key
' "$localizable_catalog")"
[[ -z "$incomplete_catalog_entries" ]] \
    || fail "catalog entries lack complete en/zh-Hans translations: $incomplete_catalog_entries"

for permission_key in NSAppleEventsUsageDescription NSScreenCaptureUsageDescription; do
    jq -e --arg key "$permission_key" '
        .strings[$key].localizations["zh-Hans"].stringUnit
        | .state == "translated"
          and (.value | type == "string" and length > 0)
    ' "$info_catalog" >/dev/null \
        || fail "InfoPlist.xcstrings lacks a translated zh-Hans $permission_key"
done

[[ -n "$derived_data_path" ]] || exit 0
[[ -d "$derived_data_path" ]] || fail "DerivedData directory does not exist: $derived_data_path"

validation_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/switch-localization.XXXXXX")"
trap 'rm -rf "$validation_tmp_dir"' EXIT

stringsdata_files=()
stringsdata_root="$derived_data_path/Build/Intermediates.noindex/Switch.build"
[[ -d "$stringsdata_root" ]] \
    || fail "Switch build intermediates do not exist: $stringsdata_root"
while IFS= read -r -d '' stringsdata_file; do
    stringsdata_files+=("$stringsdata_file")
done < <(find "$stringsdata_root" -type f -name '*.stringsdata' -print0)

((${#stringsdata_files[@]} > 0)) \
    || fail "no .stringsdata files were emitted under $derived_data_path"

extracted_keys="$validation_tmp_dir/extracted-keys.json"
jq -s '[.[].tables.Localizable[]?.key] | unique' "${stringsdata_files[@]}" > "$extracted_keys"
jq -e 'length > 0' "$extracted_keys" >/dev/null \
    || fail ".stringsdata files contained no Localizable keys"

missing_keys="$(jq -r --slurpfile extracted "$extracted_keys" '
    .strings as $catalog
    | $extracted[0][] as $key
    | select($catalog[$key] == null)
    | $key
' "$localizable_catalog")"
[[ -z "$missing_keys" ]] \
    || fail "extracted keys are missing from Localizable.xcstrings: $missing_keys"

incomplete_extracted_keys="$(jq -r --slurpfile extracted "$extracted_keys" '
    def complete:
        ([.. | objects | .stringUnit? // empty]) as $units
        | ($units | length) > 0
          and ($units | all(
              .state == "translated"
              and (.value | type == "string" and length > 0)
          ));
    .strings as $catalog
    | $extracted[0][] as $key
    | $catalog[$key] as $entry
    | select($entry != null and $entry.shouldTranslate != false)
    | select(
        (($entry.localizations.en // {}) | complete | not)
        or (($entry.localizations["zh-Hans"] // {}) | complete | not)
      )
    | $key
' "$localizable_catalog")"
[[ -z "$incomplete_extracted_keys" ]] \
    || fail "extracted keys lack complete en/zh-Hans translations: $incomplete_extracted_keys"

echo "Validated $(jq 'length' "$extracted_keys") extracted localization keys."
