#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./odf-healtcheck.sh --compact
#   ./odf-healtcheck.sh --detailed

MODE=""
case "${1:-}" in
  --compact)  MODE="compact" ;;
  --detailed) MODE="detailed" ;;
  *)
    echo "Usage:"
    echo "  $0 --compact"
    echo "  $0 --detailed"
    exit 1
    ;;
esac

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_FILE="$(date -u +'%Y%m%d-%H%M%S')"
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/odf-healthcheck-${TS_FILE}.log"

# Log everything (stdout+stderr) to console and logfile
exec > >(tee -a "$LOGFILE") 2>&1

NS="openshift-storage"

hr() { echo "========================================"; }
section() {
  echo
  hr
  echo "$1"
  hr
  echo
}
table() {
  # Reads TSV from stdin, prints pretty aligned table.
  # If input is empty, prints "(no data)".
  if ! IFS= read -r first_line; then
    echo "(no data)"
    return 0
  fi
  {
    echo "$first_line"
    cat
  } | column -t -s $'\t'
}
run_tsv() {
  # run_tsv "<cmd...>"  (expects it prints TSV or can be transformed)
  # shellcheck disable=SC2086
  eval "$1"
}

safe_oc() {
  # Run oc command; never fail the whole script on non-zero exit, but keep output.
  # shellcheck disable=SC2068
  oc $@ 2>&1 || true
}

k8s_server="$(safe_oc version -o jsonpath='{.serverVersion.gitVersion}{"\n"}' | head -n1)"
if [[ -z "$k8s_server" ]]; then k8s_server="unknown"; fi

# Helper: counts and health evaluation
WARN_COUNT=0
ERR_COUNT=0

count_events() {
  # Count warnings and errors in openshift-storage events.
  # Errors are heuristics: Reason or Message containing "Failed" / "Error" / "err" (case-insensitive)
  local events
  events="$(safe_oc -n "$NS" get events --sort-by=metadata.creationTimestamp --no-headers 2>/dev/null || true)"
  if [[ -z "$events" ]]; then
    WARN_COUNT=0
    ERR_COUNT=0
    return 0
  fi
  WARN_COUNT="$(echo "$events" | awk '$1=="Warning"{c++} END{print c+0}')"
  ERR_COUNT="$(echo "$events" | grep -Ei 'failed|error|err:' | wc -l | tr -d ' ')"
}

get_storagecluster_phase() {
  safe_oc -n "$NS" get storagecluster ocs-storagecluster -o jsonpath='{.status.phase}{"\n"}' | head -n1
}

get_ceph_health() {
  safe_oc -n "$NS" get cephcluster ocs-storagecluster-cephcluster -o jsonpath='{.status.ceph.health}{"\n"}' | head -n1
}

get_noobaa_phase() {
  safe_oc -n "$NS" get noobaa noobaa -o jsonpath='{.status.phase}{"\n"}' | head -n1
}

has_csi_driver() {
  # expects openshift-storage.rbd/cephfs/nfs drivers to exist
  local out
  out="$(safe_oc get csidriver --no-headers 2>/dev/null | awk '{print $1}' | grep -E '^openshift-storage\.(rbd|cephfs|nfs)\.csi\.ceph\.com$' || true)"
  [[ -n "$out" ]]
}

storageclass_mismatch_count() {
  # Check key SC provisioners (best-effort). Returns mismatch count.
  # Expected provisioners:
  #   ocs-storagecluster-ceph-rbd  -> openshift-storage.rbd.csi.ceph.com
  #   ocs-storagecluster-cephfs   -> openshift-storage.cephfs.csi.ceph.com
  #   ocs-storagecluster-ceph-rgw -> openshift-storage.ceph.rook.io/bucket
  local mism=0
  local sc prov exp

  while IFS=$'\t' read -r sc prov exp; do
    if safe_oc get sc "$sc" >/dev/null 2>&1; then
      local actual
      actual="$(safe_oc get sc "$sc" -o jsonpath='{.provisioner}{"\n"}' | head -n1)"
      if [[ -n "$actual" && "$actual" != "$exp" ]]; then
        mism=$((mism+1))
      fi
    fi
  done <<'EOF'
ocs-storagecluster-ceph-rbd	(provisioner)	openshift-storage.rbd.csi.ceph.com
ocs-storagecluster-cephfs	(provisioner)	openshift-storage.cephfs.csi.ceph.com
ocs-storagecluster-ceph-rgw	(provisioner)	openshift-storage.ceph.rook.io/bucket
EOF

  echo "$mism"
}

