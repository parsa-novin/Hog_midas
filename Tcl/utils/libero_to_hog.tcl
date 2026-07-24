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
# Extract files from a Libero project and create Hog list files
#
# Usage: tclsh libero_to_hog.tcl <path_to_project.prjx> [project_name]

# Parse command line arguments
if {$argc < 1} {
    puts "Usage: tclsh libero_to_hog.tcl <path_to_project.prjx> \[project_name\]"
    puts "  path_to_project.prjx : Full path to the Libero .prjx file"
    puts "  project_name         : Optional name for the Hog project (defaults to prjx filename)"
    exit 1
}

set prjx_file [lindex $argv 0]
set prjx_file [file normalize $prjx_file]

if {![file exists $prjx_file]} {
    puts "ERROR: Project file not found: $prjx_file"
    exit 1
}

# Get project name
if {$argc >= 2} {
    set project_name [lindex $argv 1]
} else {
    set project_name [file rootname [file tail $prjx_file]]
}

# Find Hog directory (assume we're in Hog/Tcl/utils/)
set hog_path [file normalize "[file dirname [info script]]/.."]
set repo_path [file normalize "$hog_path/../.."]

puts "=== Libero to Hog Converter ==="
puts "Project file: $prjx_file"
puts "Project name: $project_name"
puts "Hog path: $hog_path"
puts "Repo path: $repo_path"
puts ""

# Source Hog functions
source $hog_path/hog.tcl

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

    return [eval file join $rel_parts]
}

# Create output directory
set top_dir "$repo_path/Top/$project_name"
if {[file exists $top_dir]} {
    puts "WARNING: Directory $top_dir already exists. Files will be overwritten."
} else {
    file mkdir $top_dir
    puts "Created directory: $top_dir"
}

# Open and parse the project file
set file [open $prjx_file r]
set content [read $file]
close $file

# Parse key project parameters
set top_module ""
set device_family ""
set device_die ""
set device_package ""
set hdl_mode "VERILOG"
set project_location [file dirname $prjx_file]

