# Shared helpers for scripts/green/*.sh. Source it; do not execute.
#
# Two AWS identities, deliberately asymmetric:
#   g …  GREEN  (profile llc, 623170744161) — full read/write; this is what we build.
#   b …  BLUE   (profile levi, 011183829623) — READ-ONLY. b() refuses any verb that is not a
#        get/list/describe call, so a typo can never mutate the live (nonprofit-shared) account.
# NEVER use profile llc-projects.
set -euo pipefail

GREEN_PROFILE="${GREEN_PROFILE:-llc}"
BLUE_PROFILE="${BLUE_PROFILE:-levi}"
GA=623170744161
BA=011183829623
R=us-west-2
GREEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$GREEN_DIR/../.." && pwd)"
SNAP="$GREEN_DIR/blue-snapshot"
STATE="$GREEN_DIR/state"           # ids discovered/created in green (no secrets) — committed
mkdir -p "$STATE"

say(){ printf '[green] %s\n' "$*" >&2; }
die(){ printf '[green] FATAL: %s\n' "$*" >&2; exit 1; }

[ "$GREEN_PROFILE" = "llc-projects" ] && die "profile llc-projects is forbidden"

g(){ aws --profile "$GREEN_PROFILE" --region "$R" "$@"; }
g1(){ aws --profile "$GREEN_PROFILE" --region us-east-1 "$@"; }   # ACM for CloudFront

b(){
  local verb="${2:-}"
  case "$verb" in
    get-*|list-*|describe-*|batch-get-*|head-*) ;;
    *) die "blue is READ-ONLY; refusing: aws $*" ;;
  esac
  aws --profile "$BLUE_PROFILE" --region "$R" "$@"
}

# blue account id -> green account id in any JSON/text on stdin
to_green(){ sed -e "s/${BA}/${GA}/g"; }

# sha256 fingerprint (first 16 hex) of stdin — the only way a secret is ever identified in output
fp(){ shasum -a 256 | cut -c1-16; }

state_get(){ [ -f "$STATE/$1" ] && cat "$STATE/$1" || true; }
state_put(){ printf '%s' "$2" > "$STATE/$1"; }

BUCKETS="am-sync-jobs dev-web legal-site logs mail prod-web rec rips www"
gbucket(){ echo "pocketdj-$1-${GA}"; }
bbucket(){ echo "pocketdj-$1-${BA}"; }

# Green CloudFront distribution id by its comment (comments are unique; green ones end " [green]").
cf_id_by_comment(){
  g cloudfront list-distributions --output json \
    | jq -r --arg c "$1" '.DistributionList.Items[]? | select(.Comment==$c) | .Id' | head -1
}
cf_domain(){ g cloudfront get-distribution --id "$1" --query Distribution.DomainName --output text; }