odf_health_state() {
  # Determine overall health state: OK / WARNING / ERROR
  local sc_phase ceph noobaa_phase sc_mism
  sc_phase="$(get_storagecluster_phase)"
  ceph="$(get_ceph_health)"
  noobaa_phase="$(get_noobaa_phase)"
  sc_mism="$(storageclass_mismatch_count)"
  count_events

  local state="OK"

  # Severe conditions
  if [[ "$ceph" =~ HEALTH_ERR|HEALTH_ERROR ]] || [[ "$ERR_COUNT" -gt 0 ]]; then
    state="ERROR"
  fi

  # Warnings and degraded states
  if [[ "$state" != "ERROR" ]]; then
    if [[ "$ceph" =~ HEALTH_WARN ]] || [[ "$WARN_COUNT" -gt 0 ]] || [[ "$sc_mism" -gt 0 ]]; then
      state="WARNING"
    fi
  fi

  # If core components are not ready (best-effort)
  if [[ "$state" == "OK" ]]; then
    if [[ -n "$sc_phase" && "$sc_phase" != "Ready" && "$sc_phase" != "ready" ]]; then
      state="WARNING"
    fi
    if [[ -n "$noobaa_phase" && "$noobaa_phase" != "Ready" && "$noobaa_phase" != "ready" && "$noobaa_phase" != "Available" ]]; then
      # Only elevate if NooBaa exists and is not healthy
      state="WARNING"
    fi
  fi

  # CSI drivers missing is at least WARNING
  if ! has_csi_driver; then
    state="ERROR"
  fi

  echo "$state"
}

# ODF version detection (best-effort) from CSV
detect_odf_version_tag() {
  # Prefer ODF operator CSV version, then map "4.20.0" -> "v4.20"
  local line ver major_minor
  line="$(safe_oc -n "$NS" get csv | egrep -i 'odf|ocs|rook|noobaa|cephcsi' | head -n1 || true)"
  ver="$(echo "$line" | awk '{print $2}' | head -n1)"
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
    major_minor="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    echo "$major_minor"
    return 0
  fi
  echo ""
}

###############################################################################
# Report
###############################################################################

echo
hr
echo "ODF Cluster Healthcheck Report"
hr
echo
echo "Timestamp (UTC): ${TS_UTC}"
echo "Mode: ${MODE}"
echo "Namespace: ${NS}"
echo "Kubernetes / OpenShift Server Version: ${k8s_server}"
echo "Logfile: ${LOGFILE}"
echo

section "ODF Cluster Overview"

{
  echo -e "KIND\tNAME\tPHASE/HEALTH\tAGE"
  safe_oc -n "$NS" get storagecluster ocs-storagecluster --no-headers 2>/dev/null | awk '{print "StorageCluster\t"$1"\t"$2"\t"$3}'
  safe_oc -n "$NS" get cephcluster ocs-storagecluster-cephcluster --no-headers 2>/dev/null | awk '{print "CephCluster\t"$1"\t"$6"\t"$5}'
  safe_oc -n "$NS" get noobaa noobaa --no-headers 2>/dev/null | awk '{print "NooBaa\t"$1"\t"$6"\t"$7}'
} | table
echo

section "ODF Core Objects"

if [[ "$MODE" == "detailed" ]]; then
  {
    echo -e "RESOURCE\tNAME\tDETAIL"
    safe_oc -n "$NS" get storagecluster ocs-storagecluster -o jsonpath='{.metadata.name}{"\tphase="}{.status.phase}{"\tmsg="}{.status.conditions[0].message}{"\n"}' 2>/dev/null | sed 's/^/StorageCluster\t/' || true
    safe_oc -n "$NS" get cephcluster ocs-storagecluster-cephcluster -o jsonpath='{.metadata.name}{"\thealth="}{.status.ceph.health}{"\tmsg="}{.status.message}{"\n"}' 2>/dev/null | sed 's/^/CephCluster\t/' || true
    safe_oc -n "$NS" get noobaa noobaa -o jsonpath='{.metadata.name}{"\tphase="}{.status.phase}{"\tmsg="}{.status.conditions[0].message}{"\n"}' 2>/dev/null | sed 's/^/NooBaa\t/' || true
    safe_oc -n "$NS" get cephblockpool --no-headers 2>/dev/null | awk '{print "CephBlockPool\t"$1"\tphase="$2", type="$3", failureDomain="$4", age="$5}'
  } | table
