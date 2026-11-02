# shellcheck shell=bash
#
# Extractors for the GitHub Actions workflows, plain awk like versions.bash:
# they read the two-space job and step layout the workflows are written in.
# Each prints nothing when its block is absent; the tests treat that as a
# failure.

# wf_job FILE NAME — the lines of one job, up to the next one.
wf_job() {
  awk -v head="  $2:" '
    on && match($0, /[^ ]/) && RSTART <= 3 { exit }
    on
    $0 == head { on = 1 }' "$1"
}

# wf_step FILE HEAD — the lines of the step whose first line is "- HEAD".
wf_step() {
  awk -v head="- $2" '
    on && match($0, /[^ ]/) && RSTART <= col { exit }
    on
    !on { line = $0; sub(/^ */, "", line); if (line == head) { on = 1; col = index($0, "-") } }' "$1"
}

# wf_image_jobs FILE — the jobs of a workflow that build an image with
# build-image.yml.
wf_image_jobs() {
  awk '/^  [a-z][a-z0-9-]*:$/ { j = $1; sub(/:$/, "", j) }
       $1 == "uses:" && $2 == "./.github/workflows/build-image.yml" { print j }' "$1"
}
