#!/usr/bin/env bash
#
# Séance moved to https://github.com/L-K-M/Hauntware and this repository is
# archived, so there is nothing left to sync. This script no longer pulls or
# rebuilds anything; it only explains how to move the deployment.
set -euo pipefail

cat >&2 <<'MSG'
!!! Séance moved to https://github.com/L-K-M/Hauntware.
!!! This repository is archived and gets no updates, so ./update.sh no
!!! longer syncs or rebuilds the server. Move this deployment to a
!!! Hauntware clone as described in the section
!!! "Moving from a standalone Séance clone" of
!!! https://github.com/L-K-M/Hauntware/blob/main/seance/packages/seance_sync_server/README.md
MSG
exit 1
