#!/usr/bin/env tclsh
#   Copyright 2018-2026 The University of Birmingham
#   Copyright 2018-2026 Max-Planck-Institute for Physics
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# @file
# Pack a Libero project into Hog file structure
# Extracts HDL files, constraints, and SmartDesign components from an existing
# Libero project *directory* and creates the corresponding Hog list files.
#
# The .prjx is deliberately never read. It is not a trustworthy source: it
# records absolute, machine-specific paths (/home/<user>/... baked in at save
# time), and it keeps entries for files that have since been moved or deleted.
# The directory itself is the truth - the files that are actually there, plus
# the settings Libero maintains alongside them:
#   - device + HDL language : smartgen/smartgen.aws
#   - Libero version        : libero_setup_info.txt
#   - top module            : not on disk in any reliable form, so it must be
#                             stated explicitly via PACK's -top option
#   - SmartDesign DRCs      : written to the generated hog.conf [smartdesign]
#                             section, read back by rebuild_smartdesign.tcl
#
# Usage: Called from Hog/Do PACK <project_name> -top <module>
# Assumes: Projects/<project_name>/ exists, or -project_dir points elsewhere

## Helper proc to recursively copy directory contents
proc CopyDirectory {src dst} {
    file mkdir $dst
    foreach item [glob -nocomplain -directory $src *] {
        set tail [file tail $item]
        set dest_path [file join $dst $tail]

        if {[file isdirectory $item]} {
            CopyDirectory $item $dest_path
        } else {
            file copy -force $item $dest_path
        }
    }
}

## Helper proc to recursively find .v/.vhd files under a directory
proc FindFilesByExt {dir exts} {
    set found [list]
    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            foreach f [FindFilesByExt $item $exts] { lappend found $f }
        } elseif {[lsearch $exts [string tolower [file extension $item]]] >= 0} {
            lappend found $item
        }
    }
    return $found
}

proc FindHdlFiles {dir} {
    return [FindFilesByExt $dir {.v .vhd .vhdl}]
}

## Helper function to make paths relative
proc MakeRelative {base target} {
    set base [file normalize $base]
    set target [file normalize $target]

    # Convert to list of path components
    set base_parts [file split $base]
    set target_parts [file split $target]

    # Find common prefix
    set common_len 0
    foreach b $base_parts t $target_parts {
        if {$b ne $t} break
        incr common_len
    }

    # Calculate relative path
    set up_count [expr {[llength $base_parts] - $common_len}]
    set rel_parts {}
    for {set i 0} {$i < $up_count} {incr i} {
        lappend rel_parts ".."
    }

    set down_parts [lrange $target_parts $common_len end]
    set rel_parts [concat $rel_parts $down_parts]

    set result [eval file join $rel_parts]

    # CRITICAL: Always use forward slashes for cross-platform compatibility
    # Replace Windows backslashes with forward slashes
    set result [string map {\\ /} $result]

    return $result
}

## @brief Locates a vault directory tree ("Components/<vendor>/<library>/") to
#  search for cached IP core payloads, beyond Libero's per-user vault.
#
#  Libero ships a shared, system-wide vault next to each installed version -
#  e.g. C:/Microchip/Common/vault/Components sits alongside
#  C:/Microchip/Libero_SoC_2025.2/ - which holds the complete generator
#  payload for any IP that shipped bundled with the toolchain (SystemBuilder
#  cores like MIV_ESS in particular: confirmed present in the system vault
#  even on a machine whose PER-USER vault ($env(HOME)/.actel/vault) has never
#  seen that core at all). The per-user vault is where downloaded or
#  previously-instantiated cores land; the system vault is where anything
#  that came with the install already lives, and neither location implies
#  the other.
#
#  There's no documented Tcl command to ask Libero directly where this is
#  (add_vault/change_vault_location only let you point Libero AT one), and
#  it can be admin-relocated away from the installer default entirely - so
#  this is a best-effort default-layout guess, derived from the running
#  executable's own path rather than hardcoded, with no fallback needed: if
#  it guesses wrong, the search below simply finds nothing there and PACK
#  behaves exactly as it did before this proc existed.
#
#  @return path to a system-wide "vault/Components" directory, or "" if the
#          default installer layout wasn't found near the running executable
proc HogSystemVaultComponentsDir {} {
  set dir [file dirname [info nameofexecutable]]
  # Installer layout is <root>/<Libero_SoC_xxxx>/Libero_SoC/Designer/bin/ -
  # walk up looking for a "Common" sibling of the versioned Libero_SoC_xxxx
  # directory, capped well above that depth in case of an unusual install.
  for {set i 0} {$i < 8} {incr i} {
    set candidate [file join $dir Common vault Components]
    if {[file isdirectory $candidate]} {
      return $candidate
    }
    set parent [file dirname $dir]
    if {$parent eq $dir} {
      break
    }
    set dir $parent
  }
  return ""
}

## @brief Checks whether a complete (generator-included, not just a bare
#  descriptor) vault entry exists for a given core, in either Libero's
#  per-user vault or its system-wide one (see HogSystemVaultComponentsDir).
#
#  "Complete" uses the same test as the per-user-vault check this
#  generalizes: a core_xml.zip package plus at least one payload fileset
#  directory under fs/ next to the p0f0 descriptor one. Bare/hollow vault
#  entries (confirmed to occur - see the core_vlnvs comment above) fail this
#  and are correctly treated as absent.
#
#  @param[in] vendor core vendor (VLNV part 1)
#  @param[in] library core library (VLNV part 2)
#  @param[in] name core name (VLNV part 3)
#  @param[in] version core version (VLNV part 4)
#
#  @return the "Components" directory the complete entry was found under
#          (per-user or system), or "" if neither has one
proc HogFindCompleteVaultEntry {vendor library name version} {
  set search_roots [list]
  if {[info exists ::env(HOME)]} {
    lappend search_roots [file join $::env(HOME) .actel vault Components]
  }
  set system_root [HogSystemVaultComponentsDir]
  if {$system_root ne ""} {
    lappend search_roots $system_root
  }
  foreach root $search_roots {
    set candidate [file join $root $vendor $library $name $version]
    if {[file exists [file join $candidate pkg core_xml.zip]] &&
        [llength [glob -nocomplain -directory [file join $candidate fs] *]] >= 2} {
      return $root
    }
  }
  return ""
}

