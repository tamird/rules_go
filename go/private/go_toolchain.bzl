# Copyright 2016 The Bazel Go Rules Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""
Toolchain rules used by go.
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//go/private:common.bzl", "GO_TOOLCHAIN", "GO_TOOLCHAIN_LABEL")
load("//go/private:platforms.bzl", "PLATFORMS")
load("//go/private:providers.bzl", "GoSDK")
load("//go/private/actions:archive.bzl", "emit_archive")
load("//go/private/actions:binary.bzl", "emit_binary")
load("//go/private/actions:link.bzl", "emit_link")
load("//go/private/actions:stdlib.bzl", "emit_stdlib")

def _go_toolchain_impl(ctx):
    sdk = ctx.attr.sdk[GoSDK]
    name = "go.exe" if sdk.goos == "windows" else "go"
    go_on_path = ctx.actions.declare_file(ctx.label.name + "/path/" + name)
    ctx.actions.symlink(output = go_on_path, target_file = sdk.go, is_executable = True)
    cross_compile = ctx.attr.goos != sdk.goos or ctx.attr.goarch != sdk.goarch
    return [
        ctx.attr.sdk[DefaultInfo],
        platform_common.ToolchainInfo(
            # Public fields
            name = ctx.label.name,
            cross_compile = cross_compile,
            default_goos = ctx.attr.goos,
            default_goarch = ctx.attr.goarch,
            actions = struct(
                archive = emit_archive,
                binary = emit_binary,
                link = emit_link,
                stdlib = emit_stdlib,
            ),
            flags = struct(
                compile = (),
                link = ctx.attr.link_flags,
                link_cgo = ctx.attr.cgo_link_flags,
            ),
            sdk = sdk,

            # Internal fields -- may be read by emit functions.
            _builder = ctx.executable.builder,
            _go_on_path = go_on_path,
            _pack = ctx.executable.pack,
            _covdata = ctx.executable.covdata,
        ),
    ]

def go_run_with_sdk(ctx, *, executable, arguments = [], stdout = None, outputs = [], tools = [], **kwargs):
    """Runs an action with only the execution platform's Go command on PATH.

    If unset, GOROOT defaults to that SDK's root.

    Args:
        ctx: Rule context. The selected execution group must declare the Go toolchain.
        executable: An executable File or FilesToRunProvider for that execution group.
        arguments: Arguments to the executable, as for ctx.actions.run.
        stdout: Optional File to declare as an output and write standard output to.
        outputs: Other output Files.
        tools: Additional action tools, as for ctx.actions.run.
        **kwargs: Other ctx.actions.run arguments. PATH is set at execution time.
    """
    group = kwargs.get("exec_group")
    tc = (ctx.exec_groups[group] if group else ctx).toolchains[GO_TOOLCHAIN_LABEL]
    args = ctx.actions.args()
    sdk = tc.sdk
    args.add_all(["runwithsdk", tc._go_on_path, sdk.root_file, stdout or "", getattr(executable, "executable", executable)])
    sdk_files = depset([sdk.go, sdk.root_file], transitive = [sdk.srcs, sdk.headers, sdk.tools, sdk.libs])
    ctx.actions.run(
        executable = tc._builder,
        arguments = [args] + arguments,
        outputs = outputs + ([stdout] if stdout else []),
        tools = [executable, tc._go_on_path, sdk_files] + ([tools] if type(tools) == "depset" else tools),
        toolchain = GO_TOOLCHAIN_LABEL,
        **kwargs
    )

go_toolchain = rule(
    _go_toolchain_impl,
    attrs = {
        # Minimum requirements to specify a toolchain
        "builder": attr.label(
            mandatory = True,
            cfg = "exec",
            executable = True,
            doc = "Tool used to execute most Go actions",
        ),
        "pack": attr.label(
            mandatory = True,
            cfg = "exec",
            executable = True,
            doc = "Tool used to pack object files into archives",
        ),
        "covdata": attr.label(
            cfg = "exec",
            executable = True,
            doc = """Tool used to decode coverage meta-data files. If absent,
            no baseline coverage is emitted for packages without tests.""",
        ),
        "goos": attr.string(
            mandatory = True,
            doc = "Default target OS",
        ),
        "goarch": attr.string(
            mandatory = True,
            doc = "Default target architecture",
        ),
        "sdk": attr.label(
            mandatory = True,
            providers = [GoSDK],
            cfg = "exec",
            doc = "The SDK this toolchain is based on",
        ),
        # Optional extras to a toolchain
        "link_flags": attr.string_list(
            doc = "Flags passed to the Go internal linker",
        ),
        "cgo_link_flags": attr.string_list(
            doc = "Flags passed to the external linker (if it is used)",
        ),
    },
    doc = "Defines a Go toolchain based on an SDK",
    provides = [platform_common.ToolchainInfo],
)

