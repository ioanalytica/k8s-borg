#!/usr/bin/env bats
#
# borgUI.notifications: the reconcile Job gets the channels as JSON without any
# credential, and each credential as its own variable from a Secret — the
# chart's Secret for a value, the user's Secret for existingSecret. A channel is
# either an email channel, whose settings are visible and whose password is the
# only secret, or a whole Apprise serviceUrl kept in a Secret. Credentials must
# not appear anywhere else in the manifests.

setup() {
  load helpers/common
  command -v helm >/dev/null || fail "helm is required for the chart tests"
  command -v yq >/dev/null || fail "yq is required for the chart tests"
  CHART="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/chart"
  BASE="$BATS_TEST_TMPDIR/base.yaml"
  VALUES="$BATS_TEST_TMPDIR/values.yaml"
  cat >"$BASE" <<'YAML'
borg:
  repoBase:
    value: "ssh://user@backup.example.com/cluster"
  passphrase:
    value: "test"
ssh:
  privateKey: "test"
  publicKey: "test"
  knownHosts: "test"
borgUI:
  enabled: true
  adminPassword:
    value: "test"
YAML
  : >"$VALUES"
}

URL="mailtos://alerts:s3cr3t-pw@smtp.example.com:587"

render() { helm template rel "$CHART" -n backup -f "$BASE" -f "$VALUES" "$@"; }

# job_env NAME — the env entry of that name in the reconcile Job, as JSON.
job_env() {
  yq -o=json -I=0 "select(.kind == \"Job\") | .spec.template.spec.containers[0].env[] | select(.name == \"$1\")" <<<"$RENDERED"
}

@test "notifications: the default renders no channel and no URL key" {
  RENDERED="$(render)" || fail "did not render"
  [ -z "$(job_env BORG_UI_NOTIFICATIONS)" ] || fail "BORG_UI_NOTIFICATIONS set without channels"
  [[ "$RENDERED" != *"BORG_UI_NOTIFICATION_URL"* ]] || fail "a URL key was rendered"
}

@test "notifications: a value goes into the chart Secret and reaches the Job by secretKeyRef" {
  cat >"$VALUES" <<YAML
borgUI:
  notifications:
    - name: ops-mail
      serviceUrl:
        value: "$URL"
YAML
  RENDERED="$(render)" || fail "did not render"
  got="$(yq "select(.kind == \"Secret\" and .metadata.name == \"rel-k8s-borg\") | .stringData.BORG_UI_NOTIFICATION_URL_0" <<<"$RENDERED")"
  [ "$got" = "$URL" ] || fail "chart Secret holds '$got'"
  ref="$(job_env BORG_UI_NOTIFICATION_URL_0)"
  [ "$ref" = '{"name":"BORG_UI_NOTIFICATION_URL_0","valueFrom":{"secretKeyRef":{"name":"rel-k8s-borg","key":"BORG_UI_NOTIFICATION_URL_0","optional":true}}}' ] \
    || fail "$ref"
  want='[{"name":"ops-mail","settings":{"enabled":true},"urlEnv":"BORG_UI_NOTIFICATION_URL_0"}]'
  got="$(job_env BORG_UI_NOTIFICATIONS | jq -cS '.value | fromjson')"
  [ "$got" = "$want" ] || fail "BORG_UI_NOTIFICATIONS = $got"
}

