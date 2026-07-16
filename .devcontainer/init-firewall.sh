#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Default-deny egress. Everything the container is allowed to reach is resolved
# to IPs here and added to the `allowed-domains` ipset. Adding a domain to
# ALLOWED_DOMAINS below is the only supported way to widen the network.

# Sourced from https://code.claude.com/docs/en/network-config#network-access-requirements
# Do not edit from memory; re-check that page when Claude Code changes.
ALLOWED_DOMAINS=(
  # Claude Code: inference
  "api.anthropic.com"
  # Claude Code: authentication. Login fails without these.
  "claude.ai"
  "platform.claude.com"
  # Claude Code: MCP connectors (on by default for claude.ai auth),
  # plugin downloads, release notes
  "mcp-proxy.anthropic.com"
  "downloads.claude.ai"
  "raw.githubusercontent.com"
  # Plugin metadata. NOTE: this is all of Google Cloud Storage, not one bucket,
  # so it is the widest hole in this allowlist. Drop it if you do not use /plugin.
  "storage.googleapis.com"
  # Optional telemetry. Remove these and set
  # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 to opt out instead.
  "sentry.io"
  "statsig.com"
  # Package registries
  "registry.npmjs.org"
  "pypi.org"
  "files.pythonhosted.org"
  # VS Code extensions / server bits
  "marketplace.visualstudio.com"
  "update.code.visualstudio.com"
)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# DNS and SSH must come up before the default-drop policy lands.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub publishes its egress ranges; pull them rather than resolving the names,
# because github.com fans out across a lot of IPs that rotate.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s --connect-timeout 10 https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
  echo "ERROR: Failed to fetch GitHub IP ranges"
  exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
  echo "ERROR: GitHub API response missing expected fields"
  exit 1
fi

while read -r cidr; do
  if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: Invalid CIDR from GitHub meta: $cidr"
    exit 1
  fi
  ipset add allowed-domains "$cidr" 2>/dev/null || true
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

for domain in "${ALLOWED_DOMAINS[@]}"; do
  echo "Resolving $domain..."
  ips=$(dig +short A "$domain" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
  if [ -z "$ips" ]; then
    echo "ERROR: Failed to resolve $domain"
    exit 1
  fi
  while read -r ip; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done <<< "$ips"
done

# The host network must stay reachable or the VS Code server loses the container.
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
  echo "ERROR: Failed to detect host IP"
  exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

echo "Firewall configured. Verifying..."

if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
  echo "ERROR: Verification failed - example.com is reachable but should not be"
  exit 1
fi
echo "OK: example.com blocked as expected"

if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
  echo "ERROR: Verification failed - api.github.com is unreachable but should not be"
  exit 1
fi
echo "OK: api.github.com reachable as expected"
