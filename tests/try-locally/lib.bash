# shellcheck shell=bash
#
# Readers for the page "Try it locally" (site/guide/try-locally.md), for
# tests/try-locally/run.sh and tests/try-locally.bats. run.sh runs the page's
# own shell blocks, so a command changed on the page is a command changed in
# the job.

TRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAGE="$TRY_ROOT/site/guide/try-locally.md"
EXAMPLES="$TRY_ROOT/examples/k3d"

# Where the page takes its files and its chart from; run.sh puts the
# checkout's in their place.
PAGE_URL="https://raw.githubusercontent.com/ioanalytica/k8s-borg/main/examples/k3d"
PAGE_CHART="oci://ghcr.io/ioanalytica/charts/k8s-borg"

# The page's shell blocks the run takes, as "HEADING|N". Step 4's
# port-forward runs in the background; step 6's first block reads the file
# the restore in Borg UI writes, and is left out with it.
# shellcheck disable=SC2034  # read by run.sh and the tests
PAGE_BLOCKS=("## 1. |1" "## 1. |2" "## 2. |1" "## 3. |1" "## 3. |2" "## 4. |1"
             "## 5. |1" "## 6. |2" "## 7. |1" "## 7. |2")

# The plans the page runs in Borg UI.
# shellcheck disable=SC2034  # read by run.sh and the tests
NODE_PLAN="backup-k8s-borg-k3d-k8s-borg-server-0"
# shellcheck disable=SC2034  # read by run.sh and the tests
CLUSTER_PLAN="backup-k8s-borg-mycluster"

# page_block HEADING KIND N — the Nth code block of kind KIND ("sh", or ""
# for a plain one, the output the page shows) in the section whose heading
# starts with HEADING ("## 3. "). The section ends at the next heading; a
# line starting with # inside a block is a comment, not a heading.
page_block() {
  awk -v head="$1" -v kind="$2" -v n="$3" '
    /^```/ && !fence {
      fence = 1
      if (on && substr($0, 4) == kind && ++seen == n) take = 1
      next
    }
    /^```$/ && fence { fence = 0; if (take) exit; next }
    fence { if (take) print; next }
    /^#+ / { if (on) exit; if (index($0, head) == 1) on = 1 }' "$PAGE"
}

# localize CHART — stdin with the checkout's examples/k3d in place of the
# page's URL, and CHART, when not empty, in place of the released chart.
localize() {
  local chart="${1:-$PAGE_CHART}"
  sed -e "s|^url=$PAGE_URL\$|url=$EXAMPLES|" -e "s|$PAGE_CHART |$chart |g"
}

# chart_images CHART — the images of ghcr.io/ioanalytica the chart in the
# directory CHART runs with the page's values, one per line. The secrets are
# stand-ins: only the image names matter.
chart_images() {
  local key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPSu1DAFv3rL+0eX65tyDpi0hwnDcsWJqgSLMp0O49HD quickstart"
  helm template k8s-borg "$1" -n k8s-borg \
      -f "$EXAMPLES/values.yaml" -f "$EXAMPLES/values-demo-db.yaml" \
      --set borg.passphrase.value=x --set borgUI.adminPassword.value=x \
      --set ssh.privateKey=x --set ssh.publicKey=x --set ssh.knownHosts=x \
      --set ssh.hostKey=x --set "ssh.authorizedKeys=$key" \
    | sed -n 's/^ *image: *"\{0,1\}\(ghcr\.io\/ioanalytica\/[^"]*\)"\{0,1\} *$/\1/p' | sort -u
}

# unpublished IMAGE… — the images the registry does not have, one per line.
# Any other answer than "manifest unknown" fails: a registry that cannot be
# reached must not read as an image that is not published yet.
unpublished() {
  local image out
  for image in "$@"; do
    if ! out="$(docker manifest inspect "$image" 2>&1 >/dev/null)"; then
      case "$out" in
        *"manifest unknown"*|*"no such manifest"*) echo "$image" ;;
        *) echo "✗ $image: $out" >&2; return 1 ;;
      esac
    fi
  done
}
