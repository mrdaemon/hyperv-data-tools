<#
    .SYNOPSIS
        Safely Imports Hyper-V Virtual Machines that were exported
        as configuration only, without State Data (snapshots, VHDs, etc).
    
    .DESCRIPTION
        Hyper-V 2008 R2 removed the option to export a Virtual Machine without
        its State Data (Snapshots, Virtual Disk Images (VHDs), Suspend State),
        as configuration only through the GUI.
        
        The functionality is still there, only it is not exposed through the
        Hyper-V Manager snap-in in R2. Many scripts and resources exist to 
        perform such an export, namely the PowerShell management Library for 
        Hyper-V (see links). However, there are very few, if any usable tools
        that leverage the new ImportVirtualSystemEx() API to perform an import
        of such a configuration-only export. This cmdlet attempts to remedy this.
        
        It will copy the specified VM Export to a sensible location based on
        the current global setting for VM Data location in Hyper-V, and then
        assuming the VHD files are in the right place and the Virtual Networks
        still have the same friendly names, reattach everything together and
        import the virtual machine back into Hyper-V.
        
        This was written because there is no direct upgrade path between
        Hyper-V Server 2008 and Hyper-V Server 2008 R2.
        
    .PARAMETER ExportDirectory
        Specifies either a Directory or a list of directories where the
        Configuration Only exports can be found. Each directory must contain
        the 'config.xml' file in the root along with the "Virtual Machines"
        directory containing the actual configuration.
        
    .INPUTS
        You can pipe a collection of directories into Import-HVConfigOnlyVM.
        They will all be processed.
        
    .OUTPUTS
        System.Object - may be formatted as a table, contains a report of
        the operations in its property members.
    
    .NOTES
        The script must be ran locally on the Hyper-V server.
        It also will only work on Hyper-V R2 and Powershell 2.0.
        
    .EXAMPLE
        Import a config only export of a virtual machine stored at
        E:\Export\VMSVR03
        
        C:\PS> Import-HVConfigOnlyVM -ExportDirectory E:\Export\VMSVR03
            
    .EXAMPLE
        Import all the exports stored in E:\Export
        
        C:\PS> gci E:\Export | where { $_.PSIsContainer -eq $true } | Import-HVConfigOnlyVM
    
    .LINK
        https://github.com/mrdaemon/hyper-v_utils
        Script page and code repository on GitHub
        
    .LINK
        http://www.raptorized.com
        Author's Blog
    
    .LINK
        http://pshyperv.codeplex.com/
        PowerShell management Library for Hyper-V (only vaguely related)
    
