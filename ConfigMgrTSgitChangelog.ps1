<#
.SYNOPSIS
    Creates a backup and logs changes to Configration Manager Task Sequences using git. Creates a git repository at the specified location.
.DESCRIPTION
    Creates a backup and logs changes to Configration Manager Task Sequences using git. This script will do the following
    1. Initialize a git repository at the specified location (either local, mapped drive, or UNC path)
    2. Create a local clone of the repository at the specified location
    3. Save the XML definition of the selected ConfigMgr Task Sequence
    4. Export the selected ConfigMgr Task Sequence to the "Exports" directory
    5. Adds any untracked files to git
    6. commits all changes
    7. pushes changes to the master branch
.EXAMPLE
    PS C:\> ConfigMgrTSgitChangelog.ps1
    Backs up the Task Sequence using the defaults specified under the User Defined Variables
    PS C:\> ConfigMgrTSgitChangelog.ps1 -CommitMessage "Changed the Operating System Deployed to Windows 10 1909"
    Backs up the Task Sequence using the defaults, and adds the message: "Changed the Operating System Deployed to Windows 10 1909" to the Commit
.INPUTS
    CommitMessage - String - Custom Message to add to the Commit
.OUTPUTS
    This script outputs an XML file of the selected task sequence as well as an exported task sequence.
.NOTES
    Created by Andrew Jimenez (@AndrewJimenez_) on 2019/12
    This script requires git to be installed and setup before running.
    This script requires the Configuration Manager Console to be installed before running.
    This script was tested on ConfigMgr 1906
#>

[CmdletBinding()]
param (
    [Parameter()]
    [String]
    $CommitMessage = ""
)

<# USER DEFINED VARIABLES #>
# Name of the Repository
$RepoName = "ConfigMgrTSChangelog"

# Path to the Root of the Remote Repositiory (This is your backup, where changes are pushed)
$RemoteRepoRoot = "\\Path\To\Remote\Repository"

# Path to the Root of the Local Repository (where changes are made)
$LocalRepoRoot = "$env:USERPROFILE\Documents\git"

# SCCM Site Code (I'll assume it is the same as the device the script is running on by default)
$CMSite = "$((New-Object -ComObject "Microsoft.SMS.Client").GetAssignedSite()):"

# For Automation, a Task Sequence Name can be specified, otherwise the script will prompt for a TS
$TSName = ""

# Set a default Commit Header, the commit header is on every commit 
$CommitHeader = "Task Sequence Changes Made on $(Get-Date)"
<#END OF USER DEFINED VARIABLES#>

$LocalRepoLocation = "$LocalRepoRoot\$RepoName"
$RemoteRepoLocation = "$RemoteRepoRoot\$RepoName.git"
$BackupsFolder = "$LocalRepoLocation\Exports"

Import-Module (Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

if (-not (Test-Path $RemoteRepoLocation -ErrorAction SilentlyContinue)) {
    Write-Output "Repo has not yet been initialized"

    Write-Output "Creating Repo Folder"
    try {
        New-Item -ItemType Directory -Path $RemoteRepoLocation -ErrorAction Stop
    }
    catch {
        Write-Output "ERROR: Unable to create new Repo Location"
        Exit 1
    }
    
    Write-Output "Initializing Repo"
    try {
        & git init --bare "$RemoteRepoLocation"
    }
    catch {
        Write-Output "ERROR: Unable to initialize Repo: $RemoteRepoLocation"
        Exit 1
    }
} 

if (-not (Test-path $LocalRepoLocation -EA SilentlyContinue)) {
    Write-Output "Cloning Blank Repo to $LocalRepoRoot"
    If (-not (Test-Path $LocalRepoRoot -EA SilentlyContinue)) {
        New-Item -ItemType Directory -Path $LocalRepoRoot -Force
    }
    try {
        & git clone "$RemoteRepoLocation" "$LocalRepoLocation"
    }
    catch {
        Write-Output "ERROR: Unable to clone Repo locally"
        Exit 1
    }
}

if ((Test-Path $RemoteRepoLocation -ErrorAction SilentlyContinue) -and (Test-Path $LocalRepoLocation -ErrorAction SilentlyContinue)) {
    Write-Output "Repository for $RepoName exists. Saving Task Sequence XML,and backing up Task Sequence"

    Push-Location
    Set-Location $CMSite
    if ([system.string]::IsNullOrEmpty($TSName)) {
        $TSName = (Get-CMTaskSequence -Name * | Select-Object Name, PackageID, Description, LastRefreshTime | Out-GridView -Title "Please Select a Task Sequence to save to git" -OutputMode Single).Name
    }

    Write-Output "Saving Task Sequence XML"
    $XMLSaveLocation = Join-Path "$LocalRepoLocation" "$TSName.xml"
    $taskSequenceXML = [xml]((Get-CMTaskSequence -Name $TSName).Sequence)
    Pop-Location

    if (Test-path $XMLSaveLocation -ErrorAction SilentlyContinue) {
        $prevTaskSequenceXML = [xml](Get-Content $XMLSaveLocation)
    }

    if ($prevTaskSequenceXML -ne $taskSequenceXML) {
        Write-Output "Changes have been made to the Task Sequence, Saving new XML"
        $taskSequenceXML.Save($XMLSaveLocation)

        if (-not (Test-Path $BackupsFolder -EA SilentlyContinue)) {
            New-Item -ItemType Directory -Path $BackupsFolder -Force
        }
        $backupPath = "$BackupsFolder\$TSName - $(Get-Date -f filedatetime).zip"
        Write-Output "Backing Up $TSName to $BackupPath"
        Push-Location
        Set-location $CMSite
        Export-CMTaskSequence -Name $TSName -ExportFilePath $BackupPath -Force
        Pop-Location
    }
    Else {
        Write-Output "No changes have been made to the Task Sequence, not exporting the TS or updating the XML"
    }
    
    ## Add Files, and Commit
    Push-Location
    Set-location $LocalRepoLocation
    $gitStatus = git status -u -s
    $unstagedFiles = ($gitStatus.split('??') | Where-Object { (-not ([System.String]::IsNullOrEmpty($_))) }).trim()
    Write-Output "Adding untracked files to git"
    if (-not ([system.string]::IsNullOrEmpty($unstagedFiles))) {
        foreach ($File in $unstagedFiles) {
            Write-Output "Adding file: `"$File`""
            & git add $File
        }
    }

    Write-Output "Committing changes"
    $CommitMessageFinal = $CommitHeader
    if (-not [System.String]::IsNullOrEmpty($CommitMessage)){
        $CommitMessageFinal = "$CommitHeader`:`n`n$CommitMessage"
    }
    & git commit -a -m $CommitMessageFinal

    Write-Output "Pushing Changes"
    & git push origin

    Write-Output "Completed!"
}