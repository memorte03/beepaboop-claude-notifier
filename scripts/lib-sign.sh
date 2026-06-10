# Shared code-signing helper, sourced by install.sh and deploy.sh.
#
# Prefers a stable self-signed certificate so macOS TCC (Accessibility,
# Automation) grants survive rebuilds AND relaunches. Ad-hoc signatures have no
# stable code identity, so TCC keeps re-prompting even though Settings shows the
# permission as granted — create the cert once with scripts/make-signing-cert.sh.
SIGNING_CERT_NAME="Beepaboop Dev"

cn_sign_identity() {
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_CERT_NAME"; then
        printf '%s' "$SIGNING_CERT_NAME"
    else
        printf -- '-'
    fi
}

# cn_sign_bundle <bundle-path> <bundle-id>
cn_sign_bundle() {
    local id
    id="$(cn_sign_identity)"
    codesign --force --sign "$id" --identifier "$2" "$1" >/dev/null
    if [[ "$id" == "-" ]]; then
        echo "   signed ad-hoc — permissions may need re-granting after rebuilds."
        echo "   run scripts/make-signing-cert.sh once to make them persist."
    else
        echo "   signed with stable identity: $id"
    fi
}
