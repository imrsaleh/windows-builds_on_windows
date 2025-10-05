#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

BUILDNAME="${1:-}"
GITREPO="${2:-}"
GITREF="${3:-}"

declare -A DEPS=(
  [convert]=Imagemagick
  [curl]=curl
  [envsubst]=gettext
  [git]=git
  [inkscape]=inkscape
  [jq]=jq
  [yq]=yq
  [makensis]=NSIS
  [pip]=pip
  [pynsist]=pynsist
  [unzip]=unzip
)

PIP_ARGS=(
  --isolated
  --disable-pip-version-check
)

GIT_FETCHDEPTH=300

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(readlink -f "${0}")")
CONFIG="${ROOT}/config.yml"
DIR_CACHE="${ROOT}/cache"
DIR_DIST="${ROOT}/dist"
DIR_FILES="${ROOT}/files"


# ----


SELF=$(basename "$(readlink -f "${0}")")
log() {
  echo "[${SELF}]" "${@}"
}
err() {
  log >&2 "${@}"
  exit 1
}

# Function to clean carriage returns from variables
clean_cr() {
    local var="$1"
    printf '%s' "$var" | tr -d '\r'
}

[[ "${CI:-}" ]] || [[ "${VIRTUAL_ENV:-}" ]] || err "Can only be built in a virtual environment"

for dep in "${!DEPS[@]}"; do
  command -v "${dep}" >/dev/null 2>&1 || err "${DEPS["${dep}"]} is required to build the installer. Aborting."
done

[[ -f "${CONFIG}" ]] \
  || err "Missing config file: ${CONFIG}"
CONFIGJSON=$(cat "${CONFIG}")

if [[ -n "${BUILDNAME}" ]]; then
  yq -e --arg b "${BUILDNAME}" '.builds[$b]' >/dev/null 2>&1 <<< "${CONFIGJSON}" \
    || err "Invalid build name"
else
  BUILDNAME=$(yq -r '.builds | keys | first' <<< "${CONFIGJSON}")
fi

read -r appname apprel \
  < <(yq -r '.app | "\(.name) \(.rel)"' <<< "${CONFIGJSON}")
appname=$(clean_cr "$appname")
apprel=$(clean_cr "$apprel")

read -r gitrepo gitref \
  < <(yq -r '.git | "\(.repo) \(.ref)"' <<< "${CONFIGJSON}")
gitrepo=$(clean_cr "$gitrepo")
gitref=$(clean_cr "$gitref")

read -r implementation pythonversion platform \
  < <(yq -r --arg b "${BUILDNAME}" '.builds[$b] | "\(.implementation) \(.pythonversion) \(.platform)"' <<< "${CONFIGJSON}")
implementation=$(clean_cr "$implementation")
pythonversion=$(clean_cr "$pythonversion")
platform=$(clean_cr "$platform")

read -r pythonversionfull pythonfilename pythonurl pythonsha256 \
  < <(yq -r --arg b "${BUILDNAME}" '.builds[$b].pythonembed | "\(.version) \(.filename) \(.url) \(.sha256)"' <<< "${CONFIGJSON}")
pythonversionfull=$(clean_cr "$pythonversionfull")
pythonfilename=$(clean_cr "$pythonfilename")
pythonurl=$(clean_cr "$pythonurl")
pythonsha256=$(clean_cr "$pythonsha256")

gitrepo="${GITREPO:-${gitrepo}}"
gitref="${GITREF:-${gitref}}"


# ----


# shellcheck disable=SC2064
TEMP=$(mktemp -d) && trap "rm -rf '${TEMP}'" EXIT || exit 255

DIR_REPO="${TEMP}/source.git"
DIR_BUILD="${TEMP}/build"
DIR_ASSETS="${TEMP}/assets"
DIR_PKGS="${TEMP}/pkgs"
DIR_WHEELS="${TEMP}/wheels"

mkdir -p \
  "${DIR_CACHE}" \
  "${DIR_DIST}" \
  "${DIR_BUILD}" \
  "${DIR_ASSETS}" \
  "${DIR_WHEELS}"