@test "notifications: the URL appears only in the chart Secret" {
  cat >"$VALUES" <<YAML
borgUI:
  notifications:
    - name: ops-mail
      serviceUrl:
        value: "$URL"
YAML
  RENDERED="$(render)" || fail "did not render"
  kinds="$(yq "select(. | tostring | contains(\"s3cr3t-pw\")) | .kind + \"/\" + .metadata.name" <<<"$RENDERED")"
  [ "$kinds" = "Secret/rel-k8s-borg" ] || fail "the URL is in: $kinds"
}

@test "notifications: existingSecret is referenced, nothing goes into the chart Secret" {
  cat >"$VALUES" <<'YAML'
borgUI:
  notifications:
    - name: ops-mail
      serviceUrl:
        existingSecret: alert-urls
        existingSecretKey: ops-mail
    - name: chat
      serviceUrl:
        existingSecret: alert-urls
        existingSecretKey: chat
YAML
  RENDERED="$(render)" || fail "did not render"
  [[ "$RENDERED" != *"BORG_UI_NOTIFICATION_URL_0:"* ]] || fail "a URL key is in the chart Secret"
  [ "$(job_env BORG_UI_NOTIFICATION_URL_0 | jq -c .valueFrom.secretKeyRef)" = '{"name":"alert-urls","key":"ops-mail","optional":true}' ] \
    || fail "$(job_env BORG_UI_NOTIFICATION_URL_0)"
  [ "$(job_env BORG_UI_NOTIFICATION_URL_1 | jq -c .valueFrom.secretKeyRef)" = '{"name":"alert-urls","key":"chat","optional":true}' ] \
    || fail "$(job_env BORG_UI_NOTIFICATION_URL_1)"
  [ "$(job_env BORG_UI_NOTIFICATIONS | jq -r '.value | fromjson | map(.urlEnv) | join(",")')" \
    = "BORG_UI_NOTIFICATION_URL_0,BORG_UI_NOTIFICATION_URL_1" ] || fail "$(job_env BORG_UI_NOTIFICATIONS)"
}

@test "notifications: only the settings that are set are sent, under the API's names" {
  cat >"$VALUES" <<'YAML'
borgUI:
  notifications:
    - name: ops-mail
      serviceUrl:
        existingSecret: alert-urls
        existingSecretKey: ops-mail
      enabled: false
      titlePrefix: "[prod]"
      includeJobNameInTitle: true
      monitorAllRepositories: true
      events:
        backupSuccess: true
        restoreCheckFailure: false
        staleBackup: false
YAML
  RENDERED="$(render)" || fail "did not render"
  got="$(job_env BORG_UI_NOTIFICATIONS | jq -cS '.value | fromjson | .[0].settings')"
  want='{"enabled":false,"include_job_name_in_title":true,"monitor_all_repositories":true,"notify_on_backup_success":true,"notify_on_restore_check_failure":false,"notify_on_stale_backup":false,"title_prefix":"[prod]"}'
  [ "$got" = "$want" ] || fail "$got"
}

@test "notifications: without the reconcile Job nothing is rendered for them" {
  cat >"$VALUES" <<YAML
borgUI:
  reconcile:
    enabled: false
  notifications:
    - name: ops-mail
      serviceUrl:
        value: "$URL"
YAML
  RENDERED="$(render)" || fail "did not render"
  [[ "$RENDERED" != *"s3cr3t-pw"* ]] || fail "the URL was rendered without a Job to use it"
}

# refused YAML MESSAGE — the entry in YAML is refused with a message naming MESSAGE.
refused() {
  printf 'borgUI:\n  notifications:\n%s\n' "$1" >"$VALUES"
  run render
  [ "$status" -ne 0 ] || fail "rendered although it should not: $1"
  [[ "$output" == *"$2"* ]] || fail "message lacks '$2': $output"
}

@test "notifications: invalid entries are refused at render time" {
  refused '    - serviceUrl: {value: "json://x"}' "borgUI.notifications[0].name"
  refused '    - {name: "", serviceUrl: {value: "json://x"}}' "borgUI.notifications[0].name"
  refused '    - {name: a, serviceUrl: {value: "json://x"}}
    - {name: a, serviceUrl: {value: "json://y"}}' 'name "a" is used twice'
  refused '    - {name: a}' "borgUI.notifications[0] needs email or serviceUrl"
  refused '    - {name: a, email: {smtp: {host: h}, from: a@b.c, to: [x@b.c]}, serviceUrl: {value: "json://x"}}' "email or serviceUrl, not both"
  refused '    - {name: a, serviceUrl: "json://x"}' "borgUI.notifications[0].serviceUrl must be a map"
  refused '    - {name: a, serviceUrl: {value: ""}}' "borgUI.notifications[0].serviceUrl"
  refused '    - {name: a, serviceUrl: {existingSecret: s}}' "existingSecretKey"
  refused '    - {name: a, serviceUrl: {value: 123}}' "serviceUrl.value must be a string"
  refused '    - {name: a, serviceUrl: {value: "hooks.example.com/x"}}' "serviceUrl.value must be an Apprise URL"
  refused '    - {name: a, serviceUrl: {existingSecret: s, existingSecretKey: 1}}' "serviceUrl.existingSecretKey must be a string"
  refused '    - {name: a, serviceUrl: {value: "json://x"}, events: {backupFailed: true}}' 'unknown event "backupFailed"'
  refused '    - {name: a, serviceUrl: {value: "json://x"}, events: {backupFailure: "yes"}}' "must be true or false"
  refused '    - {name: a, serviceUrl: {value: "json://x"}, enabled: "no"}' "must be true or false"
  refused '    - {name: a, serviceURL: {value: "json://x"}}' 'unknown key "serviceURL"'
}

# email_refused YAML-FLOW MESSAGE — an email block (flow map) is refused with MESSAGE.
email_refused() { refused "    - {name: a, email: $1}" "$2"; }

@test "notifications: invalid email channels are refused at render time" {
  OK='smtp: {host: smtp.example.com}, from: alerts@example.com, to: [ops@example.com]'
  email_refused '"x"' "borgUI.notifications[0].email must be a map"
  email_refused "{$OK, smtpHost: x}" 'email: unknown key "smtpHost"'
  email_refused '{from: alerts@example.com, to: [ops@example.com]}' "email.smtp.host is required"
  email_refused '{smtp: {host: ""}, from: alerts@example.com, to: [ops@example.com]}' "email.smtp.host is required"
  email_refused '{smtp: {host: "smtp.example.com/x"}, from: alerts@example.com, to: [ops@example.com]}' "email.smtp.host must be a host name"
  email_refused '{smtp: {host: h, prot: 25}, from: alerts@example.com, to: [ops@example.com]}' 'email.smtp: unknown key "prot"'
  email_refused '{smtp: {host: h, port: 0}, from: alerts@example.com, to: [ops@example.com]}' "email.smtp.port must be"
  email_refused '{smtp: {host: h, port: "587"}, from: alerts@example.com, to: [ops@example.com]}' "email.smtp.port must be"
  email_refused '{smtp: {host: h, mode: tls}, from: alerts@example.com, to: [ops@example.com]}' 'email.smtp.mode must be "starttls", "ssl" or "insecure"'
  email_refused '{smtp: {host: h}, to: [ops@example.com]}' "email.from must be an e-mail address"
  email_refused '{smtp: {host: h}, from: alerts, to: [ops@example.com]}' "email.from must be an e-mail address"
  email_refused '{smtp: {host: h}, from: alerts@example.com}' "email.to needs at least one address"
  email_refused '{smtp: {host: h}, from: alerts@example.com, to: ops@example.com}' "email.to must be a list"
  email_refused '{smtp: {host: h}, from: alerts@example.com, to: [ops]}' 'email.to: "ops" is not an e-mail address'
  email_refused "{$OK, cc: [nope]}" 'email.cc: "nope" is not an e-mail address'
  email_refused "{$OK, replyTo: nope}" "email.replyTo must be an e-mail address"
  email_refused "{$OK, password: {value: pw}}" "email.password needs email.username"
  email_refused "{$OK, username: u, password: {existingSecret: s}}" "email.password.existingSecretKey"
  email_refused "{$OK, username: u, password: {value: \"\"}}" "email.password needs value or existingSecret"
  email_refused "{$OK, username: u, password: pw}" "email.password must be a map"
  # A YAML number is not a string, and Helm would print a large one as 1.234567e+06.
  email_refused "{$OK, username: u, password: {value: 1234567}}" "email.password.value must be a string"
}

EMAIL_VALUES='borgUI:
  notifications:
    - name: ops-mail
      email:
        smtp: {host: smtp.example.com, port: 587, mode: starttls}
        username: alerts@example.com
        password: {existingSecret: mail, existingSecretKey: SMTP_PASSWORD}
        from: alerts@example.com
        fromName: "Borg UI test"
        to: [ops@example.com, oncall@example.com]
        cc: [audit@example.com]
        replyTo: noreply@example.com
      titlePrefix: "[test]"
    - name: chat
      serviceUrl: {existingSecret: alert-urls, existingSecretKey: chat}'

@test "notifications: a missing Secret key does not stop the reconcile Job" {
  # Notifications are best effort: with optional refs the Job starts without the
  # key, warns "no password" and still publishes the marker the agents wait for.
  printf '%s\n' "$EMAIL_VALUES" >"$VALUES"
  RENDERED="$(render)" || fail "did not render"
  for v in BORG_UI_NOTIFICATION_PASSWORD_0 BORG_UI_NOTIFICATION_URL_1; do
    [ "$(job_env "$v" | jq -r .valueFrom.secretKeyRef.optional)" = "true" ] || fail "$v: $(job_env "$v")"
  done
}

@test "notifications: an email channel is visible, only its password comes by secretKeyRef" {
  printf '%s\n' "$EMAIL_VALUES" >"$VALUES"
  RENDERED="$(render)" || fail "did not render"
  got="$(job_env BORG_UI_NOTIFICATIONS | jq -cS '.value | fromjson')"
  want='[{"email":{"cc":["audit@example.com"],"from":"alerts@example.com","fromName":"Borg UI test","mode":"starttls","port":587,"replyTo":"noreply@example.com","smtpHost":"smtp.example.com","to":["ops@example.com","oncall@example.com"],"username":"alerts@example.com"},"name":"ops-mail","passwordEnv":"BORG_UI_NOTIFICATION_PASSWORD_0","settings":{"enabled":true,"title_prefix":"[test]"}},{"name":"chat","settings":{"enabled":true},"urlEnv":"BORG_UI_NOTIFICATION_URL_1"}]'
  [ "$got" = "$want" ] || fail "BORG_UI_NOTIFICATIONS = $got"
  [ "$(job_env BORG_UI_NOTIFICATION_PASSWORD_0 | jq -c .valueFrom.secretKeyRef)" = '{"name":"mail","key":"SMTP_PASSWORD","optional":true}' ] \
    || fail "$(job_env BORG_UI_NOTIFICATION_PASSWORD_0)"
  [ "$(job_env BORG_UI_NOTIFICATION_URL_1 | jq -c .valueFrom.secretKeyRef)" = '{"name":"alert-urls","key":"chat","optional":true}' ] \
    || fail "$(job_env BORG_UI_NOTIFICATION_URL_1)"
  [ -z "$(job_env BORG_UI_NOTIFICATION_URL_0)" ] || fail "a whole-URL variable for an email channel"
}

@test "notifications: email defaults: mode starttls, no port, no login" {
  cat >"$VALUES" <<'YAML'
borgUI:
  notifications:
    - name: relay
      email:
        smtp: {host: relay.example.com}
        from: alerts@example.com
        to: [ops@example.com]
YAML
  RENDERED="$(render)" || fail "did not render"
  got="$(job_env BORG_UI_NOTIFICATIONS | jq -cS '.value | fromjson | .[0]')"
  [ "$got" = '{"email":{"from":"alerts@example.com","mode":"starttls","smtpHost":"relay.example.com","to":["ops@example.com"]},"name":"relay","settings":{"enabled":true}}' ] \
    || fail "$got"
  [ -z "$(job_env BORG_UI_NOTIFICATION_PASSWORD_0)" ] || fail "a password variable without a password"
}

@test "notifications: an email password value goes only into the chart Secret" {
  cat >"$VALUES" <<'YAML'
borgUI:
  notifications:
    - name: ops-mail
      email:
        smtp: {host: smtp.example.com}
        username: alerts@example.com
        password: {value: "s3cr3t-mail-pw"}
        from: alerts@example.com
        to: [ops@example.com]
YAML
  RENDERED="$(render)" || fail "did not render"
  [ "$(job_env BORG_UI_NOTIFICATION_PASSWORD_0 | jq -c .valueFrom.secretKeyRef)" = '{"name":"rel-k8s-borg","key":"BORG_UI_NOTIFICATION_PASSWORD_0","optional":true}' ] \
    || fail "$(job_env BORG_UI_NOTIFICATION_PASSWORD_0)"
  kinds="$(yq "select(. | tostring | contains(\"s3cr3t-mail-pw\")) | .kind + \"/\" + .metadata.name" <<<"$RENDERED")"
  [ "$kinds" = "Secret/rel-k8s-borg" ] || fail "the password is in: $kinds"
}
