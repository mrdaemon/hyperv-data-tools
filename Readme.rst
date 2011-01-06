Hyper-V Data Tools
===================

Hyper-V 2008 R2 removed the option to export a Virtual Machine without
its State Data (Snapshots, Virtual Disk Images (VHDs), Suspend State),
as configuration only through the GUI.
        
The functionality is still there, only it is not exposed through the
Hyper-V Manager snap-in in R2. Many scripts and resources exist to 
perform such an export, namely the PowerShell management Library for 
Hyper-V (see links). However, there are very few, if any usable tools
that leverage the new ImportVirtualSystemEx() API to perform an import
of such a configuration-only export. This cmdlet attempts to remedy this.

The cmdlets (right now, only Import-HVConfigOnlyVM) in this powershell 
module will accomplish a multitude of tasks, such as:

Copy the specified VM Export to a sensible location based on the current 
global setting for VM Data location in Hyper-V, and then assuming the 
VHD files are in the right place and the Virtual Networks still have 
the same friendly names, reattach everything together and import the 
virtual machine back into Hyper-V.

This was written because there is no direct upgrade path between
Hyper-V Server 2008 and Hyper-V Server 2008 R2, and moving 900gb VHDs
takes ages.

Import-HVConfigOnlyVM
-----------------------
Safely Imports Hyper-V Virtual Machines that were exported
as configuration only, without State Data (snapshots, VHDs, etc).


PARAMETER ExportDirectory
~~~~~~~~~~~~~~~~~~~~~~~~~~
Specifies either a Directory or a list of directories where the
Configuration Only exports can be found. Each directory must contain
the 'config.xml' file in the root along with the "Virtual Machines"
directory containing the actual configuration.
        
INPUTS
~~~~~~
You can pipe a collection of directories into Import-HVConfigOnlyVM.
They will all be processed.

OUTPUTS
~~~~~~~
System.Object - may be formatted as a table, contains a report of
the operations in its property members.

NOTES
~~~~~~
The script must be ran locally on the Hyper-V server.
It also will only work on Hyper-V R2 and Powershell 2.0.

EXAMPLES
~~~~~~~~~
Import a config only export of a virtual machine stored at
E:\Export\VMSVR03

    C:\PS> Import-HVConfigOnlyVM -ExportDirectory E:\Export\VMSVR03

Import all the exports stored in E:\Export

    C:\PS> gci E:\Export | where { $_.PSIsContainer -eq $true } | Import-HVConfigOnlyVM
    
 
