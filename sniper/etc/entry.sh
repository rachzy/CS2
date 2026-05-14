#!/bin/bash

# Debug

## Steamcmd debugging
if [[ $DEBUG -eq 1 ]] || [[ $DEBUG -eq 3 ]]; then
    STEAMCMD_SPEW="+set_spew_level 4 4"
fi
## CS2 server debugging
if [[ $DEBUG -eq 2 ]] || [[ $DEBUG -eq 3 ]]; then
    CS2_LOG="on"
    CS2_LOG_FILE=1
    CS2_LOG_MONEY=1
    CS2_LOG_DETAIL=3
    CS2_LOG_ITEMS=1
fi

if [[ "$STEAMAPPVALIDATE" -eq 1 ]]; then
    VALIDATE="validate"
else
    VALIDATE=""
fi

## Adding shared data

ACTIVE_DIR="${STEAMAPPDIR:-/home/steam/cs2-dedicated}"
SHARED_DIR="${CS2_SHARED_DIR:-/home/steam/cs2-shared}"
CONTAINER_USER="${CS2_CONTAINER_USER:-steam}"
CONTAINER_OWNER="${CS2_CONTAINER_OWNER:-1000:1000}"

## Utils
directory_has_entries() {
    local directory="$1"
    local entries

    shopt -s nullglob dotglob
    entries=("${directory}"/*)
    shopt -u nullglob dotglob

    [ "${#entries[@]}" -gt 0 ]
}

has_shared_data() {
    [ -d "${SHARED_DIR}" ] && [ -d "${SHARED_DIR}/game" ] && directory_has_entries "${SHARED_DIR}/game"
}

copy_from_shared() {
    local relative_path="$1"
    local source="${SHARED_DIR}${relative_path}"
    local target="${ACTIVE_DIR}${relative_path}"

    if [ ! -e "${source}" ] && [ ! -L "${source}" ]; then
        echo "[wrapper] Shared path missing, skipping copy: ${relative_path}"
        return
    fi

    mkdir -p "$(dirname "${target}")"
    rm -rf "${target}"
    cp -a "${source}" "${target}"
}

link_from_shared() {
    local relative_path="$1"
    local source="${SHARED_DIR}${relative_path}"
    local target="${ACTIVE_DIR}${relative_path}"

    if [ ! -e "${source}" ] && [ ! -L "${source}" ]; then
        echo "[wrapper] Shared path missing, skipping link: ${relative_path}"
        return
    fi

    if [ -d "${source}" ] && [ ! -L "${source}" ]; then
        link_directory_contents_from_shared "${relative_path}"
        return
    fi

    mkdir -p "$(dirname "${target}")"
    rm -rf "${target}"
    ln -s "${source}" "${target}"
}

link_directory_contents_from_shared() {
    local relative_path="$1"
    local source_directory="${SHARED_DIR}${relative_path}"
    local target_directory="${ACTIVE_DIR}${relative_path}"
    local source_path
    local nested_relative_path
    local target_path

    rm -rf "${target_directory}"
    mkdir -p "${target_directory}"

    while IFS= read -r -d '' source_path; do
        nested_relative_path="${source_path#${SHARED_DIR}}"
        target_path="${ACTIVE_DIR}${nested_relative_path}"

        if [ -d "${source_path}" ] && [ ! -L "${source_path}" ]; then
            mkdir -p "${target_path}"
        else
            mkdir -p "$(dirname "${target_path}")"
            rm -rf "${target_path}"
            ln -s "${source_path}" "${target_path}"
        fi
    done < <(find "${source_directory}" -mindepth 1 -print0)
}

link_shared_glob() {
    local pattern="$1"
    local source
    local relative_path

    shopt -s nullglob
    for source in ${SHARED_DIR}${pattern}; do
        relative_path="${source#${SHARED_DIR}}"
        link_from_shared "${relative_path}"
    done
    shopt -u nullglob
}

echo "[wrapper] Validating shared CS2 data..."

if has_shared_data; then
    echo "[wrapper] Shared CS2 data is present, preparing server directories..."
    echo "[wrapper] Preparing CS2 server directories..."
    mkdir -p "${ACTIVE_DIR}"
    chown "${CONTAINER_OWNER}" "${ACTIVE_DIR}" "${SHARED_DIR}"

    echo "[wrapper] Creating per-server Steam working directories..."
    mkdir -p \
        "${ACTIVE_DIR}/steamapps/downloading" \
        "${ACTIVE_DIR}/steamapps/temp"

    echo "[wrapper] Copying per-server CS2 files from shared data..."
    copy_from_shared "/steamapps/appmanifest_730.acf"
    copy_from_shared "/game/csgo/cfg"
    copy_from_shared "/game/csgo/gameinfo.gi"
    copy_from_shared "/game/csgo_lv/gameinfo_branchspecific.gi"
    copy_from_shared "/game/csgo_lv/gameinfo.gi"
    copy_from_shared "/game/cs2.sh"
    copy_from_shared "/game/bin/linuxsteamrt64/cs2"

    echo "[wrapper] Linking shared CS2 assets..."
    link_from_shared "/installscript.vdf"
    link_from_shared "/game/bin/built_from_cl.txt"
    link_from_shared "/game/bin/content_built_from_cl.txt"
    link_shared_glob "/game/bin/linuxsteamrt64/*.flt"
    link_shared_glob "/game/bin/linuxsteamrt64/*.so*"
    link_from_shared "/game/bin/linuxsteamrt64/steam_appid.txt"
    link_from_shared "/game/bin/win64"
    link_from_shared "/game/core"
    link_from_shared "/game/csgo/bin"
    link_from_shared "/game/csgo/resource"
    link_from_shared "/game/csgo/panorama"
    link_from_shared "/game/csgo/maps"
    link_shared_glob "/game/csgo/*.vpk"
    link_from_shared "/game/csgo/steam.inf"
    link_from_shared "/game/csgo/gameinfo_branchspecific.gi"
    link_from_shared "/game/csgo_community_addons"
    link_from_shared "/game/csgo_core"
    link_from_shared "/game/csgo_imported"
    link_from_shared "/game/thirdpartylegalnotices.txt"

    chown -R "${CONTAINER_OWNER}" "${ACTIVE_DIR}"
else
    echo "[wrapper] Shared CS2 data is missing, running installation container..."
fi

# Check if CS2 installation exists
if [[ ! -f "${STEAMAPPDIR}/game/cs2.sh" ]]; then
    echo "CS2 installation not found; forcing validation of initial install"
    mkdir -p "${STEAMAPPDIR}" || true
    VALIDATE="validate"
fi

GAMEDIR="${STEAMAPPDIR}"

if [[ $VALIDATE == "validate" ]]; then
    GAMEDIR="${INSTALLATIONDIR}"
fi

echo "Installing at: ${GAMEDIR}"

## SteamCMD can fail to download
## Retry logic
MAX_ATTEMPTS=3
attempt=0
while [[ $steamcmd_rc != 0 ]] && [[ $attempt -lt $MAX_ATTEMPTS ]]; do
    ((attempt+=1))
    if [[ $attempt -gt 1 ]]; then
        echo "Retrying SteamCMD, attempt ${attempt}"
 
        echo "Removing steamapps/appmanifest_730.acf..."
        rm -rf "${STEAMAPPDIR}/steamapps/appmanifest_730.acf"
    fi
    eval bash "${STEAMCMDDIR}/steamcmd.sh" "${STEAMCMD_SPEW}"\
                                +force_install_dir "${GAMEDIR}" \
                                +@bClientTryRequestManifestWithoutCode 1 \
				+login anonymous \
				+app_update "${STEAMAPPID}" "${VALIDATE}"\
				+quit
    steamcmd_rc=$?
done

## Exit if steamcmd fails
if [[ $steamcmd_rc != 0 ]]; then
    exit $steamcmd_rc
fi

## Exit if it was a validation installation and STOPAFTERVALIDATION is enabled
if [[ $VALIDATE == "validate" ]] && [[ $STOPAFTERVALIDATION -eq 1 ]]; then
    echo "Validation installation detected and STOPAFTERVALIDATION is enabled, exiting"
    exit 0
fi

# FIX: steamclient.so fix
mkdir -p ~/.steam/sdk64
ln -sfT ${STEAMCMDDIR}/linux64/steamclient.so ~/.steam/sdk64/steamclient.so

# Install server.cfg
mkdir -p $STEAMAPPDIR/game/csgo/cfg
cp /etc/server.cfg "${STEAMAPPDIR}"/game/csgo/cfg/server.cfg

# Install hooks if they don't already exist
if [[ ! -f "${STEAMAPPDIR}/pre.sh" ]] ; then
    cp /etc/pre.sh "${STEAMAPPDIR}/pre.sh"
fi
if [[ ! -f "${STEAMAPPDIR}/post.sh" ]] ; then
    cp /etc/post.sh "${STEAMAPPDIR}/post.sh"
fi

# Download and extract custom config bundle
if [[ ! -z $CS2_CFG_URL ]]; then
    echo "Downloading config pack from ${CS2_CFG_URL}"

    TEMP_DIR=$(mktemp -d)
    TEMP_FILE="${TEMP_DIR}/$(basename ${CS2_CFG_URL})"
    wget -qO "${TEMP_FILE}" "${CS2_CFG_URL}"

    case "${TEMP_FILE}" in
        *.zip)
            echo "Extracting ZIP file..."
            unzip -o -q "${TEMP_FILE}" -d "${STEAMAPPDIR}"
            ;;
        *.tar.gz | *.tgz)
            echo "Extracting TAR.GZ or TGZ file..."
            tar xvzf "${TEMP_FILE}" -C "${STEAMAPPDIR}"
            ;;
        *.tar)
            echo "Extracting TAR file..."
            tar xvf "${TEMP_FILE}" -C "${STEAMAPPDIR}"
            ;;
        *)
            echo "Unsupported file type"
            rm -rf "${TEMP_DIR}"
            exit 1
            ;;
    esac

    rm -rf "${TEMP_DIR}"
fi

# Rewrite Config Files

# 1. Remove previous /game/csgo/cfg/server.cfg
rm -f "${STEAMAPPDIR}"/game/csgo/cfg/server.cfg

# 2. Copy new /etc/server.cfg to /game/csgo/cfg/server.cfg
cp /etc/server.cfg "${STEAMAPPDIR}"/game/csgo/cfg/server.cfg

# 3. Rewrite /game/csgo/cfg/server.cfg with the most updated values
sed -i -e "s/{{SERVER_HOSTNAME}}/${CS2_SERVERNAME}/g" \
       -e "s/{{SERVER_CHEATS}}/${CS2_CHEATS}/g" \
       -e "s/{{SERVER_HIBERNATE}}/${CS2_SERVER_HIBERNATE}/g" \
       -e "s/{{SERVER_PW}}/${CS2_PW}/g" \
       -e "s/{{SERVER_RCON_PW}}/${CS2_RCONPW}/g" \
       -e "s/{{TV_ENABLE}}/${TV_ENABLE}/g" \
       -e "s/{{TV_PORT}}/${TV_PORT}/g" \
       -e "s/{{TV_AUTORECORD}}/${TV_AUTORECORD}/g" \
       -e "s/{{TV_PW}}/${TV_PW}/g" \
       -e "s/{{TV_RELAY_PW}}/${TV_RELAY_PW}/g" \
       -e "s/{{TV_MAXRATE}}/${TV_MAXRATE}/g" \
       -e "s/{{TV_DELAY}}/${TV_DELAY}/g" \
       -e "s/{{SERVER_LOG}}/${CS2_LOG}/g" \
       -e "s/{{SERVER_LOG_FILE}}/${CS2_LOG_FILE}/g" \
       -e "s/{{SERVER_LOG_ECHO}}/${CS2_LOG_ECHO}/g" \
       -e "s/{{SERVER_LOG_MONEY}}/${CS2_LOG_MONEY}/g" \
       -e "s/{{SERVER_LOG_DETAIL}}/${CS2_LOG_DETAIL}/g" \
       -e "s/{{SERVER_LOG_ITEMS}}/${CS2_LOG_ITEMS}/g" \
       -e "s/{{SERVER_DISCONNECT_KILLS}}/${CS2_DISCONNECT_KILLS}/g" \
       "${STEAMAPPDIR}"/game/csgo/cfg/server.cfg

if [[ ! -z $CS2_LOG_HTTP_URL ]]; then
    printf 'logaddress_add_http "%s"\n' "${CS2_LOG_HTTP_URL}" >> "${STEAMAPPDIR}"/game/csgo/cfg/server.cfg
fi

if [[ ! -z $CS2_BOT_DIFFICULTY ]] ; then
    sed -i "s/bot_difficulty.*/bot_difficulty ${CS2_BOT_DIFFICULTY}/" "${STEAMAPPDIR}"/game/csgo/cfg/*
fi
if [[ ! -z $CS2_BOT_QUOTA ]] ; then
    sed -ri "s/bot_quota[[:space:]]+.*/bot_quota ${CS2_BOT_QUOTA}/" "${STEAMAPPDIR}"/game/csgo/cfg/*
fi
if [[ ! -z $CS2_BOT_QUOTA_MODE ]] ; then
    sed -i "s/bot_quota_mode.*/bot_quota_mode ${CS2_BOT_QUOTA_MODE}/" "${STEAMAPPDIR}"/game/csgo/cfg/*
fi

# Rewrite tv_delay in all gamemode_*.cfg files
if [[ -n "$TV_DELAY" ]]; then
    for f in "${STEAMAPPDIR}"/game/csgo/cfg/gamemode_*.cfg; do
        [[ -e "$f" ]] || continue
        grep -q "^tv_delay" "$f" \
            && sed -i "s/^tv_delay.*/tv_delay ${TV_DELAY}/" "$f" \
            || echo "tv_delay ${TV_DELAY}" >> "$f"
    done
fi

# Switch to server directory
cd "${STEAMAPPDIR}/game/"

# Pre Hook
source "${STEAMAPPDIR}/pre.sh"

# Construct server arguments

if [[ -z $CS2_GAMEALIAS ]]; then
    # If CS2_GAMEALIAS is undefined then default to CS2_GAMETYPE and CS2_GAMEMODE
    CS2_GAME_MODE_ARGS="+game_type ${CS2_GAMETYPE} +game_mode ${CS2_GAMEMODE}"
else
    # Else, use alias to determine game mode
    CS2_GAME_MODE_ARGS="+game_alias ${CS2_GAMEALIAS}"
fi

if [[ -z $CS2_IP ]]; then
    CS2_IP_ARGS=""
else
    CS2_IP_ARGS="-ip ${CS2_IP}"
fi

if [[ ! -z $SRCDS_TOKEN ]]; then
    SV_SETSTEAMACCOUNT_ARGS="+sv_setsteamaccount ${SRCDS_TOKEN}"
fi

if [[ ! -z $CS2_HOST_WORKSHOP_COLLECTION ]] || [[ ! -z $CS2_HOST_WORKSHOP_MAP ]]; then
    CS2_MP_MATCH_END_CHANGELEVEL="+mp_match_end_changelevel true"   # https://github.com/joedwards32/CS2/issues/57#issuecomment-2245595368
    CS2_STARTMAP="\<empty\>"                                        # https://github.com/joedwards32/CS2/issues/57#issuecomment-2245595368
    CS2_MAPGROUP_ARGS=
else
    CS2_MAPGROUP_ARGS="+mapgroup ${CS2_MAPGROUP}"
fi

if [[ ! -z $CS2_HOST_WORKSHOP_COLLECTION ]]; then
    CS2_HOST_WORKSHOP_COLLECTION_ARGS="+host_workshop_collection ${CS2_HOST_WORKSHOP_COLLECTION}"
fi

if [[ ! -z $CS2_HOST_WORKSHOP_MAP ]]; then
    CS2_HOST_WORKSHOP_MAP_ARGS="+host_workshop_map ${CS2_HOST_WORKSHOP_MAP}"
fi

if [[ ! -z $CS2_PW ]]; then
    CS2_PW_ARGS="+sv_password ${CS2_PW}"
fi

# Start Server

if [[ ! -z $CS2_RCON_PORT ]]; then
    echo "Establishing Simpleproxy for ${CS2_RCON_PORT} to 127.0.0.1:${CS2_PORT}"
    simpleproxy -L "${CS2_RCON_PORT}" -R 127.0.0.1:"${CS2_PORT}" &
fi

echo "Starting CS2 Dedicated Server"
eval "./cs2.sh" -dedicated \
        "${CS2_IP_ARGS}" -port "${CS2_PORT}" \
        -console \
        -usercon \
        -maxplayers "${CS2_MAXPLAYERS}" \
        "${CS2_GAME_MODE_ARGS}" \
        "${CS2_MAPGROUP_ARGS}" \
        +map "${CS2_STARTMAP}" \
        "${CS2_HOST_WORKSHOP_COLLECTION_ARGS}" \
        "${CS2_HOST_WORKSHOP_MAP_ARGS}" \
        "${CS2_MP_MATCH_END_CHANGELEVEL}" \
        +rcon_password "${CS2_RCONPW}" \
        "${SV_SETSTEAMACCOUNT_ARGS}" \
        "${CS2_PW_ARGS}" \
        +sv_lan "${CS2_LAN}" \
        +tv_port "${TV_PORT}" \
        "${CS2_ADDITIONAL_ARGS}"

# Post Hook
source "${STEAMAPPDIR}/post.sh"