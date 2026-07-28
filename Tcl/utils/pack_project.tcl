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
# The Libero .prjx file is deliberately NOT read: it bakes absolute,
# machine-specific paths and can carry stale entries (e.g. its own tooldata log
# has been observed reporting a different die than the real device). Everything
# is instead derived from the on-disk project/repo directory, which is the real,
# git-tracked source of truth:
#   - source/sim/constraint file lists : scanned from src/hdl|constraints/<project>/
#   - device family/die/package, HDL   : Projects/<project>/smartgen/smartgen.aws
#   - Libero version                   : Projects/<project>/libero_setup_info.txt
#   - top module                       : passed in explicitly (never guessed)
#   - SmartDesign DRC severities        : written to hog.conf, applied at CREATE
#
# Usage: Called from Hog/Do PACK <project_name> -top <top_module>
# Assumes: Projects/<project_name>/ exists

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

## Main packing function
## @param[in] project_name Name of the project (e.g., "smm-ethercat")
## @param[in] repo_path Path to repository root
## @param[in] top_module Top-level design unit (SmartDesign or HDL module).
##            Passed in explicitly - never inferred from the .prjx.
## @param[in] force If 1, overwrite existing Top directory
## @param[in] project_dir Optional path to the source Libero project directory.
##            If empty, defaults to the in-repo Projects/<project_name>/. Use it
##            to pack an external, self-contained Libero project (one that keeps
##            its files under <dir>/{hdl,constraint,stimulus}); those files are
##            copied into the repo's src/ tree, which is then the truth.
proc PackLiberoProject {project_name repo_path top_module {force 0} {project_dir ""}} {

    # The Libero project directory is the source of truth (never the .prjx).
    if {$project_dir ne ""} {
        set project_location [file normalize $project_dir]
    } else {
        set project_location [file normalize "$repo_path/Projects/$project_name"]
    }
    if {![file isdirectory $project_location]} {
        Msg Error "Libero project directory not found: $project_location"
        return 1
    }
    if {[string trim $top_module] eq ""} {
        Msg Error "PACK requires the top module: pass it with -top <module_name>"
        return 1
    }
    Msg Info "Packing Libero project directory: $project_location"
    Msg Info "Top module (explicit): $top_module"

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

    # ---- Project settings: read from the directory, never the .prjx ----------

    # Libero version: from libero_setup_info.txt ("Libero Release : 2026.1").
    set libero_version ""
    set setup_info "$project_location/libero_setup_info.txt"
    if {[file exists $setup_info]} {
        set fh [open $setup_info r]
        set si [read $fh]
        close $fh
        regexp -line {^Libero Release\s*:\s*(\S+)} $si -> libero_version
    }

    # Device + HDL type: from smartgen/smartgen.aws, whose <device .../> is the
    # authoritative on-disk record (the tooldata log has been seen to disagree
    # with, and be wrong versus, the real device - so it is not trusted).
    set device_family ""
    set device_die ""
    set device_package ""
    set hdl_mode "VERILOG"
    set aws_file "$project_location/smartgen/smartgen.aws"
    if {[file exists $aws_file]} {
        set fh [open $aws_file r]
        set aws [read $fh]
        close $fh
        regexp {<device\s+die="([^"]*)"\s+family="([^"]*)"\s+package="([^"]*)"} \
            $aws -> device_die device_family device_package
        regexp {<hdltype>([^<]*)</hdltype>} $aws -> hdl_mode
    } else {
        Msg Warning "smartgen.aws not found at $aws_file - device family/die/package will be empty in hog.conf"
    }

    Msg Info "Top Module: $top_module"
    Msg Info "Device: $device_family $device_die $device_package"
    Msg Info "HDL Mode: $hdl_mode"

    # ---- Populate src/ from the project, then scan src/ as the truth ---------
    # A self-contained Libero project keeps its files under Projects/<p>/{hdl,
    # constraint,stimulus}; copy anything present into the repo's src/ tree so
    # the scans below see a complete set. (When the project already references
    # files straight out of src/ these copies are simple no-ops.) Projects/ is
    # gitignored, so src/ is the permanent home the list files must point at.
    set src_hdl_dir "$repo_path/src/hdl/$project_name"
    set src_con_dir "$repo_path/src/constraints/$project_name"
    if {[file isdirectory "$project_location/hdl"]} {
        CopyDirectory "$project_location/hdl" $src_hdl_dir
    }
    if {[file isdirectory "$project_location/constraint"]} {
        CopyDirectory "$project_location/constraint" $src_con_dir
    }
    if {[file isdirectory "$project_location/stimulus"]} {
        CopyDirectory "$project_location/stimulus" "$src_hdl_dir/stimulus"
    }

    Msg Info "Writing Hog List Files (from the src/ directory)..."
    set list_dir "$top_dir/list"
    file mkdir $list_dir

    # Everything under src/hdl/<project>/ is imported into the "work" library:
    # the SmartDesign component scripts hardcode -library {work}, and the list
    # file's basename becomes the import library name (AddHogFiles derives it
    # via [file rootname [file tail <list file>]]). Kept as a one-entry dict so
    # the generated-core append further below can still find the primary .src.
    set src_files_by_lib [dict create work [list]]

    # work.src: every HDL file under src/hdl/<project>/, except the testbench
    # files under stimulus/ (they go to work.sim) and any generated-core output
    # under generated_cores/ (the SmartDesign section appends those itself).
    set src_list "$list_dir/work.src"
    set fp [open $src_list w]
    set src_count 0
    foreach f [lsort -nocase [FindHdlFiles $src_hdl_dir]] {
        set rel [MakeRelative $repo_path $f]
        if {[regexp {(^|/)stimulus/} $rel] || [regexp {(^|/)generated_cores/} $rel]} {
            continue
        }
        # Tag the top module's file so CREATE's SetTopProperty can find it.
        # For a SmartDesign top, no HDL file matches (the root is (re)built and
        # rooted by rebuild_smartdesign.tcl instead), so no line is tagged.
        if {[GetModuleName $f] eq [string tolower $top_module]} {
            puts $fp "$rel top=$top_module"
        } else {
            puts $fp $rel
        }
        incr src_count
    }
    close $fp
    Msg Info "Created: $src_list ($src_count files)"
    if {$src_count == 0} {
        Msg CriticalWarning "No HDL files found under $src_hdl_dir - work.src is empty. Are the source\
        files present in the repo's src/hdl/$project_name/ directory?"
    }

    # work.sim: testbench/stimulus HDL under src/hdl/<project>/stimulus/.
    set sim_dir "$src_hdl_dir/stimulus"
    if {[file isdirectory $sim_dir]} {
        set sim_files [lsort -nocase [FindHdlFiles $sim_dir]]
        if {[llength $sim_files] > 0} {
            set sim_list "$list_dir/work.sim"
            set fp [open $sim_list w]
            foreach f $sim_files {
                puts $fp [MakeRelative $repo_path $f]
            }
            close $fp
            Msg Info "Created: $sim_list ([llength $sim_files] files)"
        }
    }

    # main_constraints.con: every .sdc/.pdc under src/constraints/<project>/,
    # recursively across all subdirectories (io/, fp/, ...). Non-constraint
    # helpers (.def/.tcl) are filtered out by extension.
    if {[file isdirectory $src_con_dir]} {
        set con_files [lsort -nocase [FindFilesByExt $src_con_dir {.sdc .pdc}]]
        if {[llength $con_files] > 0} {
            set con_list "$list_dir/main_constraints.con"
            set fp [open $con_list w]
            foreach f $con_files {
                puts $fp [MakeRelative $repo_path $f]
            }
            close $fp
            Msg Info "Created: $con_list ([llength $con_files] files)"
        }
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
            # 2.0.307, confirmed by repeated direct testing to have no cached
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
                        # Libero's own user vault is where download_core
                        # deposits cores and the first place
                        # create_and_configure_core looks: a core present
                        # there is fully usable (descriptor + generator)
                        # regardless of what this project's component/ tree
                        # carries, so it always counts as complete. The
                        # The entry must actually carry its payload though -
                        # download_core is known to leave partial entries
                        # behind: either completely hollow directories
                        # (Actel:SgCore:PF_INIT_MONITOR:2.0.307) or ones
                        # with the descriptor unpacked under fs/p0f0 but
                        # none of the generator/RTL filesets it references
                        # (Actel:SystemBuilder:PF_SRAM_AHBL_AXI:1.2.111) -
                        # and create_and_configure_core rejects both with
                        # "Cannot find Spirit core configuration file".
                        # Complete entries always have at least one payload
                        # fileset directory under fs/ next to the p0f0
                        # descriptor one.
                        if {[info exists ::env(HOME)]} {
                            set vault_src [file join $::env(HOME) .actel vault Components \
                                $cac_vendor $cac_lib $cac_corename $cac_ver]
                            if {[file exists [file join $vault_src pkg core_xml.zip]] &&
                                [llength [glob -nocomplain -directory [file join $vault_src fs] *]] >= 2} {
                                set catalog_complete 1
                                set vault_hit 1
                            }
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
                            create_and_configure_core; the core is fetched via download_core at CREATE"
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
                    regsub -all "(-file|-hdl_file)(\\s+)\\${ob}hdl/(\[^${cb}\]+)\\${cb}" $sd_content \
                        {\1\2"$::HOG_SD_HDL_DIR/\3"} sd_content
                    regsub -all "(-file|-hdl_file)(\\s+)\\${ob}hdl\\\\(\[^${cb}\]+)\\${cb}" $sd_content \
                        {\1\2"$::HOG_SD_HDL_DIR/\3"} sd_content
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
                set primary_library [lindex [dict keys $src_files_by_lib] 0]
                if {$primary_library eq ""} {
                    set primary_library "work"
                }
                set fp [open "$list_dir/${primary_library}.src" a]
                foreach hf $generated_hdl_files {
                    puts $fp $hf
                }
                close $fp
                Msg Info "Added [llength $generated_hdl_files] generated-core HDL file(s) to ${primary_library}.src"
            }

            # IP-core caching is intentionally disabled: cores are fetched at
            # CREATE time by download_core (see the rebuild script emitted
            # below) instead of being restored from a committed ip_cache/ copy.
            # This keeps the repo free of the multi-MB vendor vault and follows
            # Hog's documented Libero flow (download_core followed by
            # create_and_configure_core). It requires the Libero IP catalog to
            # be reachable at CREATE time.
            # https://hog.readthedocs.io/en/latest/02-User-Manual/01-Hog-local/13-Libero.html
            Msg Info "IP-core caching disabled - [llength $core_vlnvs] core(s) will be fetched via download_core at CREATE"

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
            # SmartDesign DRC severities: with cores rebuilt as static HDL
            # wrappers (whose interfaces expose no memory-map ranges)
            # generate_component's memory-map DRC reports empty target ranges
            # as hard errors, and these DRCs are shipped downgraded to
            # warnings. The values are NOT read from the .prjx - they live in
            # hog.conf's [smartdesign] section (written by PACK, git-tracked)
            # and are read here at CREATE time from $globalSettings::PROPERTIES.
            # They must be applied before generate_component runs, which is why
            # this rebuild script - sourced before ConfigureProperties - does it,
            # rather than hog.conf's [project] section: ConfigureProperties runs
            # too late AND would try to feed these smartdesign-only options to
            # project_settings, which rejects them.
            puts $fp "# SmartDesign DRC severities, read from hog.conf's \[smartdesign\] section."
            puts $fp "# One single smartdesign call on purpose: every invocation resets the"
            puts $fp "# options it wasn't given back to their defaults, so separate calls would"
            puts $fp "# leave only the last one actually applied."
            puts $fp {if {[info exists ::globalSettings::PROPERTIES] && [dict exists $::globalSettings::PROPERTIES smartdesign]} {
    set _hog_sd_args [list]
    dict for {_k _v} [dict get $::globalSettings::PROPERTIES smartdesign] {
        lappend _hog_sd_args "-$_k" [string toupper $_v]
    }
    if {[llength $_hog_sd_args] > 0} {
        smartdesign {*}$_hog_sd_args
    }
}}
            puts $fp ""
            if {[llength $core_vlnvs] > 0} {
                puts $fp "# Make sure every IP core this design's components reference is"
                puts $fp "# present in this (freshly created, empty) project before anything"
                puts $fp "# tries to use it: create_and_configure_core only ever uses what's"
                puts $fp "# already in the local catalog/vault and fails with \"Cannot find"
                puts $fp "# Spirit core configuration file...\" for anything missing. Each core"
                puts $fp "# is fetched from Libero's IP catalog with download_core, per Hog's"
                puts $fp "# documented Libero flow, instead of being restored from a committed"
                puts $fp "# ip_cache/ copy. This requires the Libero IP catalog to be reachable"
                puts $fp "# at CREATE time."
                puts $fp "# https://hog.readthedocs.io/en/latest/02-User-Manual/01-Hog-local/13-Libero.html"
                foreach vlnv $core_vlnvs {
                    puts $fp "download_core -vlnv {$vlnv}"
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
        Msg Warning "Could not detect Libero version from libero_setup_info.txt, defaulting to 2026.1"
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
    # SmartDesign DRC severities live here (git-tracked, explicit) instead of
    # being read from the untrusted .prjx. They are consumed at CREATE time by
    # smartdesign/rebuild_smartdesign.tcl (which reads this section from
    # $globalSettings::PROPERTIES) before the design is generated - not by
    # ConfigureProperties, which handles [project]/[synth]/[impl] and would
    # reject these smartdesign-only options. Values must be literal TRUE/FALSE.
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

    # (Source files were already copied into src/ and scanned near the top of
    # this proc - src/ is the truth the list files point at.)

    Msg Status "=== Conversion Complete ==="
    Msg Status "Hog project created in: $top_dir"
    Msg Status "Source files under:"
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