else
  {
    echo -e "RESOURCE\tNAME\tSTATUS"
    safe_oc -n "$NS" get storagecluster --no-headers 2>/dev/null | awk '{print "StorageCluster\t"$1"\t"$2}'
    safe_oc -n "$NS" get cephcluster --no-headers 2>/dev/null | awk '{print "CephCluster\t"$1"\t"$6}'
    safe_oc -n "$NS" get noobaa --no-headers 2>/dev/null | awk '{print "NooBaa\t"$1"\t"$6}'
    safe_oc -n "$NS" get cephblockpool --no-headers 2>/dev/null | awk '{print "CephBlockPool\t"$1"\t"$2}'
  } | table
fi
echo

section "ODF Ceph Health"

{
  echo -e "CEPHCLUSTER\tHEALTH\tMESSAGE"
  safe_oc -n "$NS" get cephcluster ocs-storagecluster-cephcluster -o jsonpath='{.metadata.name}{"\t"}{.status.ceph.health}{"\t"}{.status.message}{"\n"}' 2>/dev/null || true
} | table
echo

section "ODF CSI Drivers"

{
  echo -e "NAME\tATTACHREQUIRED\tMODES\tAGE"
  safe_oc get csidriver --no-headers 2>/dev/null | awk '{print $1"\t"$2"\t"$7"\t"$8}' | grep -E '^openshift-storage\.' || true
} | table
echo

section "ODF CSI Pods (openshift-storage)"

if [[ "$MODE" == "detailed" ]]; then
  {
    echo -e "POD\tREADY\tSTATUS\tRESTARTS\tAGE\tNODE"
    safe_oc -n "$NS" get pods -o wide --no-headers 2>/dev/null | \
      egrep -i 'csi|rbd|cephfs|nfs' | \
      awk '{print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$7}'
  } | table
else
  {
    echo -e "POD\tSTATUS\tAGE\tNODE"
    safe_oc -n "$NS" get pods -o wide --no-headers 2>/dev/null | \
      egrep -i 'csi|rbd|cephfs|nfs' | \
      awk '{print $1"\t"$3"\t"$5"\t"$7}'
  } | table
fi
echo

section "ODF StorageClasses (provisioner check)"

{
  echo -e "STORAGECLASS\tPROVISIONER\tDEFAULT"
  safe_oc get sc --no-headers 2>/dev/null | \
    awk '{
      name=$1; prov=$2; def="";
      for(i=1;i<=NF;i++){
        if($i ~ /default/){def=$i}
      }
      print name"\t"prov"\t"def
    }' | egrep -i 'ocs-storagecluster|openshift-storage|ceph' || true
} | table
echo

# Add an explicit expected mapping check
{
  echo -e "CHECK\tSTORAGECLASS\tEXPECTED_PROVISIONER\tACTUAL_PROVISIONER\tRESULT"
  for sc in ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs ocs-storagecluster-ceph-rgw; do
    if safe_oc get sc "$sc" >/dev/null 2>&1; then
      actual="$(safe_oc get sc "$sc" -o jsonpath='{.provisioner}{"\n"}' | head -n1)"
      expected=""
      case "$sc" in
        ocs-storagecluster-ceph-rbd) expected="openshift-storage.rbd.csi.ceph.com" ;;
        ocs-storagecluster-cephfs)  expected="openshift-storage.cephfs.csi.ceph.com" ;;
        ocs-storagecluster-ceph-rgw) expected="openshift-storage.ceph.rook.io/bucket" ;;
      esac
      if [[ -n "$expected" && "$actual" == "$expected" ]]; then
        echo -e "Provisioner\t${sc}\t${expected}\t${actual}\tOK"
      else
        echo -e "Provisioner\t${sc}\t${expected}\t${actual}\tMISMATCH"
      fi
    else
      echo -e "Provisioner\t${sc}\t(n/a)\t(n/a)\tNOT_FOUND"
    fi
  done
} | table
echo

