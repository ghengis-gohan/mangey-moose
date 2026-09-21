#!/usr/bin/env bash
# swap_workflow.sh — move the Jetson between the three fleets by relabeling it.
#
#   ./swap_workflow.sh yolo      # COCO-class detections (YOLO26)
#   ./swap_workflow.sh traffic   # DeepStream resnet10_4class
#   ./swap_workflow.sh imu       # AltIMU-10 v5 dashboard on :8080
#   ./swap_workflow.sh status    # what's running on the device right now
#
# Prereqs: `flightctl login` done; all three fleet YAMLs applied once:
#   for f in fleet-specs/fleet-{yolo,traffic,imu}.yaml; do flightctl apply -f $f; done
#
# NOTE on the label command: verify which of these your flightctl CLI has,
# *before* Wednesday, with `flightctl --help`:
#   flightctl label device/<name> inference=traffic --overwrite   (newer CLIs)
#   flightctl edit device/<name>                                  (always works: edit metadata.labels)
# The Edge Manager UI can also edit device labels directly, which is the most
# visual option for a live audience.

set -euo pipefail

TARGET="${1:-status}"
DEVICE="${DEVICE:-$(flightctl get devices -o json | jq -r '.items[0].metadata.name')}"

case "$TARGET" in
  yolo|traffic|imu)
    echo "[swap] device=$DEVICE -> inference=$TARGET"
    if flightctl label --help >/dev/null 2>&1; then
      flightctl label "device/${DEVICE}" "inference=${TARGET}" --overwrite
    else
      echo "[swap] this CLI has no 'label' subcommand; patching via get/apply"
      flightctl get "device/${DEVICE}" -o yaml \
        | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); d['metadata']['labels']['inference']='${TARGET}'; d.pop('status',None); print(yaml.safe_dump(d))" \
        | flightctl apply -f -
    fi
    echo "[swap] watching until applications settle (Ctrl-C to stop)"
    watch -n 2 "flightctl get device/${DEVICE} -o json | jq '{updated: .status.updated, apps: .status.applications, summary: .status.applicationsSummary}'"
    ;;
  status)
    flightctl get "device/${DEVICE}" -o json | jq '{labels: .metadata.labels, updated: .status.updated, apps: .status.applications}'
    ;;
  *)
    echo "usage: $0 {yolo|traffic|imu|status}" >&2; exit 2 ;;
esac