get_sources() {
  log "Getting sources"
  mkdir -p "${DIR_REPO}"
  pushd "${DIR_REPO}"

  # TODO: re-investigate and optimize this
  git clone --depth 1 "${gitrepo}" .
  git fetch origin --depth "${GIT_FETCHDEPTH}" "${gitref}:branch"
  git ls-remote --tags --sort=version:refname 2>&- \
    | awk "END{printf \"+%s:%s\\n\",\$2,\$2}" \
    | git fetch origin --depth="${GIT_FETCHDEPTH}"
  git -c advice.detachedHead=false checkout --force branch
  git fetch origin --depth="${GIT_FETCHDEPTH}" --update-shallow

  log "Commit information"
  git describe --tags --long --dirty
  git --no-pager log -1 --pretty=full

  popd
}

get_python() {
  local filepath="${DIR_CACHE}/${pythonfilename}"
  if ! [[ -f "${filepath}" ]]; then
    log "Downloading Python"
    curl -SLo "${filepath}" "${pythonurl}"
  fi
  log "Checking Python"
  sha256sum -c - <<< "${pythonsha256} ${filepath}"
}

get_assets() {
  local assetname
  while read -r assetname; do
    local filename url sha256
    read -r filename url sha256 \
      < <(yq -r --arg a "${assetname}" '.assets[$a] | "\(.filename) \(.url) \(.sha256)"' <<< "${CONFIGJSON}")
    if ! [[ -f "${DIR_CACHE}/${filename}" ]]; then
      log "Downloading asset: ${assetname}"
      curl -SLo "${DIR_CACHE}/${filename}" "${url}"
    fi
    log "Checking asset: ${assetname}"
    # sha256sum -c - <<< "${sha256} ${DIR_CACHE}/${filename}"
    done < <(yq -r --arg b "${BUILDNAME}" '.builds[$b].assets[]' <<< "${CONFIGJSON}" | tr -d '\r')
}

