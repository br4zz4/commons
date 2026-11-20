#!/bin/sh

commons_image_stages="base tools deps dev release"

commons_image_json_cmd() {
  out=""
  for word in $1; do
    out="$out${out:+, }\"$word\""
  done
  printf '[%s]' "$out"
}

commons_image_env_lines() {
  file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "" | "#"*) continue ;;
    esac
    printf 'ENV %s="%s"\n' "${line%%=*}" "${line#*=}"
  done <"$file"
}

commons_image_render() {
  template="$1"
  stack_dir="$2"
  code_dir="$3"
  while IFS= read -r line; do
    case "$line" in
      "@@BASE_ENV@@") commons_image_env_lines "$stack_dir/base.env" ;;
      "@@RELEASE_ENV@@")
        commons_image_env_lines "$stack_dir/release.env"
        commons_image_env_lines "$code_dir/.module/release.env"
        ;;
      "@@DEPS_COPY@@")
        for path in $DEPS_PATHS; do
          printf 'COPY --from=source %s %s\n' "$path" "$path"
        done
        ;;
      "CMD @@CMD_DEV@@") printf 'CMD %s\n' "$(commons_image_json_cmd "$CMD_DEV")" ;;
      "CMD @@CMD_RELEASE@@") printf 'CMD %s\n' "$(commons_image_json_cmd "$CMD_RELEASE")" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$template"
}

commons_image_merge_scripts() {
  stack_dir="$1"
  code_dir="$2"
  dest="$3"
  mkdir -p "$dest"
  for script in "$stack_dir"/*.[0-9]*.sh; do
    [ -f "$script" ] && cp "$script" "$dest/"
  done
  if [ -d "$code_dir/.module/scripts" ]; then
    for script in "$code_dir/.module/scripts"/*; do
      [ -f "$script" ] || continue
      name=$(basename "$script")
      printf '%s\n' "$name" | grep -qE '^(base|tools|deps|dev|release)\.[0-9]+\..+\.sh$' \
        || commons_die "script $name fora do padrão <etapa>.<NN>.<nome>.sh (etapas: $commons_image_stages)"
      cp "$script" "$dest/$name"
    done
  fi
  for stage in $commons_image_stages; do
    printf '#!/bin/sh\nexit 0\n' >"$dest/$stage.00.noop.sh"
  done
}

commons_image_merge_manifests() {
  stack_dir="$1"
  code_dir="$2"
  dest="$3"
  mkdir -p "$dest"
  found=0
  while IFS= read -r file || [ -n "$file" ]; do
    [ -n "$file" ] || continue
    [ -f "$code_dir/$file" ] || continue
    mkdir -p "$dest/$(dirname "$file")"
    cp "$code_dir/$file" "$dest/$file"
    found=1
  done <"$stack_dir/manifests"
  [ "$found" -eq 1 ] || commons_die "nenhum manifesto de $STACK encontrado em $code_dir ($(tr '\n' ' ' <"$stack_dir/manifests"))"
}

commons_image_build() {
  module="$1"
  target="$2"
  shift 2
  case "$target" in
    dev | release) ;;
    *) commons_die "alvo $target inválido (dev ou release)" ;;
  esac
  tags=""
  platform=""
  push=""
  cache_ref=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag) [ "$#" -ge 2 ] || commons_die "--tag exige valor"; tags="$tags $2"; shift 2 ;;
      --platform) [ "$#" -ge 2 ] || commons_die "--platform exige valor"; platform="$2"; shift 2 ;;
      --push) push=1; shift ;;
      --cache-ref) [ "$#" -ge 2 ] || commons_die "--cache-ref exige valor"; cache_ref="$2"; shift 2 ;;
      *) commons_die "opção $1 desconhecida" ;;
    esac
  done
  [ -z "$cache_ref" ] || [ -n "$push" ] || commons_die "--cache-ref exige --push"
  command -v docker >/dev/null 2>&1 || commons_die "docker não encontrado"
  commons_validate_module "$module"
  commons_resolve_env "$COMMONS_ENV_LOCAL"
  MODULE="$module"
  ENVIRONMENT="$COMMONS_CURRENT_ENV"
  export MODULE ENVIRONMENT
  code_dir=$(commons_dir "$module" code)
  build_env="$code_dir/.module/build.env"
  [ -f "$build_env" ] || commons_die "$module sem $(commons_relative "$build_env")"

  (
    STACK=""
    STACK_VERSION=""
    # shellcheck disable=SC1090
    . "$build_env"
    [ -n "$STACK" ] || commons_die "$(commons_relative "$build_env") sem STACK"
    stack_dir="$COMMONS_HOME/docker/stacks/$STACK"
    [ -d "$stack_dir" ] || commons_die "STACK $STACK desconhecida (docker/stacks/$STACK)"
    [ -n "$STACK_VERSION" ] || commons_die "$(commons_relative "$build_env") sem STACK_VERSION"
    # shellcheck disable=SC1091
    . "$stack_dir/defaults.env"
    # shellcheck disable=SC1090
    . "$build_env"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    commons_image_merge_scripts "$stack_dir" "$code_dir" "$tmp/scripts"
    commons_image_merge_manifests "$stack_dir" "$code_dir" "$tmp/manifests"
    mkdir -p "$tmp/precompile"
    [ ! -f "$code_dir/.module/precompile.env" ] || cp "$code_dir/.module/precompile.env" "$tmp/precompile/precompile.env"
    commons_image_render "$COMMONS_HOME/docker/Dockerfile.tmpl" "$stack_dir" "$code_dir" >"$tmp/Dockerfile"

    [ -n "$tags" ] || tags=" $COMMONS_PROJECT-$module:$target"
    if [ -n "$cache_ref" ]; then
      docker buildx inspect commons >/dev/null 2>&1 \
        || docker buildx create --name commons --driver docker-container >/dev/null
      set -- docker buildx build --builder commons \
        --cache-from "type=registry,ref=$cache_ref" \
        --cache-to "type=registry,ref=$cache_ref,mode=max,image-manifest=true,oci-mediatypes=true"
    else
      set -- docker build
    fi
    set -- "$@" \
      --build-context "scripts=$tmp/scripts" \
      --build-context "manifests=$tmp/manifests" \
      --build-context "precompile=$tmp/precompile" \
      --build-arg "BASE_IMAGE=$BASE_IMAGE" \
      --build-arg "STACK_VERSION=$STACK_VERSION" \
      --build-arg "DEPS_ENV=$target" \
      --build-arg "PROJECT=$COMMONS_PROJECT" \
      --build-arg "RELEASE_USER=$RELEASE_USER" \
      --build-arg "EXPOSE=$EXPOSE" \
      --target "$target" \
      -f "$tmp/Dockerfile"
    for tag in $tags; do
      set -- "$@" -t "$tag"
    done
    [ -z "$platform" ] || set -- "$@" --platform "$platform"
    [ -z "$push" ] || set -- "$@" --push
    "$@" "$code_dir"
  )
}
