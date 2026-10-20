#!/bin/zsh
# Synthetic, quota-free agy metadata, shared by catalog and rendered UI checks.
set -eu
if [[ "$1" == --version ]]; then printf 'agy fixture\n'; exit 0; fi
if [[ -f "${0:h}/catalog-unavailable" ]]; then exit 7; fi
if [[ "$1" == models ]]; then
    printf 'model-a-low\tModel A (Low)\nmodel-a-high\tModel A (High)\nfixed-medium\tFixed (Medium)\n'
    exit 0
fi
[[ "$1" == -p && ( "$2" == /model || "$2" == /effort ) ]] || exit 9
# The UI check can hold the first metadata reply to render the loading state.
if [[ -p "${0:h}/catalog-ready" ]]; then
    IFS= read -r signal < "${0:h}/catalog-ready"
    /bin/rm "${0:h}/catalog-ready"
fi
command="$2"
model=''
while (( $# )); do
    if [[ "$1" == --model ]]; then shift; model="$1"; fi
    shift
done
if [[ "$command" == /model ]]; then
    if [[ "$model" == fixed ]]; then
        printf '%s' '{"status":"SUCCESS","command":{"name":"model","data":{"id":"fixed-medium","label":"Fixed (Medium)","effort":"medium"}}}'
    else
        printf '%s' '{"status":"SUCCESS","command":{"name":"model","data":{"id":"model-a-high","label":"Model A (High)","effort":"high"}}}'
    fi
elif [[ "$model" == fixed ]]; then
    printf '%s' '{"status":"SUCCESS","command":{"name":"effort","data":{"adjustable":false}}}'
else
    printf '%s' '{"status":"SUCCESS","command":{"name":"effort","data":{"adjustable":true,"current":"high","available":["low","high"]}}}'
fi