build_app() {
  log "Building app"
  pip install \
    "${PIP_ARGS[@]}" \
    --no-cache-dir \
    --platform="${platform}" \
    --python-version="${pythonversion}" \
    --implementation="${implementation}" \
    --no-deps \
    --target="${DIR_PKGS}" \
    --no-compile \
    --upgrade \
    "${DIR_REPO}"

  log "Removing unneeded dist files"
  ( set -x; rm -r "${DIR_PKGS:?}/bin" "${DIR_PKGS}"/*.dist-info/direct_url.json; )
  sed -i -E \
    -e '/^.+\.dist-info\/direct_url\.json,sha256=/d' \
    -e '/^\.\.\/\.\.\//d' \
    "${DIR_PKGS}"/*.dist-info/RECORD

  log "Creating icon"
  for size in 16 32 48 256; do
    # --without-gui and --export-png have been deprecated since Inkscape 1.0.0
    # Ubuntu 20.04 CI runner is using Inkscape 0.92.5
    inkscape \
      --without-gui \
      --export-png="${DIR_BUILD}/icon-${size}.png" \
      -w ${size} \
      -h ${size} \
      "${DIR_REPO}/icon.svg"
  done
  
  # Create .ico using ImageMagick. On Windows the plain 'convert' may be the
  # system tool, so prefer 'magick' and only use 'convert' if it's ImageMagick.
  ICON_PNGS=("${DIR_BUILD}/icon-16.png" "${DIR_BUILD}/icon-32.png" "${DIR_BUILD}/icon-48.png" "${DIR_BUILD}/icon-256.png")
  if command -v magick >/dev/null 2>&1; then
    magick "${ICON_PNGS[@]}" "${DIR_BUILD}/icon.ico"
  else
    if convert -version 2>&1 | grep -qi 'ImageMagick'; then
      convert "${ICON_PNGS[@]}" "${DIR_BUILD}/icon.ico"
    else
      err "ImageMagick not found (install ImageMagick or ensure 'magick' is on PATH)."
    fi
  fi
}

download_wheels() {
  log "Downloading wheels"
  local reqfile
  reqfile=$(mktemp) || err "mktemp failed"
  # write requirements to a temp file (avoid /dev/stdin on Windows/MSYS)
  yq -r --arg b "${BUILDNAME}" '.builds[$b].dependencies | to_entries[] | "\(.key)==\(.value)"' <<< "${CONFIGJSON}" > "${reqfile}"

  # Try downloading binary wheels only first (fast, no build tools required).
  if pip download \
    "${PIP_ARGS[@]}" \
    --require-hashes \
    --only-binary=:all: \
    --platform="${platform}" \
    --python-version="${pythonversion}" \
    --implementation="${implementation}" \
    --dest="${DIR_WHEELS}" \
    --requirement "${reqfile}"; then
    log "Downloaded binary wheels"
  else
    # Fallback: allow source distributions (sdists) if binary wheels are unavailable.
    # When using --platform/--python-version with sdists pip requires --no-deps.
    # Note: building sdists into wheels may require a build toolchain (compilers).
    log "Binary wheels missing for some packages; retrying allowing source distributions"
    pip download \
      "${PIP_ARGS[@]}" \
      --only-binary=:none: \
      --no-deps \
      --platform="${platform}" \
      --python-version="${pythonversion}" \
      --implementation="${implementation}" \
      --dest="${DIR_WHEELS}" \
      --requirement "${reqfile}" \
      || err "pip download failed when allowing source distributions"
  fi

  rm -f "${reqfile}"
}

prepare_python() {
  log "Preparing Python"
  local arch
  # Clean the platform variable
  platform=$(clean_cr "$platform")
  if [[ "${platform}" == "win_amd64" ]]; then
    arch="amd64"
  else
    arch="win32"
  fi
  install -v "${DIR_CACHE}/${pythonfilename}" "${DIR_BUILD}/python-${pythonversionfull}-embed-${arch}.zip"
}

prepare_assets() {
  log "Preparing assets"
  local assetname
  while IFS= read -r assetname; do
    # Clean the assetname
    assetname=$(clean_cr "$assetname")
    [[ -z "$assetname" || "$assetname" == "null" ]] && continue
    
    log "Preparing asset: ${assetname}"
    local type filename sourcedir targetdir
    read -r type filename sourcedir targetdir \
      < <(yq -r --arg a "${assetname}" '.assets[$a] | "\(.type) \(.filename) \(.sourcedir) \(.targetdir)"' <<< "${CONFIGJSON}" 2>/dev/null || echo "")
    
    # Clean the read values
    type=$(clean_cr "$type")
    filename=$(clean_cr "$filename")
    sourcedir=$(clean_cr "$sourcedir")
    targetdir=$(clean_cr "$targetdir")
    
    [[ -z "$type" ]] && continue
    
    case "${type}" in
      zip)
        mkdir -p "${DIR_ASSETS}/${assetname}"
        unzip -q "${DIR_CACHE}/${filename}" -d "${DIR_ASSETS}/${assetname}"
        sourcedir="${DIR_ASSETS}/${assetname}/${sourcedir}"
        ;;
      *)
        sourcedir="${DIR_CACHE}"
        ;;
    esac
    
    # Read files array safely
    while IFS= read -r file_config; do
      [[ -z "$file_config" ]] && continue
      local from to
      from=$(clean_cr "$(echo "$file_config" | cut -d' ' -f1)")
      to=$(clean_cr "$(echo "$file_config" | cut -d' ' -f2-)")
      [[ -n "$from" && -n "$to" ]] && install -vDT "${sourcedir}/${from}" "${DIR_BUILD}/${targetdir}/${to}"
    done < <(yq -r --arg a "${assetname}" '.assets[$a].files[]? | "\(.from) \(.to)"' <<< "${CONFIGJSON}" 2>/dev/null | tr -d '\r')
    
  done < <(yq -r --arg b "${BUILDNAME}" '.builds[$b].assets[]?' <<< "${CONFIGJSON}" 2>/dev/null | tr -d '\r')
}

prepare_files() {
  log "Copying license file with file extension"
  install -v "${DIR_REPO}/LICENSE" "${DIR_BUILD}/LICENSE.txt"

  log "Copying config file"
  # don't use pynsist's Include.files option, as this always overwrites files,
  # which we don't want for the config file
  install -v "${DIR_FILES}/config" "${DIR_BUILD}/config"
}

prepare_installer() {
  log "Reading version string"

  local versionstring version vi_version
  versionstring="$(PYTHONPATH="${DIR_PKGS}" python -c "from importlib.metadata import version;print(version('${appname}'))")" || err "Failed to get package version"
  versionstring=$(clean_cr "$versionstring")
  log "versionstring='${versionstring}'"

  distinfo="${DIR_PKGS}/${appname}-${versionstring}.dist-info"

  # custom gitrefs that point to a tag should use the same file name format as builds from untagged commits
  if [[ -n "${GITREF}" && "${versionstring}" != *+* ]]; then
    local _commit
    _commit="$(git -C "${TEMP}/source.git" -c core.abbrev=7 rev-parse --short HEAD)"
    _commit=$(clean_cr "$_commit")
    version="${versionstring%%+*}+0.g${_commit}"
  else
    version="${versionstring}"
  fi

  if [[ "${versionstring}" != *+* ]]; then
    vi_version="${versionstring%%+*}.0"
  else
    local _versiondist
    _versiondist="${versionstring##*+}"
    _versiondist="${_versiondist%%.*}"
    vi_version="${versionstring%%+*}.${_versiondist}"
  fi

  # ========================================================================
  # WINDOWS PATH CONVERSION HELPER FUNCTION
  # ========================================================================
  # This function converts POSIX paths to Windows paths and normalizes them
  # to use forward slashes, which are accepted by both NSIS and Python on Windows
  convert_to_windows_path() {
    local posix_path="$1"
    local win_path="${posix_path}"
    
    # Try wslpath first (WSL environment)
    if command -v wslpath >/dev/null 2>&1; then
      win_path=$(wslpath -w "${posix_path}" 2>/dev/null || echo "${posix_path}")
    # Try cygpath (Cygwin environment)
    elif command -v cygpath >/dev/null 2>&1; then
      win_path=$(cygpath -w "${posix_path}" 2>/dev/null || echo "${posix_path}")
    # If neither is available, check if we're on Windows (Git Bash, MSYS2, etc.)
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
      # Already in Windows format, just normalize
      win_path="${posix_path}"
    fi
    
    # Normalize all backslashes to forward slashes
    # This is critical for NSIS and Windows Python compatibility
    win_path="${win_path//\\//}"
    
    # Remove any carriage returns or newlines
    win_path=$(printf '%s' "${win_path}" | tr -d '\r\n')
    
    echo "${win_path}"
  }

  # ========================================================================
  # PREPARE INSTALLER TEMPLATE (installer.nsi)
  # ========================================================================
  log "Preparing installer template"
  
  # Convert DIR_BUILD to Windows path with forward slashes
  WIN_DIR_BUILD=$(convert_to_windows_path "${DIR_BUILD}")
  log "WIN_DIR_BUILD='${WIN_DIR_BUILD}'"
  
  # Use envsubst to replace variables in the template
  # shellcheck disable=SC2016
  env -i \
    PATH="${PATH}" \
    DIR_BUILD="${WIN_DIR_BUILD}" \
    VERSION="${version}-${apprel}" \
    VI_VERSION="${vi_version}" \
    envsubst '$DIR_BUILD $VERSION $VI_VERSION' \
    < "${ROOT}/installer.nsi" \
    > "${DIR_BUILD}/installer.nsi"

  # ========================================================================
  # PREPARE PYNSIST CONFIG (installer.cfg)
  # ========================================================================
  log "Preparing pynsist config"

  # Build and clean INSTALLER_NAME to remove newlines/CRs and normalize slashes
  INSTALLER_NAME_RAW="${DIR_DIST}/${appname}-${version}-${apprel}-${BUILDNAME}.exe"
  INSTALLER_NAME=$(convert_to_windows_path "${INSTALLER_NAME_RAW}")
  log "INSTALLER_NAME='${INSTALLER_NAME}'"

  # Convert all paths to Windows format with forward slashes
  WIN_DIR_BUILD=$(convert_to_windows_path "${DIR_BUILD}")
  WIN_DIR_WHEELS=$(convert_to_windows_path "${DIR_WHEELS}")
  WIN_DIR_DISTINFO=$(convert_to_windows_path "${distinfo}")
  
  log "WIN_DIR_BUILD='${WIN_DIR_BUILD}'"
  log "WIN_DIR_WHEELS='${WIN_DIR_WHEELS}'"
  log "WIN_DIR_DISTINFO='${WIN_DIR_DISTINFO}'"

  # Use perl substitution to replace placeholders with Windows-style paths
  env -i \
    PATH="${PATH}" \
    DIR_BUILD_WIN="${WIN_DIR_BUILD}" \
    DIR_WHEELS_WIN="${WIN_DIR_WHEELS}" \
    DIR_DISTINFO_WIN="${WIN_DIR_DISTINFO}" \
    VERSION="${version}-${apprel}" \
    PYTHONVERSION="${pythonversionfull}" \
    INSTALLER_NAME="${INSTALLER_NAME}" \
    NSI_TEMPLATE="installer.nsi" \
    perl -pe 's/\$\{?DIR_BUILD\}?/$ENV{DIR_BUILD_WIN}/g; s/\$\{?DIR_WHEELS\}?/$ENV{DIR_WHEELS_WIN}/g; s/\$\{?DIR_DISTINFO\}?/$ENV{DIR_DISTINFO_WIN}/g; s/\$\{?VERSION\}?/$ENV{VERSION}/g; s/\$\{?PYTHONVERSION\}?/$ENV{PYTHONVERSION}/g; s/\$\{?INSTALLER_NAME\}?/$ENV{INSTALLER_NAME}/g; s/\$\{?NSI_TEMPLATE\}?/$ENV{NSI_TEMPLATE}/g' \
    < "${ROOT}/installer.cfg" \
    > "${DIR_BUILD}/installer.cfg"

  # Normalize line endings to Unix format (LF only)
  if command -v perl >/dev/null 2>&1; then
    perl -pi -e 's/\r\n|\r/\n/g' "${DIR_BUILD}/installer.cfg" || true
  else
    sed -i 's/\r$//' "${DIR_BUILD}/installer.cfg" || true
  fi

  # ========================================================================
  # HANDLE LOCAL WHEELS
  # ========================================================================
  # Remove local_wheels section if there are no wheels
  (
    shopt -s nullglob
    files=( "${DIR_WHEELS}"/*.whl )
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
      log "No local wheels found in ${DIR_WHEELS}; removing entire local_wheels section from installer.cfg"
      awk 'BEGIN{in_local_wheels=0}
        {
          if (in_local_wheels && $0 !~ /^[[:space:]]/) { in_local_wheels = 0 }
          if ($0 ~ /^[[:space:]]*local_wheels[[:space:]]*=/) { in_local_wheels = 1; next }
          if (in_local_wheels) { next }
          print
        }' "${DIR_BUILD}/installer.cfg" > "${DIR_BUILD}/installer.cfg.tmp" && mv "${DIR_BUILD}/installer.cfg.tmp" "${DIR_BUILD}/installer.cfg"
    else
      log "Found ${#files[@]} local wheels in ${DIR_WHEELS}; keeping local_wheels block"
    fi
  )

  log "Generated ${DIR_BUILD}/installer.cfg (first 200 lines):"
  sed -n '1,200p' "${DIR_BUILD}/installer.cfg" || true

  # ========================================================================
  # VERIFY PATHS IN GENERATED FILES
  # ========================================================================
  log "Verifying paths in generated installer.nsi..."
  
  # Check if DIR_BUILD placeholder was properly replaced
  if grep -q '\${DIR_BUILD}' "${DIR_BUILD}/installer.nsi" 2>/dev/null; then
    log "WARNING: Found unreplaced \${DIR_BUILD} placeholder in installer.nsi"
  fi
  if grep -q '\$DIR_BUILD' "${DIR_BUILD}/installer.nsi" 2>/dev/null; then
    log "WARNING: Found unreplaced \$DIR_BUILD placeholder in installer.nsi"
  fi
  
  log "Installer preparation complete"
}

build_installer() {
  log "Building installer"

  log "Checking required build files in: ${DIR_BUILD}"
  ls -la "${DIR_BUILD}" || true

  # required files that must be present in ${DIR_BUILD}
  required=( "icon.ico" "LICENSE.txt" "config" )

  missing=0
  for f in "${required[@]}"; do
    if [[ ! -f "${DIR_BUILD}/${f}" ]]; then
      log "ERROR: required file missing: ${DIR_BUILD}/${f}"
      missing=1
    fi
  done

  if [[ "${missing}" -eq 1 ]]; then
    log "Contents of ${DIR_BUILD}:"
    ls -la "${DIR_BUILD}" || true
    err "Missing required files in build directory. Run prepare_files or copy files/config into ${DIR_BUILD}."
  fi

  # debug: show Windows path used by pynsist (if available)
  if command -v wslpath >/dev/null 2>&1; then
    win_build="$(wslpath -w "${DIR_BUILD}" 2>/dev/null || true)"
    log "Windows-visible build dir: ${win_build}"
  fi

  log "PYTHONPATH=${DIR_PKGS} PYNSIST_CACHE_DIR=${DIR_BUILD} pynsist ${DIR_BUILD}/installer.cfg"
  PYTHONPATH="${DIR_PKGS}" PYNSIST_CACHE_DIR="${DIR_BUILD}" pynsist "${DIR_BUILD}/installer.cfg"
}


build() {
  log "Building ${BUILDNAME}, using git reference ${gitref}"
  get_sources
  get_python
  get_assets
  build_app
  download_wheels
  prepare_python
  prepare_assets
  prepare_files
  prepare_installer
  build_installer
  log "Success!"
}

build