## Main packing function
## @param[in] project_name Name of the project (e.g., "smm-ethercat")
## @param[in] repo_path Path to repository root
## @param[in] force If 1, overwrite existing Top directory
## @param[in] top_module Name of the top-level module / SmartDesign. Required:
##                       nothing on disk marks the design root unambiguously,
##                       so it is stated explicitly rather than guessed.
## @param[in] force If 1, overwrite existing Top directory
## @param[in] source_dir Optional path to the source Libero project directory.
##                       If empty, defaults to <repo_path>/Projects/<project_name>.
proc PackLiberoProject {project_name repo_path top_module {force 0} {source_dir ""}} {

    if {$top_module eq ""} {
        Msg Error "PACK needs the name of the top module: pass it with -top <module>."
        return 1
    }

    # Resolve the source Libero project directory. -project_dir lets PACK read
    # from a project that lives outside the repo; without it we keep the
    # original behaviour of packing from Projects/<project_name>.
    if {$source_dir ne ""} {
        set project_dir [file normalize $source_dir]
        if {![file isdirectory $project_dir]} {
            Msg Error "Specified project directory not found: $project_dir"
            return 1
        }
        Msg Info "Using specified Libero project directory: $project_dir"
    } else {
        set project_dir "$repo_path/Projects/$project_name"
        if {![file isdirectory $project_dir]} {
            Msg Error "No Libero project directory found at $project_dir"
            Msg Info "Use -project_dir to point PACK at the project you want to pack from"
            return 1
        }
    }
    set project_location $project_dir

    # Create output directory
    set top_dir "$repo_path/Top/$project_name"
    if {[file exists $top_dir]} {
        if {$force == 0} {
            Msg Error "Directory $top_dir already exists. Use -recreate flag to overwrite."
            return 1
        }
        # Wipe it rather than overlay: PACK only ever writes files it knows
        # about this run, so a stale file from a previous PACK (e.g. an old
        # SmartDesign component that no longer exists) would otherwise be
        # silently left behind and could get sourced/added by mistake.
        Msg Warning "Recreating existing directory: $top_dir"
        file delete -force $top_dir
        file mkdir $top_dir
    } else {
        file mkdir $top_dir
        Msg Info "Created directory: $top_dir"
    }

    # Project settings, read from files Libero maintains on disk next to the
    # design - never from the .prjx (see the file header for why).
    set device_family ""
    set device_die ""
    set device_package ""
    set hdl_mode "VERILOG"
    set libero_version ""

    # Device and HDL language: smartgen/smartgen.aws. Each attribute is matched
    # on its own rather than as one fixed-order pattern, so a differently
    # ordered <device .../> tag still resolves.
    set aws_file "$project_location/smartgen/smartgen.aws"
    if {[file exists $aws_file]} {
        set fh [open $aws_file r]
        set aws_content [read $fh]
        close $fh

        if {[regexp {<device[^>]*>} $aws_content device_tag]} {
            regexp {die="([^"]*)"} $device_tag -> device_die
            regexp {family="([^"]*)"} $device_tag -> device_family
            regexp {package="([^"]*)"} $device_tag -> device_package
        } else {
            Msg CriticalWarning "No <device .../> entry in $aws_file - FAMILY/DIE/PACKAGE will be\
            empty in the generated hog.conf and must be filled in by hand before CREATE."
        }
        if {[regexp {<hdltype>([^<]+)</hdltype>} $aws_content -> aws_hdl]} {
            set hdl_mode [string toupper [string trim $aws_hdl]]
        }
    } else {
        Msg CriticalWarning "No $aws_file found, so the device cannot be determined - FAMILY/DIE/PACKAGE\
        will be empty in the generated hog.conf and must be filled in by hand before CREATE."
    }

    # Libero version: libero_setup_info.txt
    set setup_file "$project_location/libero_setup_info.txt"
    if {[file exists $setup_file]} {
        set fh [open $setup_file r]
        set setup_content [read $fh]
        close $fh
        regexp {Libero Release\s*:\s*(\S+)} $setup_content -> libero_version
    }

    Msg Info "Top Module: $top_module"
    Msg Info "Device: $device_family $device_die $device_package"
    Msg Info "HDL Mode: $hdl_mode"

    # Copy the project's sources into the repo *before* building the file
    # lists, so the scan below reads one canonical tree. src/ is what the
    # build actually consumes and what is git-tracked; the Libero project
    # directory is gitignored and is not guaranteed to exist for whoever
    # clones the repo and runs CREATE. Copying first also means a project
    # whose own hdl/ is empty (because its sources already live in src/)
    # packs correctly instead of producing empty lists.
    Msg Info "Copying source files to src/ directory..."
    set src_hdl_dir "$repo_path/src/hdl/$project_name"
    set src_con_dir "$repo_path/src/constraints/$project_name"

    # An empty source directory is not an error and not a no-op worth
    # announcing: it just means this project keeps its files in src/ already
    # (which the scan below reads either way).
    foreach {sub_dir copy_dst copy_what} [list \
        hdl        $src_hdl_dir             "HDL" \
        constraint $src_con_dir             "constraint" \
        stimulus   "$src_hdl_dir/stimulus"  "stimulus"] {
        set copy_src "$project_location/$sub_dir"
        if {[file isdirectory $copy_src] && [llength [glob -nocomplain -directory $copy_src *]] > 0} {
            CopyDirectory $copy_src $copy_dst
            Msg Info "Copied $copy_what files to $copy_dst"
        }
    }

    # Build the file lists by scanning the tree. Everything goes into the
    # "work" library: that is the library the SmartDesign component scripts
    # hardcode (-library {work}), and a list file's basename has to match its
    # library exactly or create_hdl_core silently fails to resolve the file
    # (see the list-writing comment below).
    set library "work"
    set src_files [list]
    set sim_files [list]
    set con_files [list]

    set stimulus_dir [file normalize "$src_hdl_dir/stimulus"]
    set gen_cores_dir [file normalize "$src_hdl_dir/generated_cores"]

    foreach hdl_file [FindHdlFiles $src_hdl_dir] {
        set norm_file [file normalize $hdl_file]
        # stimulus/ is testbench material and belongs in .sim, not .src.
        if {[string first "$stimulus_dir/" $norm_file] == 0} {
            continue
        }
        # generated_cores/ is written later in this same run by the
        # SmartDesign static-core fallback, which appends its own entries to
        # the .src list - including them here as well would duplicate them.
        if {[string first "$gen_cores_dir/" $norm_file] == 0} {
            continue
        }
        lappend src_files $norm_file
    }

    if {[file isdirectory $stimulus_dir]} {
        foreach sim_file [FindHdlFiles $stimulus_dir] {
            lappend sim_files [file normalize $sim_file]
        }
    }

    if {[file isdirectory $src_con_dir]} {
        foreach con_file [FindFilesByExt $src_con_dir {.sdc .pdc}] {
            lappend con_files [file normalize $con_file]
        }
    }

    # Sort so a re-PACK of an unchanged tree produces byte-identical lists;
    # directory traversal order is not guaranteed to be stable otherwise.
    # -nocase rather than plain lsort: it keeps names in the order they read
    # in a listing (asynchronous_clks.sdc before EtherCAT_timing.sdc) instead
    # of hoisting every capitalised name to the top the way ASCII ordering
    # does. Not -dictionary, which would additionally compare digit runs
    # numerically and so order pck_myhdl_07 before pck_myhdl_011.
    set src_files [lsort -nocase $src_files]
    set sim_files [lsort -nocase $sim_files]
    set con_files [lsort -nocase $con_files]

    Msg Info "Writing Hog List Files..."

    # Create list subdirectory
    set list_dir "$top_dir/list"
    file mkdir $list_dir

    # Write the source list file. Its basename becomes the Libero library name
    # Hog imports it under (AddHogFiles derives it via
    # [file rootname [file tail <list file>]]) - it must be exactly $library,
    # with no extra suffix, or it stops matching the -library value hardcoded
    # into the SmartDesign component scripts ("work"), and create_hdl_core
    # then can't resolve the file at all: it silently behaves as if -file were
    # never given.
    #
    # Every path written below is already inside the repo (the files were
    # copied into src/ above), so MakeRelative yields a clean repo-relative
    # path with no absolute or Projects/ references baked in.
    if {[llength $src_files] > 0} {
        set list_file "$list_dir/${library}.src"
        set fp [open $list_file w]
        set top_found 0

        foreach file_path $src_files {
            set rel_path [MakeRelative $repo_path $file_path]

            # Tag the file that actually defines the top module, which is what
            # drives SetTopProperty/set_root at CREATE time. A SmartDesign top
            # has no HDL file at all, so finding no match here is normal.
            if {[GetModuleName $file_path] eq [string tolower $top_module]} {
                puts $fp "$rel_path top=$top_module"
                set top_found 1
            } else {
                puts $fp $rel_path
            }
        }

        close $fp
        Msg Info "Created: $list_file ([llength $src_files] files)"
        if {!$top_found} {
            Msg Info "No HDL file defines '$top_module' - assuming it is the SmartDesign top,\
            which is rooted by the rebuild script instead."
        }
    } else {
        Msg CriticalWarning "No HDL files found under $src_hdl_dir - the generated project will have\
        no sources. Check that the Libero project you packed from actually has an hdl/ directory."
    }

    # Write the simulation list file. Same naming rule as the .src above: the
    # basename becomes the Libero library name.
    if {[llength $sim_files] > 0} {
        set list_file "$list_dir/${library}.sim"
        set fp [open $list_file w]

        foreach file_path $sim_files {
            puts $fp [MakeRelative $repo_path $file_path]
        }

        close $fp
        Msg Info "Created: $list_file ([llength $sim_files] files)"
    }

    # Write constraint list file
    if {[llength $con_files] > 0} {
        set list_file "$list_dir/main_constraints.con"
        set fp [open $list_file w]

        foreach file_path $con_files {
            puts $fp [MakeRelative $repo_path $file_path]
        }

        close $fp
        Msg Info "Created: $list_file ([llength $con_files] files)"
    }

    # Find and copy SmartDesign TCL reconstruction scripts (if they exist).
    # These recreate the *live*, GUI-editable SmartDesign block inside Libero
    # via its native SmartDesign Tcl API (create_smartdesign, sd_instantiate_*,
    # generate_component, ...). We intentionally do NOT cache the SmartDesign's
    # generated top-level netlist as a static HDL source: that would freeze the
    # design and, once the SmartDesign is rebuilt, would collide with it (two
    # definitions of the same top-level module in the "work" library).
    set smartdesign_dir "$project_location/$top_module"
    if {[file exists $smartdesign_dir]} {
        set sd_components [glob -nocomplain "$smartdesign_dir/components/*.tcl"]

        if {[llength $sd_components] > 0} {
            set sd_dir "$top_dir/smartdesign"
            set sd_components_dir "$sd_dir/components"
            file mkdir $sd_components_dir

            # Copy each component TCL, rewriting any hdl-relative file
            # reference (create_hdl_core -file, sd_instantiate_hdl_module
            # -hdl_file) to point at the file's permanent home in src/hdl/,
            # since the original Libero project's hdl directory lives only in
            # the gitignored Projects/ and will not exist for anyone who pulls
            # the repo and runs CREATE.
            #
            # The brace characters used to build the regexes below are
            # produced via format rather than typed literally in this source
            # file: a literal open or close brace here would also be seen
            # (and counted) by Tcl's own brace-matcher for the enclosing proc
            # body, not just by the regexp engine, and that kind of mismatch
            # is invisible until the whole file fails to parse.
            set ob [format %c 123]
            set cb [format %c 125]

            # Collect every IP core (vendor:library:name:version) referenced
            # by create_and_configure_core across the components, so the
            # rebuild script can pre-fetch anything we can't avoid depending
            # on Libero's own catalog/generator for (see the per-file loop
            # below).
            set core_vlnvs [list]
            # Subset of core_vlnvs whose catalog data lives in Libero's user
            # vault (~/.actel/vault/Components) rather than this project's
            # component/ tree. SystemBuilder cores in particular never appear
            # under component/<vendor>/ at all, and SgCore entries there are
            # generation *output* without the generator - the vault copy is
            # the complete, generator-included form for both. These get
            # cached from (and restored to) the vault, not component/.
            set vault_vlnvs [list]

            # create_and_configure_core produces a real "Component", which
            # carries any bus interfaces (BIFs - AXI4, APB, ...) its catalog
            # definition declares, and PROC_SUBSYSTEM.tcl's sd_connect_pins
            # calls for interface-level connections (e.g. "...:AXI4mmaster0"
            # "...:BIF_1") depend on that. create_hdl_core produces a
            # different kind of object (an "HDL Core") that starts with none
            # of that: unless every one of those interfaces is manually
            # redeclared with hdl_core_add_bif (which is what axi4Upper/
            # axi4VHDL/ECAT_WRAPPER already do, hand-written into the
            # original design), sd_connect_pins fails with "Parameter 'to'
            # is missing" for anything trying to connect to it at the
            # interface level. So create_and_configure_core, backed by the
            # cached vault/catalog data below, is the *preferred* path for
            # anything that already has cached data beyond a bare
            # descriptor. The generated_cores/create_hdl_core route further
            # below exists only as a last resort for cores whose cache truly
            # is just a thin reference (e.g. Actel:SgCore:PF_INIT_MONITOR:
            # 2.0.308, confirmed by repeated direct testing to have no cached
            # generator content anywhere, and whose download_core call
            # reports "successfully downloaded" while silently writing
            # nothing at all) - such cores had better not expose any BIFs of
            # their own, or this fallback will silently drop them.
            set generated_hdl_files [list]
            # Names that switched from create_and_configure_core to
            # create_hdl_core above: Libero treats these as two genuinely
            # different object types (an "HDL Core" vs. a "Component"), and
            # the canvas script instantiates them with different commands
            # (sd_instantiate_hdl_core -hdl_core_name vs.
            # sd_instantiate_component -component_name). Every name in this
            # list needs its instantiation call in the canvas script patched
            # to match, or sd_instantiate_component fails with "The
            # component '<name>::work' doesn't exist" - it's simply the
            # wrong lookup for what create_hdl_core actually created.
            set hdl_core_fallback_names [list]

            foreach tcl_file $sd_components {
                set tcl_name [file tail $tcl_file]
                set fh [open $tcl_file r]
                set sd_content [read $fh]
                close $fh

                set cac_match [regexp -- \
                    "create_and_configure_core\\s+-core_vlnv\\s+\\${ob}(\[^${cb}\]+)\\${cb}\\s+-component_name\\s+\\${ob}(\[^${cb}\]+)\\${cb}" \
                    $sd_content -> cac_vlnv cac_name]

                set used_static_fallback 0
                if {$cac_match} {
                    # Prefer create_and_configure_core (via the cached
                    # catalog data below) whenever this project's cache for
                    # it is usable: that's a real Component, with correct
                    # BIF/interface support. Only fall back to a static
                    # create_hdl_core wrapper (which can't carry any BIFs)
                    # when it isn't.
                    #
                    # "Usable" depends on the core's library. DirectCore/
                    # SystemBuilder/MiV cores are pre-built, static IP:
                    # cached RTL plus the .cxf descriptor is enough, and
                    # that's confirmed working (e.g. COREAXI4INTERCONNECT).
                    # SgCore ("SmartGen") cores are parametrically generated
                    # instead, and confirmed by direct, repeated testing to
                    # still fail create_and_configure_core with "Cannot find
                    # Spirit core configuration file" even with a full cached
                    # RTL+cxf set, UNLESS the actual generator script is also
                    # present - a plain RTL cache is this project's *output*
                    # from a previous generation, not the generator itself.
                    set catalog_complete 0
                    set vault_hit 0
                    set cac_vlnv_parts [split $cac_vlnv ":"]
                    if {[llength $cac_vlnv_parts] == 4} {
                        lassign $cac_vlnv_parts cac_vendor cac_lib cac_corename cac_ver
                        # A core present in EITHER of Libero's two vaults is
                        # fully usable (descriptor + generator) regardless of
                        # what this project's component/ tree carries, so it
                        # always counts as complete:
                        #  - the per-user vault ($env(HOME)/.actel/vault),
                        #    where download_core deposits cores and the
                        #    first place create_and_configure_core looks;
                        #  - Libero's system-wide vault (see
                        #    HogSystemVaultComponentsDir), which holds
                        #    whatever shipped bundled with the install
                        #    itself - e.g. Actel:SystemBuilder:MIV_ESS
                        #    confirmed present there while entirely absent
                        #    from the per-user vault - and is otherwise
                        #    identical in format.
                        # The entry must actually carry its payload though -
                        # download_core is known to leave partial entries
                        # behind: either completely hollow directories
                        # (Actel:SgCore:PF_INIT_MONITOR:2.0.308) or ones
                        # with the descriptor unpacked under fs/p0f0 but
                        # none of the generator/RTL filesets it references
                        # (Actel:SystemBuilder:PF_SRAM_AHBL_AXI:1.2.111) -
                        # and create_and_configure_core rejects both with
                        # "Cannot find Spirit core configuration file".
                        # Complete entries always have at least one payload
                        # fileset directory under fs/ next to the p0f0
                        # descriptor one - see
                        # HogFindCompleteVaultEntry, which applies this same
                        # test to both vault locations.
                        set vault_root [HogFindCompleteVaultEntry $cac_vendor $cac_lib $cac_corename $cac_ver]
                        if {$vault_root ne ""} {
                            set catalog_complete 1
                            set vault_hit 1
                            set vault_roots($cac_vlnv) $vault_root
                        }
                        set catalog_src "$project_location/component/$cac_vendor/$cac_lib/$cac_corename/$cac_ver"
                        if {[file exists $catalog_src]} {
                            set catalog_items [glob -nocomplain -directory $catalog_src *]
                            set has_more_than_cxf 0
                            if {[llength $catalog_items] > 1} {
                                set has_more_than_cxf 1
                            } elseif {[llength $catalog_items] == 1 &&
                                    [string tolower [file extension [lindex $catalog_items 0]]] ne ".cxf"} {
                                set has_more_than_cxf 1
                            }
                            if {$has_more_than_cxf} {
                                if {[string equal -nocase $cac_lib "SgCore"]} {
                                    if {[llength [FindFilesByExt $catalog_src {.tcl}]] > 0} {
                                        set catalog_complete 1
                                    }
                                } else {
                                    set catalog_complete 1
                                }
                            }
                        }
                    }

                    set gen_dir "$project_location/component/work/$cac_name"
                    set gen_top ""
                    if {!$catalog_complete} {
                        if {[file exists "$gen_dir/$cac_name.v"]} {
                            set gen_top "$cac_name.v"
                        } elseif {[file exists "$gen_dir/$cac_name.vhd"]} {
                            set gen_top "$cac_name.vhd"
                        }
                    }
                    if {$gen_top ne ""} {
                        Msg Warning "$cac_name ($cac_vlnv) has no cached catalog data beyond a bare descriptor,\
                        so it's being packed as a static HDL core from this project's already-generated output\
                        instead of a live Component. If $cac_name exposes any bus interfaces (BIFs) in the\
                        canvas, connections to it will fail - re-run PACK once this core's full catalog data is\
                        available (e.g. after building this design once with a Libero install/catalog that has\
                        it) to get proper Component support instead."
                        set gen_dst "$repo_path/src/hdl/$project_name/generated_cores/$cac_name"
                        CopyDirectory $gen_dir $gen_dst
                        foreach hf [FindHdlFiles $gen_dst] {
                            lappend generated_hdl_files [Relative $repo_path $hf]
                        }
                        set sd_content "# $cac_name: reusing this project's own already-generated output\n"
                        append sd_content "# (component/work/$cac_name/) instead of create_and_configure_core,\n"
                        append sd_content "# which depends on Libero's online IP catalog/generator being\n"
                        append sd_content "# complete and reachable at CREATE time - unreliable in practice,\n"
                        append sd_content "# see the comment above core_vlnvs in pack_project.tcl.\n"
                        append sd_content "create_hdl_core -file \"\$::HOG_SD_HDL_DIR/generated_cores/$cac_name/$gen_top\"\
                            -module {$cac_name} -library {work} -package {}\n"
                        # Recover the bus interfaces (BIFs) the original
                        # component declared, from its .cxf in the source
                        # project: a bare create_hdl_core carries none, so
                        # any interface-level sd_connect_pins in the canvas
                        # (e.g. "...:AXI4_Slave", "...:APBSlave") would fail
                        # with "Parameter 'to' is missing". hdl_core_add_bif
                        # re-declares them - the same mechanism the design's
                        # own hand-made HDL+ cores (axi4Upper etc.) use.
                        set cxf_file "$gen_dir/$cac_name.cxf"
                        if {[file exists $cxf_file]} {
                            set fh [open $cxf_file r]
                            set cxf_content [read $fh]
                            close $fh
                            if {[regexp {<busInterfaces>(.*)</busInterfaces>} $cxf_content -> bifs_xml]} {
                                foreach bif_xml [split [string map [list "</busInterface>" "\x01"] $bifs_xml] "\x01"] {
                                    if {[string first "<busInterface>" $bif_xml] < 0} {
                                        continue
                                    }
                                    if {![regexp {<name>([^<]+)</name>} $bif_xml -> bif_name]} {
                                        continue
                                    }
                                    if {![regexp {<busType library="([^"]+)" name="([^"]+)" vendor="([^"]+)"} \
                                        $bif_xml -> bt_lib bt_name bt_vendor]} {
                                        continue
                                    }
                                    set bif_role [expr {[string first "<slave/>" $bif_xml] >= 0 ? "slave" : "master"}]
                                    set map_entries [list]
                                    foreach {m csig bsig} [regexp -all -inline \
                                        {<componentSignalName>([^<]+)</componentSignalName><busSignalName>([^<]+)</busSignalName>} \
                                        $bif_xml] {
                                        lappend map_entries "\"$bsig:$csig\""
                                    }
                                    append sd_content "hdl_core_add_bif -hdl_core_name {$cac_name}\
                                        -bif_definition {$bt_name:$bt_vendor:$bt_lib:$bif_role}\
                                        -bif_name {$bif_name} -signal_map { [join $map_entries " "] }\n"
                                    Msg Info "Recovered BIF '$bif_name' ($bt_name $bif_role) for static HDL core\
                                    $cac_name from its .cxf"
                                }
                            }
                        }
                        set used_static_fallback 1
                        lappend hdl_core_fallback_names $cac_name
                        Msg Info "Reusing generated output for $cac_name (skipping create_and_configure_core for\
                        $cac_vlnv)"
                    } else {
                        if {[lsearch -exact $core_vlnvs $cac_vlnv] < 0} {
                            lappend core_vlnvs $cac_vlnv
                        }
                        if {$vault_hit && [lsearch -exact $vault_vlnvs $cac_vlnv] < 0} {
                            lappend vault_vlnvs $cac_vlnv
                        }
                        if {$catalog_complete} {
                            Msg Debug "$cac_name ($cac_vlnv) has complete cached catalog data - keeping\
                            create_and_configure_core, cached via core_vlnvs/ip_cache below"
                        } else {
                            Msg Warning "No cached catalog data or generated output found for $cac_name at\
                            $gen_dir - CREATE will have to get $cac_vlnv from Libero's catalog or download_core"
                        }
                    }
                }

                if {!$used_static_fallback} {
                    # Tcl's regexp uses POSIX leftmost-longest overall
                    # matching, so a non-greedy dot-star here would still
                    # expand all the way to the last closing brace on the
                    # line (e.g. the one ending an empty -package argument).
                    # Matching "anything but a closing brace" instead is
                    # what actually bounds this to the current argument.
                    regsub -all "(-file)(\\s+)\\${ob}hdl/(\[^${cb}\]+)\\${cb}" $sd_content \
                        {\1\2"$::HOG_SD_HDL_DIR/\3"} sd_content
                    regsub -all "(-file)(\\s+)\\${ob}hdl\\\\(\[^${cb}\]+)\\${cb}" $sd_content \
                        {\1\2"$::HOG_SD_HDL_DIR/\3"} sd_content
                    # -hdl_file (sd_instantiate_hdl_module) cannot take the
                    # absolute path -file (create_hdl_core) is happy with:
                    # Libero resolves it relative to the project directory and
                    # blames the failure on the module being a "sub-module".
                    # HogSdHdlFile (create_project.tcl) does that conversion at
                    # CREATE time, when the project directory is known.
                    regsub -all "(-hdl_file)(\\s+)\\${ob}hdl/(\[^${cb}\]+)\\${cb}" $sd_content \
                        "\\1\\2\[HogSdHdlFile ${ob}\\3${cb}\]" sd_content
                    regsub -all "(-hdl_file)(\\s+)\\${ob}hdl\\\\(\[^${cb}\]+)\\${cb}" $sd_content \
                        "\\1\\2\[HogSdHdlFile ${ob}\\3${cb}\]" sd_content
                }

                set fh [open "$sd_components_dir/$tcl_name" w]
                puts -nonewline $fh $sd_content
                close $fh
            }
            Msg Info "Copied [llength $sd_components] SmartDesign components to $sd_components_dir"

            # Patch the canvas script's instantiation calls for every name
            # that became an HDL Core above (see hdl_core_fallback_names).
            # Done as a post-pass, once every component file has been seen,
            # since a name's fallback status isn't known until then; string
            # map is safe here regardless of order because it does exact,
            # non-overlapping literal substitution, not regex/glob matching.
            if {[llength $hdl_core_fallback_names] > 0} {
                set canvas_file "$sd_components_dir/${top_module}.tcl"
                if {[file exists $canvas_file]} {
                    set fh [open $canvas_file r]
                    set canvas_content [read $fh]
                    close $fh

                    set swap_map [list]
                    foreach name $hdl_core_fallback_names {
                        lappend swap_map \
                            "sd_instantiate_component -sd_name \$\{sd_name\} -component_name {$name}" \
                            "sd_instantiate_hdl_core -sd_name \$\{sd_name\} -hdl_core_name {$name}"
                    }
                    set canvas_content [string map $swap_map $canvas_content]

                    set fh [open $canvas_file w]
                    puts -nonewline $fh $canvas_content
                    close $fh
                    Msg Info "Patched [llength $hdl_core_fallback_names] instantiation call(s) in\
                    ${top_module}.tcl to use sd_instantiate_hdl_core"
                }
            }

            # Add every generated-core HDL file to the HDL library list file,
            # so Hog imports it exactly like any other source. This has to
            # happen after the fact (in append mode): the list files were
            # already written above, before we knew which cores would need
            # their generated output pulled in.
            if {[llength $generated_hdl_files] > 0} {
                set primary_library $library
                set fp [open "$list_dir/${primary_library}.src" a]
                foreach hf $generated_hdl_files {
                    puts $fp $hf
                }
                close $fp
                Msg Info "Added [llength $generated_hdl_files] generated-core HDL file(s) to ${primary_library}.src"
            }

            # Cache each IP core that still needs create_and_configure_core
            # (no generated output was found for it above) under
            # smartdesign/ip_cache/, so a fresh CREATE can restore it straight
            # into the new project's own component/ directory instead of
            # depending on create_and_configure_core finding it in Libero's
            # local catalog, or on a "Hog/Do PACK"-time download_core call.
            set ip_cache_dir "$top_dir/smartdesign/ip_cache"
            set cached_vlnvs [list]
            # Vault-resident cores cached below keep their vault directory
            # format (fs/p0/pkg with the generator inside), which only works
            # restored back into a vault - never into component/. The rebuild
            # script uses this list to tell the two apart.
            set vault_cached_vlnvs [list]
            foreach vlnv $core_vlnvs {
                set vlnv_parts [split $vlnv ":"]
                if {[llength $vlnv_parts] != 4} {
                    Msg Warning "Core VLNV '$vlnv' doesn't look like vendor:library:name:version, skipping cache"
                    continue
                }
                lassign $vlnv_parts core_vendor core_lib core_name core_ver
                set from_vault 0
                if {[lsearch -exact $vault_vlnvs $vlnv] >= 0} {
                    # vault_roots was populated with whichever of the two
                    # vaults (per-user or system-wide) HogFindCompleteVaultEntry
                    # actually found this VLNV in - not necessarily the
                    # per-user one, see HogSystemVaultComponentsDir.
                    if {[info exists vault_roots($vlnv)]} {
                        set core_src [file join $vault_roots($vlnv) \
                            $core_vendor $core_lib $core_name $core_ver]
                    } else {
                        set core_src [file join $::env(HOME) .actel vault Components \
                            $core_vendor $core_lib $core_name $core_ver]
                    }
                    set from_vault 1
                } else {
                    set core_src "$project_location/component/$core_vendor/$core_lib/$core_name/$core_ver"
                }
                if {[file exists $core_src]} {
                    set core_dst "$ip_cache_dir/$core_vendor/$core_lib/$core_name/$core_ver"
                    CopyDirectory $core_src $core_dst
                    lappend cached_vlnvs $vlnv
                    if {$from_vault} {
                        lappend vault_cached_vlnvs $vlnv
                    }
                } else {
                    Msg Warning "IP core $vlnv not found at $core_src, cannot cache it - CREATE will have to fetch\
                    it from Libero's catalog or download_core instead"
                }
            }
            if {[llength $cached_vlnvs] > 0} {
                Msg Info "Cached [llength $cached_vlnvs] IP core(s) to $ip_cache_dir"
            }

            # Copy the main recursive TCL (if it exists), adapting it to run
            # standalone from Top/<project>/smartdesign/ instead of from
            # inside the original (gitignored) Libero project directory:
            #  - drop the "source hdl_source.tcl" step: Hog's own list files
            #    already imported every HDL file into the "work" library, so
            #    re-importing them here would just duplicate that work.
            #  - resolve "components/<file>.tcl" relative to this script's own
            #    location (via [info script]) instead of the process' CWD,
            #    since Tcl's `source` does not do that automatically.
            set recursive_tcl "$smartdesign_dir/${top_module}_recursive.tcl"
            if {[file exists $recursive_tcl]} {
                set fh [open $recursive_tcl r]
                set rec_content [read $fh]
                close $fh

                regsub -line {^source\s+hdl_source\.tcl\s*$} $rec_content {} rec_content
                regsub -all {source\s+components/([^\s]+\.tcl)} $rec_content \
                    {source [file join $script_dir components \1]} rec_content

                # Move every component that became a create_hdl_core (HDL
                # Core) above out of its original position and into the
                # "HDL+core definitions" group the original export already
                # put axi4Upper/axi4VHDL/ECAT_WRAPPER in (i.e. right before
                # the first build_design_hierarchy call in the file).
                # Interleaving create_hdl_core and create_and_configure_core
                # calls - which is what happens if these are left in their
                # original position, among the "individual components" group
                # that's still create_and_configure_core-based - was
                # confirmed by direct testing to make a *later*
                # create_and_configure_core call fail with "Cannot find
                # Spirit core configuration file", for a core whose cached
                # data is otherwise complete and works fine on its own.
                # Keeping every create_hdl_core call together in one batch,
                # like the original export already does for its own 3, is
                # what avoids that.
                if {[llength $hdl_core_fallback_names] > 0} {
                    set rc_lines [split $rec_content "\n"]
                    set moved_lines [list]
                    set remaining_lines [list]
                    foreach rc_line $rc_lines {
                        set is_moved 0
                        foreach fb_name $hdl_core_fallback_names {
                            if {[string first "components $fb_name.tcl" $rc_line] >= 0} {
                                lappend moved_lines $rc_line
                                set is_moved 1
                                break
                            }
                        }
                        if {!$is_moved} {
                            lappend remaining_lines $rc_line
                        }
                    }
                    set first_bdh_idx -1
                    for {set li 0} {$li < [llength $remaining_lines]} {incr li} {
                        if {[string trim [lindex $remaining_lines $li]] eq "build_design_hierarchy"} {
                            set first_bdh_idx $li
                            break
                        }
                    }
                    if {$first_bdh_idx >= 0} {
                        set rc_lines [concat [lrange $remaining_lines 0 [expr {$first_bdh_idx - 1}]] \
                            $moved_lines [lrange $remaining_lines $first_bdh_idx end]]
                    } else {
                        set rc_lines [concat $remaining_lines $moved_lines]
                    }
                    set rec_content [join $rc_lines "\n"]
                }

                # Insert a hierarchy refresh right before the top-level
                # canvas script (Libero always names it <top_module>.tcl,
                # sourced last, per the recursive-export's own "bottom-up"
                # convention). Without it, sd_instantiate_component fails
                # with "The component '<name>::work' doesn't exist" for
                # every component created earlier in this same script by
                # create_hdl_core/create_and_configure_core: Libero doesn't
                # make a newly created component available for instantiation
                # until build_design_hierarchy runs again after creating it,
                # and the original export never needed this refresh itself
                # because (in the GUI) each component already existed from a
                # previous, separate design session.
                set canvas_source_line "source \[file join \$script_dir components ${top_module}.tcl\]"
                set canvas_idx [string first $canvas_source_line $rec_content]
                if {$canvas_idx >= 0} {
                    set rec_content "[string range $rec_content 0 [expr {$canvas_idx - 1}]]build_design_hierarchy\n\
                        [string range $rec_content $canvas_idx end]"
                } else {
                    Msg Warning "Could not find the top-level canvas source line for $top_module in\
                    ${top_module}_recursive.tcl to insert a hierarchy refresh before it - if CREATE fails with\
                    \"component ... doesn't exist\" during sd_instantiate_component, add a build_design_hierarchy\
                    call right before \"source \[file join \$script_dir components $top_module.tcl\]\" by hand."
                }

                set rec_content "set script_dir \[file dirname \[info script\]\]\n\n$rec_content"

                set fh [open "$sd_dir/${top_module}_recursive.tcl" w]
                puts -nonewline $fh $rec_content
                close $fh
                Msg Info "Copied and adapted SmartDesign: ${top_module}_recursive.tcl"
            }

            # Create the rebuild script. Hog sources this once HDL files,
            # constraints and device properties are already in place (see
            # RebuildSmartDesign in create_project.tcl), so all it needs to do
            # is point the recursive script at where the HDL now lives and
            # (re)root the design on the freshly-generated SmartDesign.
            set rebuild_script "$sd_dir/rebuild_smartdesign.tcl"
            set fp [open $rebuild_script w]
            puts $fp "# SmartDesign rebuild script for $project_name"
            puts $fp "# Sourced by Hog during CREATE (see RebuildSmartDesign in"
            puts $fp "# create_project.tcl) to recreate the GUI SmartDesign hierarchy"
            puts $fp "# from the files cached under Top/$project_name/smartdesign/ and"
            puts $fp "# src/hdl/$project_name/. Never reads from Projects/, which is"
            puts $fp "# gitignored and not guaranteed to exist."
            puts $fp ""
            puts $fp "set script_dir \[file dirname \[info script\]\]"
            puts $fp "set ::HOG_SD_HDL_DIR \[file normalize \[file join \$script_dir .. .. .. src hdl $project_name\]\]"
            puts $fp ""
            # Apply the SmartDesign DRC severity settings: with cores rebuilt
            # as static HDL wrappers (whose interfaces expose no memory-map
            # ranges) generate_component's memory-map DRC reports empty target
            # ranges as hard errors, so they have to be downgraded to warnings.
            #
            # The values come from hog.conf's [smartdesign] section, written by
            # PACK and editable by hand afterwards - they are project settings,
            # not something to scrape back out of a .prjx. They deliberately do
            # not live in [project]: ConfigureProperties forwards every
            # [project] key to `project_settings -<key>` (create_project.tcl),
            # which would reject these, and it runs only after the rebuild
            # anyway - too late, since the DRCs must be set before the
            # SmartDesign is generated. globalSettings::PROPERTIES is populated
            # well before RebuildSmartDesign sources this script, and
            # ConfigureProperties ignores sections it doesn't know.
            puts $fp "# SmartDesign DRC severities, read from hog.conf's \[smartdesign\] section."
            puts $fp "# One single call on purpose: every smartdesign invocation resets the"
            puts $fp "# options it wasn't given back to their defaults, so issuing these as"
            puts $fp "# separate calls leaves only the last one actually applied."
            puts $fp "set hog_drc_args \[list\]"
            puts $fp "if {\[info exists globalSettings::PROPERTIES\] &&"
            puts $fp "    \[dict exists \$globalSettings::PROPERTIES smartdesign\]} {"
            puts $fp "    dict for {hog_drc_key hog_drc_val} \\"
            puts $fp "        \[dict get \$globalSettings::PROPERTIES smartdesign\] {"
            puts $fp "        # Value must be the literal string TRUE/FALSE: the smartdesign"
            puts $fp "        # command accepts (doesn't error on) other spellings like 1/0"
            puts $fp "        # but silently stores them as FALSE."
            puts $fp "        lappend hog_drc_args -\$hog_drc_key \[string toupper \$hog_drc_val\]"
            puts $fp "    }"
            puts $fp "}"
            puts $fp "if {\[llength \$hog_drc_args\] > 0} {"
            puts $fp "    smartdesign {*}\$hog_drc_args"
            puts $fp "}"
            puts $fp ""
            if {[llength $core_vlnvs] > 0} {
                puts $fp "# Make sure every IP core this design's components reference is"
                puts $fp "# present in this (freshly created, empty) project's own"
                puts $fp "# component/ directory before anything tries to use them:"
                puts $fp "# create_and_configure_core only ever uses what's already in the"
                puts $fp "# local catalog, and fails with \"Cannot find Spirit core"
                puts $fp "# configuration file...\" for anything missing. Restoring the copy"
                puts $fp "# cached under ip_cache/ (by Hog/Do PACK, from a project where this"
                puts $fp "# core was already known to work) is preferred over download_core:"
                puts $fp "# it needs no network access at build time, and download_core has"
                puts $fp "# been observed to silently report success without actually"
                puts $fp "# depositing a usable core for at least one core/version - it's"
                puts $fp "# kept only as a best-effort fallback for cores that weren't cached."
                puts $fp "set ip_cache_dir \[file join \$script_dir ip_cache\]"
                foreach vlnv $core_vlnvs {
                    set vlnv_parts [split $vlnv ":"]
                    lassign $vlnv_parts core_vendor core_lib core_name core_ver
                    set cache_rel "$core_vendor/$core_lib/$core_name/$core_ver"
                    if {[lsearch -exact $vault_cached_vlnvs $vlnv] >= 0} {
                        # Vault-format cache (fs/p0/pkg + generator): only a
                        # vault restore makes create_and_configure_core see
                        # it - dropping it into component/ does nothing. If
                        # this machine's vault already has this exact
                        # version, leave it alone.
                        puts $fp "set hog_vault_dst \[file join \$::env(HOME) .actel vault Components\
                            $core_vendor $core_lib $core_name\]"
                        puts $fp "if {!\[file exists \[file join \$hog_vault_dst $core_ver\]\]} {"
                        puts $fp "    if {\[file exists \[file join \$ip_cache_dir $cache_rel\]\]} {"
                        puts $fp "        file mkdir \$hog_vault_dst"
                        puts $fp "        file copy -force \[file join \$ip_cache_dir $cache_rel\]\
                            \[file join \$hog_vault_dst $core_ver\]"
                        puts $fp "    } else {"
                        puts $fp "        catch {download_core -vlnv {$vlnv}}"
                        puts $fp "    }"
                        puts $fp "}"
                    } elseif {[lsearch -exact $cached_vlnvs $vlnv] >= 0} {
                        puts $fp "if {\[file exists \[file join \$ip_cache_dir $cache_rel\]\]} {"
                        puts $fp "    file mkdir \[file join \$::HOG_SD_BUILD_DIR component\
                            $core_vendor $core_lib $core_name\]"
                        puts $fp "    file copy -force \[file join \$ip_cache_dir $cache_rel\]\
                            \[file join \$::HOG_SD_BUILD_DIR component $cache_rel\]"
                        puts $fp "} else {"
                        puts $fp "    catch {download_core -vlnv {$vlnv}}"
                        puts $fp "}"
                    } else {
                        puts $fp "catch {download_core -vlnv {$vlnv}}"
                    }
                }
                puts $fp ""
            }
            if {[file exists $recursive_tcl]} {
                puts $fp "source \[file join \$script_dir ${top_module}_recursive.tcl\]"
            } else {
                puts $fp "# No recursive TCL found - source components individually"
                foreach tcl_file $sd_components {
                    set tcl_name [file tail $tcl_file]
                    puts $fp "source \[file join \$script_dir components $tcl_name\]"
                }
            }
            puts $fp ""
            puts $fp "# The SmartDesign now exists as a live design unit: (re)root the"
            puts $fp "# project on it now that it has actually been generated."
            puts $fp "set_root -module $top_module"
            close $fp
            Msg Info "Created: $rebuild_script"
        }
    }

    # Write hog.conf
    set conf_file "$top_dir/hog.conf"
    set fp [open $conf_file w]

    # First line must specify IDE and version
    if {$libero_version != ""} {
        puts $fp "#libero $libero_version"
    } else {
        puts $fp "#libero 2026.1"
        Msg Warning "Could not read the Libero version from $setup_file, defaulting to 2026.1"
    }
    puts $fp ""
    puts $fp "\[main\]"
    # The top module is not a [main] key: for Libero, ConfigureProperties
    # forwards unrecognized [main] keys straight to `set_device`, which has
    # no -top option. The top module is instead conveyed via the `top=`
    # attribute on its file in the generated .src list file (see the "top"
    # handling in the source-list-writing loop above), which drives
    # SetTopProperty/set_root at CREATE time.
    puts $fp "FAMILY = $device_family"
    puts $fp "DIE = $device_die"
    puts $fp "PACKAGE = $device_package"
    puts $fp ""
    puts $fp "\[project\]"
    puts $fp ""
    # SmartDesign DRC severities. Read by the generated
    # smartdesign/rebuild_smartdesign.tcl (not by ConfigureProperties, which
    # ignores sections it doesn't recognise) before the SmartDesign is
    # generated. Each key is passed straight through as a `smartdesign`
    # option, so the key names are the option names; values must be TRUE or
    # FALSE. Edit these here rather than anywhere else - this file is the
    # setting's home now.
    puts $fp "\[smartdesign\]"
    puts $fp "memory_map_drc_change_error_to_warning = TRUE"
    puts $fp "bus_interface_data_width_drc_change_error_to_warning = TRUE"
    puts $fp "bus_interface_id_width_drc_change_error_to_warning = TRUE"
    puts $fp ""
    puts $fp "\[synth\]"
    puts $fp "# Synthesis settings"
    puts $fp ""
    puts $fp "\[impl\]"
    puts $fp "# Implementation settings"

    close $fp
    Msg Info "Created: $conf_file"

    Msg Status "=== Conversion Complete ==="
    Msg Status "Hog project created in: $top_dir"
    Msg Status "Source files copied to:"
    Msg Status "  - HDL: $src_hdl_dir"
    Msg Status "  - Constraints: $src_con_dir"
    Msg Status ""
    Msg Status "Next steps:"
    Msg Status "  1. Review the generated list files in $top_dir/list/"
    Msg Status "  2. Check smartdesign/ directory for SmartDesign components"
    Msg Status "  3. Test project creation with: ./Hog/Do CREATE $project_name"
    Msg Status ""
    Msg Status "NOTE: Projects/ directory is gitignored. All source files are now in src/"

    return 0
}
