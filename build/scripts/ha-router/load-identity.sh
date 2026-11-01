# Sourced by install.sh after preflight. Credentials stay on the router.
identity=/etc/ha-quick/identity.conf
if [ -f "$identity" ]; then . "$identity"; fi
if [ -z "${HA_ET_SECRET:-}" ] && [ -f /etc/easytier/config.toml ] && grep -q '^network_name = "yksnet"$' /etc/easytier/config.toml; then
    HA_ET_SECRET=$(sed -n 's/^network_secret = "\([A-Za-z0-9_-]*\)"$/\1/p' /etc/easytier/config.toml)
fi
if [ -z "${HA_NPS_VKEY:-}" ] && [ "$(uci -q get npc.@npc[0].server_addr)" = hhc.gqru.com ]; then
    HA_NPS_VKEY=$(uci -q get npc.@npc[0].vkey || true)
fi
read_secret() {
    [ -t 0 ] || die 'Missing local credentials: create /etc/ha-quick/identity.conf (see README)'
    printf '%s: ' "$1" >&2
    stty -echo
    trap 'stty echo' EXIT HUP INT TERM
    IFS= read -r reply
    stty echo
    trap - EXIT HUP INT TERM
    printf '\n' >&2
}
if [ -z "${HA_ET_SECRET:-}" ] || [ "$HA_ET_SECRET" = __HA_ET_SECRET__ ]; then
    read_secret 'EasyTier network secret'; HA_ET_SECRET=$reply
fi
if [ -z "${HA_NPS_VKEY:-}" ] || [ "$HA_NPS_VKEY" = __HA_NPS_VKEY__ ]; then
    read_secret 'Shared primary NPS vkey'; HA_NPS_VKEY=$reply
fi
# These identities use alphanumerics, underscore and hyphen; reject placeholders.
for key in "$HA_ET_SECRET" "$HA_NPS_VKEY"; do
    case "$key" in ''|*[!A-Za-z0-9_-]*) die 'Keys must be nonempty alphanumeric/underscore/hyphen values' ;; esac
done
mkdir -p /etc/ha-quick
printf "HA_ET_SECRET='%s'\nHA_NPS_VKEY='%s'\n" "$HA_ET_SECRET" "$HA_NPS_VKEY" >"$identity"
chmod 600 "$identity"
private_payload=$(mktemp -d /tmp/ha-identity.XXXXXX)
trap 'rm -rf "$private_payload"' EXIT
cp "$p/"* "$private_payload/"
sed -i "s/__HA_ET_SECRET__/$HA_ET_SECRET/g" "$private_payload/easytier-$node.toml"
cp "$private_payload/npc.uci" "$private_payload/npc"
uci -c "$private_payload" set npc.@npc[0].vkey="$HA_NPS_VKEY"
uci -c "$private_payload" commit npc
# UCI expects a file named npc, while the reference payload uses npc.uci.
cp "$private_payload/npc" "$private_payload/npc.uci"
p=$private_payload
