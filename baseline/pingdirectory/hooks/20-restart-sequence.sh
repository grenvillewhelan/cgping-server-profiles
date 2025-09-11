#!/usr/bin/env sh

${VERBOSE} && set -x

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"
#source the file from the beluga-common image
. "${HOOKS_DIR}/01-update-license.sh"

test -f "${HOOKS_DIR}/pingdata.lib.sh" && . "${HOOKS_DIR}/pingdata.lib.sh"

beluga_log "restarting container"

if "${SKIP_LIVENESS}"; then
  # Executing as background process so that server setup continues
  run_hook "02-skip-liveness.sh" &
fi

# Remove the post-start initialization marker file so the pod isn't prematurely considered ready
rm -f "${POST_START_INIT_MARKER_FILE}"

# Before running any ds tools, remove java.properties and re-create it
# for the current JVM.
beluga_log "Re-generating java.properties for current JVM"
rm -f "${SERVER_ROOT_DIR}/config/java.properties"
dsjavaproperties --initialize --jvmTuningParameter AGGRESSIVE --maxHeapSize "${MAX_HEAP_SIZE}"

# TODO : We need to cleanup this below method from utils and here when all the customers are upgraded to 1.19/PDv9.3
validate_and_reset_workaround

# If this hook is provided it can be executed early on
beluga_log "restart-sequence: updating server profile"
run_hook "21-update-server-profile.sh"

export encryptionOption=$(getEncryptionOption)
export jvmOptions=$(getJvmOptions)

################## Licensing Logic ##################
# Use the update_license script from beluga-common
# to validate and pull the required license file 
# to start the application. Moved the logic to 
# ping-cloud-common/pingcloud-services/beluga-common
# so it can be used across all the applications.
#####################################################

# LICENSE_KEY_FILE required due to prior configuration of server
# No matter previous state, license must exist here in order to start
# Additionally, 17-check-license.sh manages this file
export LICENSE_KEY_FILE="${LICENSE_DIR}/${LICENSE_FILE_NAME}"

# The license provided via Secret (if applicable)
external_license_file_name="${IN_DIR}/instance/${LICENSE_FILE_NAME}"

beluga_log "checking if any license file is provided as secret and pulling the license file"
update_license "${external_license_file_name}" "${LICENSE_KEY_FILE}"

# Always set license_key_arg as LICENSE_KEY_FILE path
license_key_arg="--licenseKeyFile ${LICENSE_KEY_FILE}"

# Unset BELUGA_JAVA_ARGS since we could have them set from a previous run
unset BELUGA_JAVA_ARGS

# Point java.io.tmpdir to /opt/out for manage-profile tool. See PDO-3548 for details
export BELUGA_JAVA_ARGS="-Djava.io.tmpdir=${OUT_DIR}"
# TODO: until fixed, this uses the overriden version of export_container_env set in "${HOOKS_DIR}/utils.lib.sh"
# This provides support for variables with spaces
b_export_container_env BELUGA_JAVA_ARGS

test -f "${SECRETS_DIR}"/encryption-settings.pin &&
  ENCRYPTION_PIN_FILE="${SECRETS_DIR}"/encryption-settings.pin ||
  ENCRYPTION_PIN_FILE="${SECRETS_DIR}"/encryption-password

beluga_log "Using ${ENCRYPTION_PIN_FILE} as the encryption-setting.pin file"
cp "${ENCRYPTION_PIN_FILE}" "${PD_PROFILE}"/server-root/pre-setup/config

beluga_log "Merging changes from new server profile"

additional_args="--replaceFullProfile"
if "${OPTIMIZE_REPLACE_PROFILE}"; then
  beluga_log "Running replace-profile in optimized mode"
  additional_args=
fi

# Multiple backends
create_backends_dsconfig

_manage_profile_cmd="${SERVER_BITS_DIR}/bin/manage-profile replace-profile \
    --serverRoot ${SERVER_ROOT_DIR} \
    --profile ${PD_PROFILE} \
    --useEnvironmentVariables \
    --tempProfileDirectory ${OUT_DIR} \
    --reimportData never \
    --skipValidation \
    ${license_key_arg} \
    ${additional_args}"

_replaceProfileOutputFile="/tmp/replace-profile-output.txt"
set -o pipefail # set status to failure if manage profile command in pipe fail.

${_manage_profile_cmd} | tee "${_replaceProfileOutputFile}"

MANAGE_PROFILE_STATUS=${?}
beluga_log "manage-profile replace-profile status: ${MANAGE_PROFILE_STATUS}"
set +o pipefail # reset status handling when future pipes fail.

if test "${MANAGE_PROFILE_STATUS}" -ne 0; then
  beluga_log "Contents of manage-profile.log file:"
  cat "${SERVER_BITS_DIR}/logs/tools/manage-profile.log"
  exit 20
fi

if is_multi_cluster; then
  # to update DNS entry in route53 for the current pod.
  validate_and_update_route53 "UPSERT"
  update_status=$?
  if test $update_status -ne 0; then
    beluga_error "Error while updating route53 with new pod address"
    exit 1
  fi 
fi

beluga_log "Copy beluga profile files after restart"
run_hook "07-apply-server-profile.sh"

# Add base entries to the server, only if base DNs are enabled.
add_base_entry_if_needed
add_base_entry_status=$?
beluga_log "add base DN ${USER_BASE_DN} status: ${add_base_entry_status}"
if test ${add_base_entry_status} -ne 0; then
  beluga_error "Adding base DNs failed with status: ${add_base_entry_status}"
  exit ${add_base_entry_status}
fi

rebuild_base_dn_indexes
rebuild_base_dn_indexes_status=$?
if test ${rebuild_base_dn_indexes_status} -ne 0; then
  beluga_error "Rebuilding base DN indexes failed with status: ${rebuild_base_dn_indexes_status}"
  exit ${rebuild_base_dn_indexes_status}
fi

rm -f "${_replaceProfileOutputFile}"

beluga_log "updating tools.properties"
run_hook "185-apply-tools-properties.sh"

beluga_log "updating encryption settings"
run_hook "15-encryption-settings.sh"

beluga_log "enabling the replication sub-system in offline mode"
offline_enable_replication
enable_replication_status=$?
if test ${enable_replication_status} -ne 0; then
  beluga_error "replication enable failed with status: ${enable_replication_status}"
  exit ${enable_replication_status}
fi

beluga_log "restart sequence done"
exit 0