section "ODF NooBaa / CNPG Cluster"

{
  echo -e "RESOURCE\tNAME\tSTATUS\tDETAIL"
  safe_oc -n "$NS" get noobaa noobaa --no-headers 2>/dev/null | awk '{print "NooBaa\t"$1"\t"$6"\timage="$5}'
  safe_oc -n "$NS" get clusters.postgresql.cnpg.noobaa.io --no-headers 2>/dev/null | awk '{print "CNPG Cluster\t"$1"\t"$2"\tinstances="$3", ready="$4", age="$5}'
} | table
echo

if [[ "$MODE" == "detailed" ]]; then
  echo
  echo "CNPG Cluster Describe (noobaa-db-pg-cluster):"
  echo
  safe_oc -n "$NS" describe clusters.postgresql.cnpg.noobaa.io noobaa-db-pg-cluster
  echo
fi

section "ODF PVC / PV Overview"

{
  echo -e "TYPE\tNAMESPACE\tNAME\tSTATUS\tSC\tCAPACITY\tVOLUME"
  safe_oc -n "$NS" get pvc --no-headers 2>/dev/null | awk '{print "PVC\t'"$NS"'\t"$1"\t"$2"\t"$6"\t"$4"\t"$3}'
  safe_oc get pv --no-headers 2>/dev/null | awk '{print "PV\t-\t"$1"\t"$5"\t"$6"\t"$2"\t"$4}'
} | table
echo

section "ODF Events (openshift-storage)"

if [[ "$MODE" == "detailed" ]]; then
  {
    echo -e "TYPE\tREASON\tAGE\tFROM\tMESSAGE"
    safe_oc -n "$NS" get events --sort-by=metadata.creationTimestamp --no-headers 2>/dev/null | \
      awk '{
        type=$1; reason=$2; age=$3; from=$4;
        $1=$2=$3=$4="";
        sub(/^ +/,"");
        msg=$0;
        print type"\t"reason"\t"age"\t"from"\t"msg
      }'
  } | table
else
  {
    echo -e "TYPE\tREASON\tAGE\tMESSAGE"
    safe_oc -n "$NS" get events --sort-by=metadata.creationTimestamp --no-headers 2>/dev/null | tail -n 50 | \
      awk '{
        type=$1; reason=$2; age=$3;
        $1=$2=$3=$4="";
        sub(/^ +/,"");
        msg=$0;
        print type"\t"reason"\t"age"\t"msg
      }'
  } | table
fi
echo

section "Summary"

count_events
SC_PHASE="$(get_storagecluster_phase)"
CEPH_HEALTH="$(get_ceph_health)"
NOOBAA_PHASE="$(get_noobaa_phase)"
SC_MISMATCH="$(storageclass_mismatch_count)"
CSI_PRESENT="NO"
if has_csi_driver; then CSI_PRESENT="YES"; fi
ODF_STATE="$(odf_health_state)"

SC_STATUS="WARN"
[[ "${SC_PHASE:-}" == "Ready" || "${SC_PHASE:-}" == "ready" ]] && SC_STATUS="OK"
CEPH_STATUS="WARN"
[[ "${CEPH_HEALTH:-}" == "HEALTH_OK" ]] && CEPH_STATUS="OK"
NOOBAA_STATUS="WARN"
[[ "${NOOBAA_PHASE:-}" == "Ready" || "${NOOBAA_PHASE:-}" == "ready" || "${NOOBAA_PHASE:-}" == "Available" ]] && NOOBAA_STATUS="OK"
CSI_STATUS="ERROR"
[[ "$CSI_PRESENT" == "YES" ]] && CSI_STATUS="OK"
SC_MISMATCH_STATUS="WARN"
[[ "${SC_MISMATCH}" == "0" ]] && SC_MISMATCH_STATUS="OK"
WARN_STATUS="WARN"
[[ "${WARN_COUNT}" == "0" ]] && WARN_STATUS="OK"
ERR_STATUS="ERROR"
[[ "${ERR_COUNT}" == "0" ]] && ERR_STATUS="OK"

