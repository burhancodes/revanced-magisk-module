#!/usr/bin/env bash

CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//"'"/'"'}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo -e "::error::utils.sh [-] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	exit 1
}

get_rv_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"
	for src_ver in "$cli_src CLI $cli_ver revanced-cli" "$patches_src Patches $patches_ver patches"; do
		set -- $src_ver
		local src=$1 tag=$2 ver=${3-} fprefix=$4
		local ext
		if [ "$tag" = "CLI" ]; then
			ext="jar"
			local grab_cl=false
		elif [ "$tag" = "Patches" ]; then
			ext="rvp"
			local grab_cl=true
		else abort unreachable; fi
		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel="https://api.github.com/repos/${src}/releases" name_ver
		if [ "$ver" = "dev" ]; then
			name_ver="*-dev*"
		elif [ "$ver" = "latest" ]; then
			rv_rel+="/latest"
			name_ver="*"
		else
			rv_rel+="/tags/${ver}"
			name_ver="$ver"
		fi

		local url file tag_name name
		file=$(find "$dir" -name "${fprefix}-${name_ver#v}.${ext}" -type f 2>/dev/null)
		if [ -z "$file" ]; then
			local resp asset name
			resp=$(gh_req "$rv_rel" -) || return 1
			if [ "$ver" = "dev" ]; then resp=$(jq -r '.[0]' <<<"$resp"); fi
			tag_name=$(jq -r '.tag_name' <<<"$resp")
			asset=$(jq -e -r ".assets[] | select(.name | endswith(\"$ext\"))" <<<"$resp") || return 1
			url=$(jq -r .url <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			local for_err=$file
			if [ "$ver" = "latest" ]; then
				file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
			else file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1); fi
			if [ -z "$file" ]; then abort "filter fail: '$for_err' with '$ver'"; fi
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f3- <<<"$name")
			tag_name=v${tag_name%.*}
		fi
		if [ "$tag" = "Patches" ] && [ $grab_cl = true ]; then
			echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = false ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local rv_rel="https://api.github.com/repos/${PATCHES_SRC}/releases"
			if [ "$PATCHES_VER" = "dev" ]; then
				last_patches=$(gh_req "$rv_rel" - | jq -e -r '.[0]')
			elif [ "$PATCHES_VER" = "latest" ]; then
				last_patches=$(gh_req "$rv_rel/latest" -)
			else
				last_patches=$(gh_req "$rv_rel/tags/${ver}" -)
			fi
			if ! last_patches=$(jq -e -r '.assets[] | select(.name | endswith("rvp")) | .name' <<<"$last_patches"); then
				abort oops
			fi
			if [ "$last_patches" ]; then
				if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	# Array of User-Agents to rotate through
	local user_agents=(
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
		"Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
		"Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Mobile/15E148 Safari/604.1"
	)
	# Pick a random User-Agent
	local ua_index=$((RANDOM % ${#user_agents[@]}))
	local user_agent="${user_agents[$ua_index]}"

	if [ "$op" = - ]; then
		if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --retry 2 --retry-delay 2 --fail -s -S -H "User-Agent: $user_agent" "$@" "$ip"; then
			epr "Request failed: $ip"
			return 1
		fi
	else
		if [ -f "$op" ]; then return; fi
		local dlp
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
		if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --retry 2 --retry-delay 2 --fail -s -S -H "User-Agent: $user_agent" "$@" "$ip" -o "$dlp"; then
			epr "Request failed: $ip"
			return 1
		fi
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

# -------------------- apkpure --------------------
get_apkpure_resp() {
	# Try the base URL first
	__APKPURE_RESP__=$(req "${1}" -) || return 1
	# Try the download URL with a fallback if 403 occurs
	__APKPURE_DL_RESP__=$(req "${1}/download?from=details" -) || {
		epr "Failed to access download page, trying alternative..."
		__APKPURE_DL_RESP__=$(req "${1}/download" -) || return 1
	}
}
get_apkpure_vers() {
	local versions
	# Updated selector based on current APKPure structure (as of 2023, may need further adjustment)
	versions=$($HTMLQ ".version-list .version-item" --text <<<"$__APKPURE_RESP__" | awk '{$1=$1};1') || {
		epr "Could not parse versions from APKPure, falling back to scraping..."
		versions=$(grep -oP '(?<=Version: )[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?' <<<"$__APKPURE_RESP__" | awk '{$1=$1};1')
	}
	if [ -z "$versions" ]; then
		epr "No versions found on APKPure page"
		return 1
	fi
	if [ "$__AAV__" = false ]; then
		grep -iv "\(beta\|alpha\)" <<<"$versions"
	else
		echo "$versions"
	fi
}
dl_apkpure() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=$5
	local dl_url

	# Try to get the download link from the page
	dl_url=$($HTMLQ "#download_link" --attribute href <<<"$__APKPURE_DL_RESP__") || {
		epr "Failed to find download link with #download_link, trying alternative..."
		dl_url=$(grep -oP '(?<=href=")[^"]+\.apk[^"]*' <<<"$__APKPURE_DL_RESP__" | head -1) || {
			epr "No APK download link found on APKPure page"
			return 1
		}
	}

	# Check if it's a split APK (XAPK/APKM) or regular APK
	if [[ "$dl_url" =~ \.(xapk|apkm)$ ]]; then
		pr "Downloading XAPK/APKM from $dl_url"
		req "$dl_url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output" || return 1
	else
		pr "Downloading APK from $dl_url"
		req "$dl_url" "$output" || return 1
	fi
}
get_apkpure_pkg_name() {
	# Updated selector based on current APKPure structure
	local pkg_name
	pkg_name=$($HTMLQ ".package-name" --text <<<"$__APKPURE_RESP__" | awk '{$1=$1};1') || {
		epr "Could not find package name with .package-name, falling back to scraping..."
		pkg_name=$(grep -oP '(?<=Package: )[^<]+' <<<"$__APKPURE_RESP__" | head -1 | awk '{$1=$1};1') || {
			epr "Failed to extract package name from APKPure page"
			return 1
		}
	}
	echo "$pkg_name"
}

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version=${version// /}
	path=$(grep "${version_f#v}-${arch// /}" <<<"$__ARCHIVE_RESP__") || return 1
	req "${url}/${path}" "$output"
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\)\.apk//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 rv_cli_jar=$4 rv_patches_jar=$5
	local cmd="env -u GITHUB_REPOSITORY java -jar $rv_cli_jar patch $stock_input --purge -o $patched_apk -p $rv_patches_jar --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc $patcher_args"
	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary=${AAPT2}"; fi
	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	for dl_p in archive apkpure; do
		if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
		if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
			args[${dl_p}_dlurl]=""
			epr "ERROR: Could not find ${table} in ${dl_p}"
			continue
		fi
		tried_dl+=("$dl_p")
		dl_from=$dl_p
		break
	done
	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	local list_patches
	list_patches=$(java -jar "$rv_cli_jar" list-patches "$rv_patches_jar" -f "$pkg_name" -v -p 2>&1)

	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
			exit 1
		elif [ -z "$version" ]; then get_latest_ver=true; fi
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi

	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in archive apkpure; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from ${dl_p}"
			if ! isoneof $dl_p "${tried_dl[@]}"; then get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; fi
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from ${dl_p} with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then return 0; fi
	fi
	if ! OP=$(check_sig "$stock_apk" "$pkg_name" 2>&1) && ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
		abort "apk signature mismatch '$stock_apk': $OP"
	fi
	log "${table}: ${version}"

	local patcher_args patched_apk
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	patcher_args=("${p_patcher_args[@]}")
	patched_apk="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
	pr "Building '${table}' as APK"
	patch_apk "$stock_apk" "$patched_apk" "$patcher_args" "${args[cli]}" "${args[ptjar]}" || abort "Failed to patch ${table}"
}