#>  
function Import-HVConfigOnlyVM {
    [OutputType([System.Object])]
    [CmdletBinding(
        SupportsShouldProcess=$true,
        ConfirmImpact="Medium"
    )]
    Param
    (
        [parameter(Mandatory=$true,
                    ValueFromPipelineByPropertyName=$true,
                    HelpMessage="Enter path to exported VM directory (containing config.xml)")]
        [ValidateScript({ 
                            (Test-Path (Join-Path $_ "config.xml") -PathType Leaf) -and 
                            (Test-Path (Join-Path $_ "Virtual Machines") -PathType Container)
                       })]
        [alias("FullName", "Path")]
        [string[]]$ExportDirectory
    )
    BEGIN 
    {
        # Local settings and local-scope WMI class instances
        #####################################################
        
        # Sane default for Errors behavior.
        # You shouldn't override it anyways.        
        $ErrorActionPreference = "Stop"

        # Hyper-V WMI Namespace
        $hyperv_namespace = "root/virtualization"
        
        # VirtualSystemManagementService and 
        # VirtualSystemManagementSettingData WMI instances
        $vsms = Get-WmiObject -Namespace $hyperv_namespace -Class "MsVM_virtualSystemManagementService"
        $hyperv_config = Get-WmiObject -NameSpace $hyperv_namespace -Class "MsVM_VirtualSystemManagementServiceSettingData"
        
        # List of currently configured Virtual Networks from the
        # Hyper-V server configuration, for validation purposes.
        [String[]]$vswitches = Get-WmiObject -NameSpace $hyperv_namespace -Class "MsVM_VirtualSwitch" | 
                                        foreach( $_.ElementName.toString())
        
        # Array to hold the result set populated with our custom report objects
        [System.Object[]]$statusdataset = @()
    }
    
    PROCESS 
    {
        write-host "Importing config-only Virtual machine in", $ExportDirectory
        
        # Reporting Object, contains all the status data.
        # It is pushed into a global array and returned when the script
        # is done executing.
        $importstatus = New-Object System.Object
        
        # Construct new destination root from the default Hyper-V VM storage 
        # path, the system default name of "Virtual Machines" as a subdirectory, 
        # and the the top level directory (which should be the name of the VM).
        # TODO: make this a parameter.
        $newroot = Join-Path (Join-Path $hyperv_config.DefaultExternalDataRoot "Virtual Machines") (get-item $ExportDirectory).Name
        
        # There's no way we can continue if the data set already exists.
        if (Test-Path $newroot -PathType Container) {
            $err = "The destination path $newroot already exists!`n",
                        "Aborting..."
            throw $err
        }
        
        # Copy the export files to their final location in $newroot,
        # they will be imported in-place, since we do not enable CreateCopy.
        # Copy-Item creates target Directories if they don't already exist.
        Write-Host "Copying configuration to $newroot..."
        if($PSCmdlet.ShouldProcess) {
            Copy-Item $ExportDirectory -Destination $newroot -Container -Recurse
        }
        
        # Fetch current import settings data from files in new data root
        $importconfig = $vsms.GetVirtualSystemImportSettingData("$newroot").ImportSettingData
        
        Write-Host "Processing configuration for", $importconfig.Name

        # Populate our status object with what we have gathered so far:
        $importstatus | Add-Member
        

        # Alter importation settings to reuse current and default values.
        # This is how to specify where the data actually lives.
        # http://msdn.microsoft.com/en-us/library/dd379577(v=VS.85).aspx
        $importconfig.CreateCopy = $false
        $importconfig.GenerateNewId = $false
        $importconfig.SourceSnapshotDataRoot = $hyperv_config.DefaultVirtualHardDiskPath
        $importconfig.SourceResourcePaths = $importconfig.CurrentResourcePaths
        $importconfig.TargetNetworkConnections = $importconfig.SourceNetworkConnections
        
        # Validate (at least roughly) import settings
        foreach ($path in $importconfig.SourceResourcePaths) {
            if(Test-Path -Path $path -PathType Leaf) {
                Write-Host "Found Resource $path ."
            } else {
                Write-Warning ("Warning, missing ressource: $path!`n",
                    "You will be able to continue but you will have to reattach",
                    "the missing volumes to the virtual machines after the import." -join " ")
            }
        }
        
        
        # Perform Importation of system.
        $result = $vsms.ImportVirtualSystemEx("$newroot", $importconfig.PSBase.GetText(1))
        
        # Apparently, calling ImportVirtualSystemEx forks a process/thread asynchronously,
        # returning a CIM_ConcreteJob class instance with the job details.
        # This is translated in Powershell as a Job, but the translation is not flawless.
        if ($result.ReturnValue -eq 4096) {
            
            # Getting WMI Job object reference.
            $job = [WMI]$result.Job
            
            # Process our job status in a loop while it is in one of the following states:
            #  2 - Never Started
            #  3 - Starting
            #  4 - Running
            # http://msdn.microsoft.com/en-us/library/cc136808(v=VS.85).aspx#properties
            while ($job.JobState -eq 2 -or $job.JobState -eq 3 -or $job.JobState -eq 4) {
                # Display and update the lovely progress bar.
                Write-Progress $job.Caption -Status "Importing VM" -PercentComplete $job.PercentComplete
                
                start-sleep 1
                
                # Update the ref, it doesn't do that by itself.
                $job = [WMI]$result.Job
            }
            
            # Complete Progress bar and move on.
            Write-Progress "Importing Virtual Machine" -Status "Done." -PercentComplete 100
            
            # JobState 7 means Successfully Completed.
            # There are a billion other things that could be returned here,
            # and frankly, I don't care. Enjoy your generic error code.
            if($job.JobState -eq 7) {
                Write-Output "System in $ExportDirectory successfully imported in $newroot."
            } else {
                Write-Error "System failed to import. Error value:", $job.Errorcode, $job.ErrorDescription
            }
        } else {
            # Return code was not 4096, which is "Job Started".
            # This means no job was forked. There can be only two outcomes
            # to this entire ordeal. Let's Address them in the laziest way possible.
            $msg = "ImportVirtualSystemEx() returned prematurely with status"
            
            if($result.ReturnValue -eq 0) {
                Write-Warning $msg, "0 (Success)"
            } else {
                Write-Error $msg, $result.ReturnValue
            }
        }
    }
}
