# shellcheck shell=bash
#
# borg-encryption.sh — what BORG_ENCRYPTION means, for borg-init (which creates
# the repository) and register-repo (which records it in Borg UI). Sourced
# (never executed); defines two functions and a list, prints only when it
# refuses a mode.
# Keeping the table here is what makes the mode a repository is created with
# and the mode it is recorded with the same one.
#
# BORG_ENCRYPTION names a mode the way Borg UI does. For Borg 1 that is Borg's
# own name, passed through as it is. Borg 2 is translated:
#
#  - The default differs: repokey-blake2 is Borg 1 only, and Borg 2's
#    recommended default is repokey-aes-ocb.
#  - 2.0.0b22 split repo-create's single --encryption value into the cipher,
#    where the key is stored (--key-location) and the id hash; the combined
#    names stay, and become the split options here.
#  - The modes that do not encrypt carry their hash in the name since 2.0.0b23.
#    'authenticated' stands for authenticated-sha256, the hash the encrypted
#    modes use by default, and is the name Borg UI records for it. It keeps
#    Borg's default key location, and it has a key: the passphrase is needed as
#    for an encrypted repository.
#  - authenticated-blake3 is refused: Borg UI has no name for it, so the pods
#    could not record the repository they created with it.
#  - Borg 2 has no mode without a key: 2.0.0b25 removed the none-* modes.

# borg_encryption VERSION — resolve BORG_ENCRYPTION (or the default of that Borg
# major) into
#   borg_enc_args  the encryption arguments of `init` (Borg 1) / `repo-create`
#   borg_enc_name  the mode's name in Borg UI
# Returns 1, with the reason on stderr, for a mode the pods cannot use.
# shellcheck disable=SC2034  # borg_enc_* are the results, read by the caller
borg_encryption() {
  local mode
  if [ "${1:-1}" != "2" ]; then
    mode="${BORG_ENCRYPTION:-repokey-blake2}"
    borg_enc_args=(--encryption="$mode")
    borg_enc_name="$mode"
    return 0
  fi
  mode="${BORG_ENCRYPTION:-repokey-aes-ocb}"
  borg_enc_name="$mode"
  case "$mode" in
    repokey-aes-ocb)
      borg_enc_args=(--encryption aes256-ocb --key-location repokey) ;;
    repokey-chacha20-poly1305)
      borg_enc_args=(--encryption chacha20-poly1305 --key-location repokey) ;;
    keyfile-aes-ocb)
      borg_enc_args=(--encryption aes256-ocb --key-location keyfile) ;;
    keyfile-chacha20-poly1305)
      borg_enc_args=(--encryption chacha20-poly1305 --key-location keyfile) ;;
    authenticated | authenticated-sha256)
      borg_enc_args=(--encryption authenticated-sha256)
      borg_enc_name=authenticated ;;
    authenticated-blake3)
      echo "BORG_ENCRYPTION=authenticated-blake3: Borg UI has no name for this mode, so the" >&2
      echo "repository could not be recorded there with it. Use 'authenticated' (the same" >&2
      echo "with the sha256 hash), or one of the encrypted modes." >&2
      return 1 ;;
    none)
      echo "BORG_ENCRYPTION=none: Borg 2 has no repository without a key (the none modes" >&2
      echo "were removed in 2.0.0b25). Use 'authenticated' for a repository that is not" >&2
      echo "encrypted, or one of the encrypted modes; both need the passphrase." >&2
      return 1 ;;
    *)
      echo "BORG_ENCRYPTION=$mode is not a Borg 2 mode (expected repokey-aes-ocb," >&2
      echo "repokey-chacha20-poly1305, keyfile-aes-ocb, keyfile-chacha20-poly1305" >&2
      echo "or authenticated)." >&2
      return 1 ;;
  esac
}

# The modes of `borg init --encryption` in Borg 1.4. borg_encryption does not
# check a Borg 1 mode, Borg does; the list tells a name Borg 1 has from one it
# does not where no Borg runs (register-repo, the chart's test).
BORG1_ENCRYPTION_MODES="repokey-blake2 repokey keyfile-blake2 keyfile authenticated-blake2 authenticated none"

# borg_encryption_creates VERSION MODE — whether borg-init creates a repository
# of that Borg major with BORG_ENCRYPTION=MODE, under that same name in Borg UI.
# Prints nothing.
borg_encryption_creates() {
  if [ "${1:-1}" != "2" ]; then
    case " $BORG1_ENCRYPTION_MODES " in
      *" $2 "*) return 0 ;;
    esac
    return 1
  fi
  ( BORG_ENCRYPTION="$2" borg_encryption 2 2>/dev/null && [ "$borg_enc_name" = "$2" ] )
}