# Extract project settings
foreach line [split $content "\n"] {
    if {[regexp {^KEY ActiveRoot \"([^\"]+)\"} $line -> value]} {
        # Extract top module name (before ::)
        set top_module [string range $value 0 [expr {[string first "::" $value] - 1}]]
    }
    if {[regexp {^KEY VendorTechnology_Family \"?([^\"]*)\"?} $line -> value]} {
        set device_family $value
    }
    if {[regexp {^KEY VendorTechnology_Die \"?([^\"]*)\"?} $line -> value]} {
        set device_die $value
    }
    if {[regexp {^KEY VendorTechnology_Package \"?([^\"]*)\"?} $line -> value]} {
        set device_package $value
    }
    if {[regexp {^KEY HDLTechnology \"?([^\"]*)\"?} $line -> value]} {
        set hdl_mode $value
    }
}

puts "Top Module: $top_module"
puts "Device: $device_family $device_die $device_package"
puts "HDL Mode: $hdl_mode"
puts ""

# Initialize file storage dictionaries
set src_files_by_lib [dict create]
set sim_files_by_lib [dict create]
set con_files [list]
set smartdesign_files [list]

# Parse FileManager section
set in_file_manager 0
set lines [split $content "\n"]
set i 0
set num_lines [llength $lines]

while {$i < $num_lines} {
    set line [lindex $lines $i]

    # Detect FileManager section
    if {[regexp {^LIST FileManager} $line]} {
        set in_file_manager 1
        incr i
        continue
    }

    if {[regexp {^ENDLIST} $line] && $in_file_manager} {
        set in_file_manager 0
        break
    }

    # Extract file entries
    if {$in_file_manager && [regexp {^VALUE \"([^\"]+)} $line -> value]} {
        lassign [split $value ,] file_path file_type

        # Replace <project> placeholder
        set file_path [string map [list "<project>" $project_location] $file_path]

        # Extract file properties (STATE, LIBRARY, PARENT, etc.)
        set library "work"
        set parent_file ""
        set is_readonly "FALSE"

        # Read subsequent lines for this file
        incr i
        while {$i < $num_lines} {
            set prop_line [lindex $lines $i]

            if {[regexp {^ENDFILE} $prop_line]} {
                break
            }
            if {[regexp {^LIBRARY=\"([^\"]+)} $prop_line -> lib_value]} {
                set library $lib_value
            }
            if {[regexp {^PARENT=\"([^\"]+)} $prop_line -> parent_value]} {
                if {$parent_file == ""} {
                    set parent_file $parent_value
                }
            }
            if {[regexp {^IS_READONLY=\"([^\"]+)} $prop_line -> readonly_value]} {
                set is_readonly $readonly_value
            }

            incr i
        }

        # Only process files without a parent (top-level files)
        if {$parent_file == ""} {
            # Determine file category
            if {$file_type == "hdl"} {
                # HDL source file
                if {![dict exists $src_files_by_lib $library]} {
                    dict set src_files_by_lib $library [list]
                }
                dict lappend src_files_by_lib $library [list $file_path $top_module]
                puts "  \[SRC\] \[$library\] $file_path"

            } elseif {$file_type == "tb_hdl"} {
                # Simulation HDL file
                if {![dict exists $sim_files_by_lib $library]} {
                    dict set sim_files_by_lib $library [list]
                }
                dict lappend sim_files_by_lib $library $file_path
                puts "  \[SIM\] \[$library\] $file_path"

            } elseif {$file_type == "io_pdc" || $file_type == "sdc" || $file_type == "pdc"} {
                # Constraint file
                lappend con_files $file_path
                puts "  \[CON\] $file_path"

            } elseif {$file_type == "cxf" && [string match "*component/work/*" $file_path]} {
                # SmartDesign component definition
                set tcl_file [string map {".cxf" ".tcl"} $file_path]
                if {[file exists $tcl_file]} {
                    lappend smartdesign_files $tcl_file
                    puts "  \[SD\]  $tcl_file"
                }
            }
        }
    }

    incr i
}

puts ""
puts "=== Writing Hog List Files ==="

# Write source list files (one per library)
dict for {library file_list} $src_files_by_lib {
    set list_file "$top_dir/${library}.src"
    set fp [open $list_file w]

    foreach file_entry $file_list {
        set file_path [lindex $file_entry 0]
        set top [lindex $file_entry 1]

        # Make path relative to repo
        set rel_path [MakeRelative $repo_path $file_path]

        # Check if this is the top module
        if {[file exists $file_path]} {
            set module_name [GetModuleName $file_path]
            if {$module_name == [string tolower $top] && $top != ""} {
                puts $fp "$rel_path top=$top"
            } else {
                puts $fp $rel_path
            }
        } else {
            puts $fp $rel_path
        }
    }

    close $fp
    puts "Created: $list_file ([dict size $file_list] files)"
}

# Write simulation list files (one per library)
dict for {library file_list} $sim_files_by_lib {
    set list_file "$top_dir/${library}.sim"
    set fp [open $list_file w]

    foreach file_path $file_list {
        set rel_path [MakeRelative $repo_path $file_path]
        puts $fp $rel_path
    }

    close $fp
    puts "Created: $list_file ([llength $file_list] files)"
}

# Write constraint list file
if {[llength $con_files] > 0} {
    set list_file "$top_dir/constraints.con"
    set fp [open $list_file w]

    foreach file_path $con_files {
        set rel_path [MakeRelative $repo_path $file_path]
        puts $fp $rel_path
    }

    close $fp
    puts "Created: $list_file ([llength $con_files] files)"
}

# Find and copy SmartDesign TCL files
# SmartDesign components are stored in <project>/<top_module>/components/*.tcl
set smartdesign_dir "$project_location/$top_module"
if {[file exists $smartdesign_dir]} {
    set sd_components [glob -nocomplain "$smartdesign_dir/components/*.tcl"]

    if {[llength $sd_components] > 0} {
        set sd_dir "$top_dir/smartdesign"
        file mkdir $sd_dir

        # Copy the main recursive TCL (if it exists)
        set recursive_tcl "$smartdesign_dir/${top_module}_recursive.tcl"
        if {[file exists $recursive_tcl]} {
            file copy -force $recursive_tcl "$sd_dir/${top_module}_recursive.tcl"
            puts "Copied SmartDesign: ${top_module}_recursive.tcl"
        }

        # Copy all component TCL files
        foreach tcl_file $sd_components {
            set tcl_name [file tail $tcl_file]
            set dest_file "$sd_dir/$tcl_name"
            file copy -force $tcl_file $dest_file
            puts "Copied SmartDesign component: $tcl_name"
        }

        # Create a rebuild script that will be called during Hog project creation
        set rebuild_script "$sd_dir/rebuild_smartdesign.tcl"
        set fp [open $rebuild_script w]
        puts $fp "# SmartDesign rebuild script for $project_name"
        puts $fp "# This script recreates the SmartDesign hierarchy"
        puts $fp ""
        puts $fp "# Source the main recursive script"
        if {[file exists $recursive_tcl]} {
            puts $fp "source \[file join \$script_dir ${top_module}_recursive.tcl\]"
        } else {
            puts $fp "# No recursive TCL found - source components individually"
            foreach tcl_file $sd_components {
                set tcl_name [file tail $tcl_file]
                puts $fp "source \[file join \$script_dir $tcl_name\]"
            }
        }
        puts $fp ""
        puts $fp "# Build the SmartDesign"
        puts $fp "build_design_hierarchy"
        close $fp
        puts "Created: $rebuild_script"

        # Create a README
        set readme_file "$sd_dir/README.md"
        set fp [open $readme_file w]
        puts $fp "# SmartDesign Components"
        puts $fp ""
        puts $fp "This directory contains the TCL scripts needed to rebuild the SmartDesign hierarchy."
        puts $fp ""
        puts $fp "## Files"
        if {[file exists $recursive_tcl]} {
            puts $fp "- `${top_module}_recursive.tcl` - Main recursive SmartDesign script"
        }
        puts $fp "- `rebuild_smartdesign.tcl` - Master rebuild script to be sourced during project creation"
        puts $fp "- Component TCL files ([llength $sd_components] components)"
        puts $fp ""
        puts $fp "## Integration with Hog"
        puts $fp ""
        puts $fp "To integrate SmartDesign rebuild into your Hog workflow:"
        puts $fp "1. Add a pre-synthesis hook in your Hog configuration"
        puts $fp "2. Source `rebuild_smartdesign.tcl` before synthesis"
        puts $fp "3. Alternatively, create a custom `pre-synthesis.tcl` script in your Top directory"
        close $fp
        puts "Created: $readme_file"
    } else {
        puts "Note: No SmartDesign components found in $smartdesign_dir/components/"
    }
} else {
    puts "Note: SmartDesign directory not found: $smartdesign_dir"
}

# Write hog.conf
set conf_file "$top_dir/hog.conf"
set fp [open $conf_file w]

puts $fp "\[main\]"
puts $fp "top = $top_module"
puts $fp ""
puts $fp "\[project\]"
puts $fp "family = $device_family"
puts $fp "die = $device_die"
puts $fp "package = $device_package"
puts $fp ""
puts $fp "\[synth\]"
puts $fp "# Synthesis settings"
puts $fp ""
puts $fp "\[impl\]"
puts $fp "# Implementation settings"

close $fp
puts "Created: $conf_file"

puts ""
puts "=== Conversion Complete ==="
puts "Hog project directory: $top_dir"
puts ""
puts "Next steps:"
puts "1. Review the generated list files in $top_dir"
puts "2. If SmartDesigns were found, check $top_dir/smartdesign/"
puts "3. Create a TCL script to rebuild SmartDesigns during synthesis"
puts "4. Test the project by running Hog's create_project.tcl"
puts ""
