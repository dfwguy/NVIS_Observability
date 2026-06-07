#!/usr/bin/env bash
# wizard-snippet.sh -- NetQ wizard prompt block.
#
# This file is intended to be sourced by the master nvis-platform install.sh
# so the unified wizard can prompt for NetQ (NVIDIA Cumulus fabric monitoring)
# settings only if the operator opts into the integration.
#
# After prompt_netq_block returns, the following environment variables are
# exported for the caller:
#   NETQ_URL    NetQ telemetry server base URL (e.g. https://netq.example.com)
#   NETQ_TOKEN  Bearer token (set if auth type is "token")
#   NETQ_USER   API username   (set if auth type is "password")
#   NETQ_PASS   API password   (set if auth type is "password")
#   INT_NETQ    "true" once the user has filled out the block.

prompt_netq_block() {
    local url auth_type token user pass

    echo
    echo "=== NetQ (Cumulus fabric monitoring) ==="

    # --- URL --------------------------------------------------------------
    while true; do
        printf "NetQ API URL (e.g. https://netq.example.com): "
        read -r url
        if [[ "$url" =~ ^https?:// ]]; then
            break
        fi
        echo "  ! URL must begin with http:// or https://"
    done
    # Strip trailing slash for a tidy NETQ_URL.
    url="${url%/}"

    # --- auth type --------------------------------------------------------
    while true; do
        printf "Auth type [token/password]: "
        read -r auth_type
        auth_type="${auth_type,,}"
        case "$auth_type" in
            token|password) break ;;
            *) echo "  ! enter 'token' or 'password'" ;;
        esac
    done

    if [[ "$auth_type" == "token" ]]; then
        while true; do
            printf "NetQ bearer token (hidden): "
            stty -echo
            read -r token
            stty echo
            echo
            if [[ -n "$token" ]]; then
                break
            fi
            echo "  ! token must not be empty"
        done
        user=""
        pass=""
    else
        printf "NetQ API username: "
        read -r user
        while true; do
            printf "NetQ API password (hidden): "
            stty -echo
            read -r pass
            stty echo
            echo
            if [[ -n "$pass" ]]; then
                break
            fi
            echo "  ! password must not be empty"
        done
        token=""
    fi

    export NETQ_URL="$url"
    export NETQ_TOKEN="$token"
    export NETQ_USER="$user"
    export NETQ_PASS="$pass"
    export INT_NETQ="true"
}
