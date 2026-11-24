#!/bin/sh

commons_github_secrets() {
  repo="$1"
  [ -n "${COMMONS_GITHUB_SECRETS-}" ] || return 0
  old_ifs=$IFS
  IFS=,
  for pair in $COMMONS_GITHUB_SECRETS; do
    IFS=$old_ifs
    name=${pair%%:*}
    file=${pair#*:}
    if [ -f "$COMMONS_ROOT/$file" ]; then
      gh secret set "$name" -R "$repo" < "$COMMONS_ROOT/$file" > /dev/null
      commons_info "secret $name gravado"
    else
      commons_warn "secret $name pulado: $file não existe"
    fi
    IFS=,
  done
  IFS=$old_ifs
}

commons_github_merge() {
  gh api -X PATCH "repos/$1" \
    -F allow_merge_commit=true \
    -F allow_squash_merge=false \
    -F allow_rebase_merge=false \
    -F delete_branch_on_merge=true > /dev/null
  commons_info "merge configurado: só merge commit"
}

commons_github_ruleset() {
  repo="$1"
  check="${COMMONS_REQUIRED_CHECK-}"
  [ -n "$check" ] || return 0
  default=$(gh repo view -R "$repo" --json defaultBranchRef -q .defaultBranchRef.name)
  git -C "$COMMONS_ROOT" fetch -q origin "$default" 2> /dev/null || true
  if ! git -C "$COMMONS_ROOT" grep -qE "^name: ${check}[[:space:]]*$|^[[:space:]]+name: ${check}[[:space:]]*$" "origin/$default" -- .github/workflows 2> /dev/null; then
    commons_warn "ruleset adiado: nenhum workflow em $default declara $check"
    return 0
  fi
  id=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name=="commons-default-branch") | .id' | head -n1)
  payload=$(printf '{"name":"commons-default-branch","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"%s","integration_id":15368}]}}]}' "$check")
  if [ -n "$id" ]; then
    printf '%s' "$payload" | gh api -X PUT "repos/$repo/rulesets/$id" --input - > /dev/null
    commons_info "ruleset commons-default-branch atualizado"
  else
    printf '%s' "$payload" | gh api -X POST "repos/$repo/rulesets" --input - > /dev/null
    commons_info "ruleset commons-default-branch criado"
  fi
}

commons_github_setup() {
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  commons_github_secrets "$repo"
  commons_github_merge "$repo"
  commons_github_ruleset "$repo"
}
