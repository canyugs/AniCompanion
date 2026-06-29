#!/usr/bin/env python3
"""Convert an MMD PMX model to VRM with Blender add-ons.

Run with Blender, not system Python, for example:

BLENDER_USER_SCRIPTS=/tmp/anicomp_blender_user blender --background \
  --python Tools/convert_pmx_to_vrm.py -- \
  --pmx /tmp/UsadaPekora/PMX/UsadaPekora.pmx \
  --output AniCompanion/Resources/VRMModel/UsadaPekora.vrm \
  --opencc-path /tmp/anicomp_opencc
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    else:
        argv = []

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pmx", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--opencc-path", type=Path)
    parser.add_argument("--debug-blend", type=Path)
    parser.add_argument("--scale", type=float, default=0.08)
    return parser.parse_args(argv)


def enable_addons(opencc_path: Path | None) -> None:
    if opencc_path:
        sys.path.insert(0, str(opencc_path))

    import addon_utils

    for module_name in ("mmd_tools", "io_scene_vrm"):
        addon_utils.enable(module_name, default_set=True)


def clear_scene() -> None:
    import bpy

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def import_pmx(pmx_path: Path, scale: float) -> None:
    import bpy

    result = bpy.ops.mmd_tools.import_model(
        filepath=str(pmx_path),
        types={"MESH", "ARMATURE", "PHYSICS", "DISPLAY", "MORPHS"},
        scale=scale,
        clean_model=True,
        remove_doubles=False,
        fix_bone_order=True,
        fix_ik_links=True,
        apply_bone_fixed_axis=True,
        rename_bones=True,
        use_underscore=False,
        log_level="INFO",
    )
    if result != {"FINISHED"}:
        raise RuntimeError(f"PMX import failed: {result}")


def largest_armature():
    import bpy

    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if not armatures:
        raise RuntimeError("No armature found after PMX import")
    return max(armatures, key=lambda obj: len(obj.data.bones))


def select_armature(armature) -> None:
    import bpy

    bpy.ops.object.mode_set(mode="OBJECT") if bpy.context.object else None
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature


def configure_vrm(armature) -> None:
    import bpy

    select_armature(armature)
    armature.data.vrm_addon_extension.spec_version = "1.0"

    meta = armature.data.vrm_addon_extension.vrm1.meta
    meta.vrm_name = "Usada Pekora"
    meta.version = "1.0.0"
    if not meta.authors:
        meta.authors.add()
    meta.authors[0].value = "Converted locally from PMX"
    meta.copyright_information = "See original PMX model license"
    meta.contact_information = ""
    meta.third_party_licenses = "See original PMX model license"
    meta.avatar_permission = "onlyAuthor"
    meta.allow_excessively_violent_usage = False
    meta.allow_excessively_sexual_usage = False
    meta.commercial_usage = "personalNonProfit"
    meta.allow_political_or_religious_usage = False
    meta.allow_antisocial_or_hate_usage = False
    meta.credit_notation = "required"
    meta.allow_redistribution = False
    meta.modification = "allowModification"

    auto_result = bpy.ops.vrm.assign_vrm1_humanoid_human_bones_automatically(
        armature_object_name=armature.name
    )
    print(f"automatic bone assignment: {auto_result}")

    assign_usada_pekora_human_bones(armature)

    steps = (
        ("estimated humanoid T-pose", bpy.ops.vrm.make_estimated_humanoid_t_pose),
        ("MMD expressions", bpy.ops.vrm.assign_vrm1_expressions_from_mmd),
        ("MMD spring bones", bpy.ops.vrm.assign_spring_bone1_from_mmd),
    )

    for label, operator in steps:
        result = operator(armature_object_name=armature.name)
        print(f"{label}: {result}")


def cleanup_scene_for_export(armature) -> None:
    import bpy

    def has_ancestor_named(obj, names: set[str]) -> bool:
        parent = obj.parent
        while parent:
            if parent.name in names:
                return True
            parent = parent.parent
        return False

    character_meshes = {
        obj
        for obj in bpy.context.scene.objects
        if obj.type == "MESH"
        and obj.parent == armature
        and len(obj.data.vertices) > 1000
        and len(obj.data.materials) > 1
    }
    if not character_meshes:
        raise RuntimeError("No character mesh found for VRM export")

    helper_roots = {"rigidbodies", "joints"}
    removable = []
    for obj in bpy.context.scene.objects:
        if obj.type in {"CAMERA", "LIGHT"}:
            removable.append(obj)
            continue
        if obj.name in helper_roots or has_ancestor_named(obj, helper_roots):
            removable.append(obj)
            continue
        if obj.type == "MESH" and obj not in character_meshes:
            removable.append(obj)

    for obj in sorted(removable, key=lambda candidate: len(candidate.children), reverse=True):
        bpy.data.objects.remove(obj, do_unlink=True)


def assign_usada_pekora_human_bones(armature) -> None:
    human_bones = armature.data.vrm_addon_extension.vrm1.humanoid.human_bones
    mapping = {
        "hips": "腰",
        "spine": "上半身",
        "chest": "上半身2",
        "neck": "首",
        "head": "頭",
        "left_eye": "目.L",
        "right_eye": "目.R",
        "left_shoulder": "肩.L",
        "left_upper_arm": "腕.L",
        "left_lower_arm": "ひじ.L",
        "left_hand": "手首.L",
        "right_shoulder": "肩.R",
        "right_upper_arm": "腕.R",
        "right_lower_arm": "ひじ.R",
        "right_hand": "手首.R",
        "left_upper_leg": "足.L",
        "left_lower_leg": "ひざ.L",
        "left_foot": "足首.L",
        "left_toes": "足先EX.L",
        "right_upper_leg": "足.R",
        "right_lower_leg": "ひざ.R",
        "right_foot": "足首.R",
        "right_toes": "足先EX.R",
        "left_thumb_metacarpal": "親指０.L",
        "left_thumb_proximal": "親指１.L",
        "left_thumb_distal": "親指２.L",
        "left_index_proximal": "人指１.L",
        "left_index_intermediate": "人指２.L",
        "left_index_distal": "人指３.L",
        "left_middle_proximal": "中指１.L",
        "left_middle_intermediate": "中指２.L",
        "left_middle_distal": "中指３.L",
        "left_ring_proximal": "薬指１.L",
        "left_ring_intermediate": "薬指２.L",
        "left_ring_distal": "薬指３.L",
        "left_little_proximal": "小指１.L",
        "left_little_intermediate": "小指２.L",
        "left_little_distal": "小指３.L",
        "right_thumb_metacarpal": "親指０.R",
        "right_thumb_proximal": "親指１.R",
        "right_thumb_distal": "親指２.R",
        "right_index_proximal": "人指１.R",
        "right_index_intermediate": "人指２.R",
        "right_index_distal": "人指３.R",
        "right_middle_proximal": "中指１.R",
        "right_middle_intermediate": "中指２.R",
        "right_middle_distal": "中指３.R",
        "right_ring_proximal": "薬指１.R",
        "right_ring_intermediate": "薬指２.R",
        "right_ring_distal": "薬指３.R",
        "right_little_proximal": "小指１.R",
        "right_little_intermediate": "小指２.R",
        "right_little_distal": "小指３.R",
    }

    existing_bones = set(armature.data.bones.keys())
    for human_bone_attribute, model_bone_name in mapping.items():
        if model_bone_name not in existing_bones:
            raise RuntimeError(f"Missing PMX bone for VRM mapping: {model_bone_name}")
        getattr(human_bones, human_bone_attribute).node.bone_name = model_bone_name


def dump_summary(armature) -> None:
    import bpy

    mesh_count = sum(1 for obj in bpy.context.scene.objects if obj.type == "MESH")
    shape_key_count = 0
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or not obj.data.shape_keys:
            continue
        shape_key_count += max(0, len(obj.data.shape_keys.key_blocks) - 1)

    print(f"armature: {armature.name}")
    print(f"bones: {len(armature.data.bones)}")
    print(f"meshes: {mesh_count}")
    print(f"shape_keys: {shape_key_count}")

    human_bones = armature.data.vrm_addon_extension.vrm1.humanoid.human_bones
    required = (
        "hips",
        "spine",
        "head",
        "left_upper_arm",
        "left_lower_arm",
        "left_hand",
        "right_upper_arm",
        "right_lower_arm",
        "right_hand",
        "left_upper_leg",
        "left_lower_leg",
        "left_foot",
        "right_upper_leg",
        "right_lower_leg",
        "right_foot",
    )
    for human_bone_name in required:
        human_bone = getattr(human_bones, human_bone_name)
        bone_name = human_bone.node.bone_name
        print(f"human_bone {human_bone_name}: {bone_name}")


def export_vrm(output_path: Path, armature) -> None:
    import bpy
    from io_scene_vrm.editor.validation import WM_OT_vrm_validator

    output_path.parent.mkdir(parents=True, exist_ok=True)

    class ValidationRecord:
        name = ""
        severity = 0
        message = ""

    class ValidationCollection(list):
        def add(self):
            record = ValidationRecord()
            self.append(record)
            return record

    validation_errors = ValidationCollection()
    has_validation_error = WM_OT_vrm_validator.detect_errors(
        bpy.context,
        validation_errors,
        armature.name,
        execute_migration=True,
    )
    for error in validation_errors:
        print(f"validation severity={error.severity}: {error.message}")
    if has_validation_error:
        raise RuntimeError("VRM validation failed")

    result = bpy.ops.export_scene.vrm(
        filepath=str(output_path),
        armature_object_name=armature.name,
        ignore_warning=True,
        export_invisibles=False,
        export_only_selections=False,
        export_all_influences=False,
        export_lights=False,
        export_gltf_animations=False,
    )
    if result != {"FINISHED"}:
        raise RuntimeError(f"VRM export failed: {result}")


def main() -> None:
    args = parse_args()
    if not args.pmx.exists():
        raise FileNotFoundError(args.pmx)

    enable_addons(args.opencc_path)
    clear_scene()
    import_pmx(args.pmx, args.scale)
    armature = largest_armature()
    configure_vrm(armature)
    cleanup_scene_for_export(armature)
    dump_summary(armature)

    if args.debug_blend:
        import bpy

        args.debug_blend.parent.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(args.debug_blend))

    export_vrm(args.output, armature)
    print(f"exported: {args.output}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback

        traceback.print_exc()
        sys.exit(1)
