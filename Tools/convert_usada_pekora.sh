#!/usr/bin/env bash
set -euo pipefail

ZIP_PATH="${1:-/Users/can/Downloads/UsadaPekora.zip}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_ROOT="${TMPDIR:-/tmp}/anicomp_usada_pekora_conversion"
BLENDER_USER_SCRIPTS_DIR="${WORK_ROOT}/blender_user"
ADDONS_DIR="${BLENDER_USER_SCRIPTS_DIR}/addons"
MMD_TOOLS_DIR="${WORK_ROOT}/blender_mmd_tools"
VRM_ADDON_DIR="${WORK_ROOT}/VRM-Addon-for-Blender"
OPENCC_DIR="${WORK_ROOT}/opencc"
MODEL_DIR="${WORK_ROOT}/model"

PMX_PATH="${MODEL_DIR}/UsadaPekora/PMX/UsadaPekora.pmx"
OUTPUT_PATH="${REPO_ROOT}/AniCompanion/Resources/VRMModel/UsadaPekora.vrm"
DEBUG_BLEND_PATH="${WORK_ROOT}/UsadaPekora-converted.blend"

if [[ ! -f "${ZIP_PATH}" ]]; then
  echo "Missing zip: ${ZIP_PATH}" >&2
  exit 1
fi

if ! command -v blender >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install --cask blender
  else
    echo "Blender is required and Homebrew is not available." >&2
    exit 1
  fi
fi

mkdir -p "${WORK_ROOT}" "${ADDONS_DIR}"

if [[ ! -d "${MMD_TOOLS_DIR}/.git" ]]; then
  rm -rf "${MMD_TOOLS_DIR}"
  git clone --depth 1 https://github.com/MMD-Blender/blender_mmd_tools.git "${MMD_TOOLS_DIR}"
fi

if [[ ! -d "${VRM_ADDON_DIR}/.git" ]]; then
  rm -rf "${VRM_ADDON_DIR}"
  git clone --depth 1 https://github.com/saturday06/VRM-Addon-for-Blender.git "${VRM_ADDON_DIR}"
fi

ln -sfn "${MMD_TOOLS_DIR}/mmd_tools" "${ADDONS_DIR}/mmd_tools"
ln -sfn "${VRM_ADDON_DIR}/src/io_scene_vrm" "${ADDONS_DIR}/io_scene_vrm"

rm -rf "${OPENCC_DIR}"
mkdir -p "${OPENCC_DIR}"
unzip -q "${MMD_TOOLS_DIR}/mmd_tools/wheels/opencc_python_reimplemented-0.1.7-py2.py3-none-any.whl" -d "${OPENCC_DIR}"

rm -rf "${MODEL_DIR}"
mkdir -p "${MODEL_DIR}"
unzip -q "${ZIP_PATH}" -d "${MODEL_DIR}"

BLENDER_USER_SCRIPTS="${BLENDER_USER_SCRIPTS_DIR}" blender --background \
  --python "${REPO_ROOT}/Tools/convert_pmx_to_vrm.py" -- \
  --pmx "${PMX_PATH}" \
  --output "${OUTPUT_PATH}" \
  --opencc-path "${OPENCC_DIR}" \
  --debug-blend "${DEBUG_BLEND_PATH}"

echo "Wrote ${OUTPUT_PATH}"
echo "Debug blend: ${DEBUG_BLEND_PATH}"
