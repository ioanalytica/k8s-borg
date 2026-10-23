#!/usr/bin/env bats
#
# The agent image's rclone comes from one pin, docker/rclone.env, which
# docker/Dockerfile repeats as the ARG defaults of its rclone-fetch stage. The
# UI image's rclone is borg-ui's (borg-ui/docker/runtime-base.env), not this.

setup() {
  load helpers/versions
  RCLONE_ENV="$REPO_ROOT/docker/rclone.env"
  DOCKERFILE="$REPO_ROOT/docker/Dockerfile"
}

env_value() { sed -n "s/^$1=\\(.*\\)/\\1/p" "$RCLONE_ENV" | head -1; }
arg_default() { sed -n "s/^ARG $1=\\(.*\\)/\\1/p" "$DOCKERFILE" | head -1; }

@test "the agent image's rclone ARG defaults are docker/rclone.env's" {
  for key in RCLONE_VERSION RCLONE_SHA256_AMD64 RCLONE_SHA256_ARM64; do
    [ -n "$(env_value "$key")" ] || fail "no $key in docker/rclone.env"
    [ "$(arg_default "$key")" = "$(env_value "$key")" ] \
      || fail "docker/Dockerfile: ARG $key=$(arg_default "$key"), docker/rclone.env: $(env_value "$key")"
  done
}

@test "the agent image takes rclone from its own stage, not from Alpine" {
  grep -q '^COPY --from=rclone-fetch /out/usr/bin/rclone /usr/bin/rclone$' "$DOCKERFILE" \
    || fail "no COPY of the fetched rclone"
  ! awk '/^RUN apk add/ { on = 1 } on && $1 == "rclone" { found = 1 } on && !/\\$/ { on = 0 } END { exit !found }' "$DOCKERFILE" \
    || fail "the agent image still installs Alpine's rclone package"
}