odf_hint="-"
[[ "$ODF_STATE" != "OK" ]] && odf_hint="Hinweis: Gesamtzustand nicht OK. Prüfe Ceph-/NooBaa-Ressourcen und Events in ${NS}."

sc_hint="-"
[[ "$SC_STATUS" != "OK" ]] && sc_hint="Hinweis: StorageCluster ist nicht Ready. oc -n ${NS} describe storagecluster ocs-storagecluster."

ceph_hint="-"
[[ "$CEPH_STATUS" != "OK" ]] && ceph_hint="Hinweis: Ceph meldet Probleme. oc -n ${NS} describe cephcluster ocs-storagecluster-cephcluster."

noobaa_hint="-"
[[ "$NOOBAA_STATUS" != "OK" ]] && noobaa_hint="Hinweis: NooBaa ist nicht Ready. oc -n ${NS} describe noobaa noobaa."

csi_hint="-"
[[ "$CSI_STATUS" != "OK" ]] && csi_hint="Hinweis: Erwartete CSI-Treiber fehlen. oc get csidriver | grep openshift-storage."

scm_hint="-"
[[ "$SC_MISMATCH_STATUS" != "OK" ]] && scm_hint="Hinweis: StorageClass-Provisioner prüfen. oc get sc ocs-storagecluster-* -o yaml."

warn_hint="-"
[[ "$WARN_STATUS" != "OK" ]] && warn_hint="Hinweis: Aktuelle Warn-Events analysieren. oc -n ${NS} get events --sort-by=metadata.creationTimestamp."

err_hint="-"
[[ "$ERR_STATUS" != "OK" ]] && err_hint="Hinweis: Fehler-Events untersuchen. oc -n ${NS} get events | grep -Ei 'Failed|Error'."

{
  echo -e "ITEM\tVALUE\tSTATUS\tHINT"
  echo -e "Cluster Namespace\t${NS}\tINFO\t-"
  echo -e "Timestamp (UTC)\t${TS_UTC}\tINFO\t-"
  echo -e "Mode\t${MODE}\tINFO\t-"
  echo -e "Logfile\t${LOGFILE}\tINFO\t-"
  echo -e "ODF Health State\t${ODF_STATE}\t${ODF_STATE}\t${odf_hint}"
  echo -e "StorageCluster Phase\t${SC_PHASE:-unknown}\t${SC_STATUS}\t${sc_hint}"
  echo -e "Ceph Health\t${CEPH_HEALTH:-unknown}\t${CEPH_STATUS}\t${ceph_hint}"
  echo -e "NooBaa Phase\t${NOOBAA_PHASE:-unknown}\t${NOOBAA_STATUS}\t${noobaa_hint}"
  echo -e "Ceph CSI Drivers Registered\t${CSI_PRESENT}\t${CSI_STATUS}\t${csi_hint}"
  echo -e "StorageClass Mismatches\t${SC_MISMATCH}\t${SC_MISMATCH_STATUS}\t${scm_hint}"
  echo -e "Events Warnings (count)\t${WARN_COUNT}\t${WARN_STATUS}\t${warn_hint}"
  echo -e "Events Errors (heuristic count)\t${ERR_COUNT}\t${ERR_STATUS}\t${err_hint}"
} | table
echo

section "Create must-gather report"

echo "Must-gather is the standard OpenShift way to collect cluster diagnostics for troubleshooting and support."
echo "It gathers relevant logs, resource definitions, and operator state into a single directory."
echo

echo "Detecting ODF-related CSVs:"
echo
safe_oc -n "$NS" get csv | egrep -i 'odf|ocs|rook|noobaa|cephcsi' || true
echo

TAG="$(detect_odf_version_tag)"
if [[ -z "$TAG" ]]; then
  TAG="v4.20"
  echo "ODF version tag could not be reliably detected. Using a default tag: ${TAG}"
else
  echo "Detected ODF version tag: ${TAG}"
fi
echo

echo "Ready-to-run must-gather command:"
echo
cat <<EOF
oc adm must-gather \\
  --image=registry.redhat.io/odf4/odf-must-gather-rhel9:${TAG} \\
  --dest-dir=must-gather-odf
EOF
echo
