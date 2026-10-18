# Recreate official Vivado 2022.2 floating_point v7.1 configurations. No synthesis.
set root [file dirname [file dirname [file normalize [info script]]]]
set dest [file join $root build ip generated]
if {[file exists $dest]} {error "Destination exists; refusing to overwrite generated IP: $dest"}
file mkdir $dest
set_param general.maxThreads 1
create_project -in_memory -part xcu50-fsvh2104-2-e
foreach {module operation latency} {
 sfu_exp64_ip Exponential 45 sfu_sub64_ip Add_Subtract 14
 sfu_recip64_ip Reciprocal 35 sfu_gmul64_ip Multiply 12
 sfu_gadd64_ip Add_Subtract 14 sfu_gdiv64_ip Divide 57
} {
 create_ip -name floating_point -vendor xilinx.com -library ip -version 7.1 -module_name $module -dir $dest
 set config [list CONFIG.Operation_Type $operation CONFIG.A_Precision_Type Double CONFIG.Result_Precision_Type Double CONFIG.Flow_Control NonBlocking CONFIG.Has_ACLKEN true CONFIG.Has_ARESETn true CONFIG.Maximum_Latency true CONFIG.C_Rate 1]
 if {$operation eq "Exponential"} {lappend config CONFIG.C_BRAM_Usage Full_Usage}
 if {$operation eq "Add_Subtract"} {
  if {$module eq "sfu_sub64_ip"} {lappend config CONFIG.Add_Sub_Value Subtract} else {lappend config CONFIG.Add_Sub_Value Add}
 }
 if {$operation eq "Multiply" || $operation eq "Add_Subtract"} {lappend config CONFIG.C_Mult_Usage Full_Usage}
 set_property -dict $config [get_ips $module]
 generate_target all [get_ips $module]
 if {[get_property CONFIG.C_Latency [get_ips $module]] != $latency} {error "Unexpected latency for $module; RTL alignment must be revalidated"}
 set f [open [file join $dest ${module}_properties.txt] w]
 foreach p {CONFIG.Operation_Type CONFIG.A_Precision_Type CONFIG.Result_Precision_Type CONFIG.C_Latency CONFIG.C_Rate} {puts $f "$p=[get_property $p [get_ips $module]]"}
 close $f
}
puts SFU_IP_CONFIGURATION_READY
exit 0