def declare_go_toolchains(exec_goos, sdk, builder, pack, covdata):
    """Declares go_toolchain targets for each platform."""
    for p in PLATFORMS:
        if p.cgo:
            # Don't declare separate toolchains for cgo_on / cgo_off.
            continue

        link_flags = []
        cgo_link_flags = []
        if exec_goos == "darwin":
            cgo_link_flags.extend(["-shared", "-Wl,-all_load"])
        elif exec_goos == "linux":
            cgo_link_flags.append("-Wl,-whole-archive")

        go_toolchain(
            name = "go_" + p.name + "-impl",
            goos = p.goos,
            goarch = p.goarch,
            sdk = sdk,
            builder = builder,
            pack = pack,
            covdata = covdata,
            link_flags = link_flags,
            cgo_link_flags = cgo_link_flags,
            tags = ["manual"],
            visibility = ["//visibility:public"],
        )

def declare_bazel_toolchains(
        *,
        go_toolchain_repo,
        exec_goarch,
        exec_goos,
        major,
        minor,
        patch,
        prerelease,
        sdk_name,
        sdk_type,
        prefix = ""):
    """Declares toolchain targets for each platform."""

    sdk_version_label = Label("//go/toolchain:sdk_version")

    native.config_setting(
        name = prefix + "match_all_versions",
        flag_values = {
            sdk_version_label: "",
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_major_version",
        flag_values = {
            sdk_version_label: major,
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_major_minor_version",
        flag_values = {
            sdk_version_label: major + "." + minor,
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_patch_version",
        flag_values = {
            sdk_version_label: major + "." + minor + "." + patch,
        },
        visibility = ["//visibility:private"],
    )

    # If prerelease version is "", this will be the same as ":match_patch_version", but that's fine since we use match_any in config_setting_group.
    native.config_setting(
        name = prefix + "match_prerelease_version",
        flag_values = {
            sdk_version_label: major + "." + minor + "." + patch + prerelease,
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_minor_release_candidate",
        flag_values = {
            sdk_version_label: major + "." + minor + prerelease,
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_sdk_type",
        flag_values = {
            sdk_version_label: sdk_type,
        },
        visibility = ["//visibility:private"],
    )

    selects.config_setting_group(
        name = prefix + "sdk_version_setting",
        match_any = [
            ":" + prefix + "match_all_versions",
            ":" + prefix + "match_major_version",
            ":" + prefix + "match_major_minor_version",
            ":" + prefix + "match_patch_version",
            ":" + prefix + "match_prerelease_version",
            ":" + prefix + "match_minor_release_candidate",
            ":" + prefix + "match_sdk_type",
        ],
        visibility = ["//visibility:private"],
    )

    # use Label constructor to resolve the label relative to the package this bzl file
    # is located, instead of the context of the caller of declare_bazel_toolchains.
    # See https://bazel.build/rules/lib/builtins/Label#Label for details.
    sdk_name_label = Label("//go/toolchain:sdk_name")

    native.config_setting(
        name = prefix + "match_sdk_name",
        flag_values = {
            sdk_name_label: sdk_name,
        },
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = prefix + "match_all_sdks",
        flag_values = {
            sdk_name_label: "",
        },
        visibility = ["//visibility:private"],
    )

    selects.config_setting_group(
        name = prefix + "sdk_name_setting",
        match_any = [
            ":" + prefix + "match_all_sdks",
            ":" + prefix + "match_sdk_name",
        ],
        visibility = ["//visibility:private"],
    )

    for p in PLATFORMS:
        if p.cgo:
            # Don't declare separate toolchains for cgo_on / cgo_off.
            continue

        cgo_constraints = (
            "@io_bazel_rules_go//go/toolchain:cgo_off",
            "@io_bazel_rules_go//go/toolchain:cgo_on",
        )
        constraints = [c for c in p.constraints if c not in cgo_constraints]

        native.toolchain(
            # keep in sync with generate_toolchain_names
            name = prefix + "go_" + p.name,
            toolchain_type = GO_TOOLCHAIN,
            exec_compatible_with = [
                "@io_bazel_rules_go//go/toolchain:" + exec_goos,
                "@io_bazel_rules_go//go/toolchain:" + exec_goarch,
            ],
            target_compatible_with = constraints,
            target_settings = [
                ":" + prefix + "sdk_name_setting",
                ":" + prefix + "sdk_version_setting",
            ],
            toolchain = go_toolchain_repo + "//:go_" + p.name + "-impl",
        )
