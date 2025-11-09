# ------------------------------------------------------------------------------------
# Script: Filter-Timeline-Sessions.ps1
# Description: Filters a timeline CSV based on Logon IDs to extract complete user sessions.
#              Session bounds are strictly defined by Logon (4624/4672) and Logoff (4634) events,
#              with a fallback to the absolute first event if a Logon event is missing.
#
# IMPROVEMENTS:
# 1. ROBUST CSV PARSING: Now uses Import-Csv to correctly handle quoted fields and embedded commas.
# 2. Dynamic Property Mapping: Maps field names to object properties, resilient to header variations.
# 3. FIELD INCLUSION: SubjectUserName is now mapped and used as a critical fallback for naming the session file.
# 4. USERNAME CLEANING: Added a check to skip usernames that are a hyphen ('-').
# 5. FILTER RESTRICTION: Logic uses TargetLogonId OR SubjectLogonId OR LegacyLogonId to capture all intermediate activity.
# 6. SKIPPED SESSION LOGGING: Tracks session files that are skipped due to lack of intermediate activity and exports the list to 'ignored-sessions.txt' with a reason.
# 7. FILENAME LOGON TYPE FIX: Replaces missing LogonType with 'missing' in the output filename to prevent illegal character error.
# 8. OUTPUT CLEANING: Clears the contents of the 'sessions' folder before generating new files.
# 9. FALLBACK LOGON TYPE: Searches all session events for the first non-empty LogonType if the starting event is missing this value.
# 10. IGNORED SESSION SORT: Sorts the contents of ignored-sessions.txt alphabetically.
# 11. DYNAMIC LOGON ID EXTRACTION: The script now automatically extracts all unique Logon IDs from the Target/Subject/Legacy ID columns in the timeline CSV, removing the need for a separate input file.
# 12. FIX: Replaced .ToArray() with @() casting to prevent 'MethodNotFound' error when converting the HashSet to an array.
# 13. FIX: Changed bare words 'true' and 'false' to PowerShell variables '$true' and '$false' to avoid 'CommandNotFoundException'.
# 14. UPDATE: Sessions with no intermediate activity are now exported to an 'ignored' subdirectory, instead of being discarded. A summary file is also created in this subdirectory.
# ------------------------------------------------------------------------------------
param (
    [Parameter(Mandatory=$true)]
    [string]$TimelineCsv
)

# --- CONFIGURATION ---
$OutputDirectory = ".\output\sessions"
$IgnoredDirectory = Join-Path -Path $OutputDirectory -ChildPath "ignored"
$Delimiter = "," # Assuming the input CSV uses a comma delimiter
$IgnoredSessions = @() # Array to hold names of files that were skipped for the summary file

# --- PREP: Initialization and Robust CSV Loading/Mapping ---

if (-not (Test-Path $TimelineCsv)) {
    Write-Error "Timeline file not found: $TimelineCsv"
    exit 1
}

# Ensure the output directory exists and clear its contents if it does
if (Test-Path $OutputDirectory -PathType Container) {
    Write-Host "Clearing existing output directory contents: $OutputDirectory"
    # Remove all items inside the main directory, excluding the 'ignored' folder for now
    Get-ChildItem -Path $OutputDirectory -Exclude "ignored" -Force | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}
if (-not (Test-Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory | Out-Null
    Write-Host "Created output directory: $OutputDirectory"
}

# Ensure the IGNORED subdirectory exists and clear its contents
if (Test-Path $IgnoredDirectory -PathType Container) {
    Write-Host "Clearing existing contents of ignored directory: $IgnoredDirectory"
    Remove-Item -Path (Join-Path -Path $IgnoredDirectory -ChildPath "*") -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $IgnoredDirectory)) {
    New-Item -Path $IgnoredDirectory -ItemType Directory | Out-Null
    Write-Host "Created ignored subdirectory: $IgnoredDirectory"
}

# 1. LOAD DATA ROBUSTLY using Import-Csv
Write-Host "Loading data using Import-Csv for robust parsing..."
try {
    # Import-Csv handles quoted fields, embedded commas, and complex line endings.
    $DataRecords = Import-Csv -Path $TimelineCsv -Delimiter $Delimiter -Encoding UTF8
}
catch {
    Write-Error "Failed to import CSV file. Check the delimiter, file path, or encoding: $($_.Exception.Message)"
    exit 1
}

if (-not $DataRecords) {
    Write-Host "Timeline CSV contains no data records. Exiting."
    exit 0
}

# 2. DYNAMIC PROPERTY MAPPING (checking for common field names)
if (-not $DataRecords[0]) {
    Write-Error "Timeline CSV appears to be empty or missing headers after processing."
    exit 1
}

$SampleRecord = $DataRecords[0]
$AvailableProperties = $SampleRecord.PSObject.Properties.Name

# --- Define Field Definitions (Mandatory or Optional) ---
# Key = variable name; Alternatives = array of possible field names; Mandatory = boolean
$FieldDefinitions = @(
    @{ Key='EpochTimeProp'; Alternatives=@('EpochTime'); Mandatory=$true },
    @{ Key='EventCodeProp'; Alternatives=@('EventCode', 'EventID'); Mandatory=$true },
    @{ Key='TimestampProp'; Alternatives=@('Timestamp', 'TimeGenerated', 'datetime', 'TimeCreated'); Mandatory=$true },
    @{ Key='TargetUserNameProp'; Alternatives=@('TargetUserName', 'UserName'); Mandatory=$true },
    @{ Key='LogonTypeProp'; Alternatives=@('LogonType'); Mandatory=$true },
    @{ Key='TargetLogonIdProp'; Alternatives=@('TargetLogonId', 'TargetId'); Mandatory=$true },
    @{ Key='SubjectLogonIdProp'; Alternatives=@('SubjectLogonId', 'SubjectId'); Mandatory=$true },
    @{ Key='SubjectUserNameProp'; Alternatives=@('SubjectUserName', 'SubjectUser'); Mandatory=$false },
    @{ Key='LegacyLogonIdProp'; Alternatives=@('LogonId'); Mandatory=$false }
)

# Check all required fields and assign dynamic property names
foreach ($Definition in $FieldDefinitions) {
    $Key = $Definition.Key
    $Mandatory = $Definition.Mandatory
    $Alternatives = $Definition.Alternatives
    $FoundField = $false
    
    foreach ($Alternative in $Alternatives) {
        if ($AvailableProperties -contains $Alternative) {
            # Dynamically assign the property name variable (e.g., $EventCodeProp = 'EventID')
            Set-Variable -Name $Key -Value $Alternative
            $FoundField = $true
            break
        }
    }
    
    if (-not $FoundField) {
        if ($Mandatory) {
            Write-Error "Timeline CSV is missing the required field '$($Key -replace 'Prop$', '')'. Looked for alternatives: $($Alternatives -join ', ')"
            exit 1
        } else {
            # Optional field is missing: Print warning and set variable to $null
            Write-Warning "Optional field '$($Key -replace 'Prop$', '')' not found. Events matching this field will be ignored for session matching."
            Set-Variable -Name $Key -Value $null
        }
    }
}

# Retrieve the mapped property names for easy access
$EpochTimeProp = Get-Variable -Name EpochTimeProp -Value
$EventCodeProp = Get-Variable -Name EventCodeProp -Value
$TimestampProp = Get-Variable -Name TimestampProp -Value
$TargetUserNameProp = Get-Variable -Name TargetUserNameProp -Value
$LogonTypeProp = Get-Variable -Name LogonTypeProp -Value
$TargetLogonIdProp = Get-Variable -Name TargetLogonIdProp -Value
$SubjectLogonIdProp = Get-Variable -Name SubjectLogonIdProp -Value
$LegacyLogonIdProp = Get-Variable -Name LegacyLogonIdProp -Value # Will be $null if not found
$SubjectUserNameProp = Get-Variable -Name SubjectUserNameProp -Value # Will be $null if not found


# 3. DYNAMICALLY EXTRACT ALL UNIQUE LOGON IDS FROM THE DATA
Write-Host "Extracting all unique Logon IDs from TargetLogonId, SubjectLogonId, and LegacyLogonId columns..."
$LogonIdsSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($Record in $DataRecords) {
    
    $TargetId = $Record.$TargetLogonIdProp.Trim()
    if (-not [string]::IsNullOrEmpty($TargetId) -and $TargetId -ne '-') {
        [void]$LogonIdsSet.Add($TargetId)
    }

    $SubjectId = $Record.$SubjectLogonIdProp.Trim()
    if (-not [string]::IsNullOrEmpty($SubjectId) -and $SubjectId -ne '-') {
        [void]$LogonIdsSet.Add($SubjectId)
    }

    if ($LegacyLogonIdProp) {
        $LegacyId = $Record.$LegacyLogonIdProp.Trim()
        if (-not [string]::IsNullOrEmpty($LegacyId) -and $LegacyId -ne '-') {
            [void]$LogonIdsSet.Add($LegacyId)
        }
    }
}

# FIX: Use the unary array operator @() to safely cast the HashSet contents into a PowerShell array.
$LogonIds = @($LogonIdsSet)

if (-not $LogonIds) {
    Write-Host "No valid Logon IDs found in the timeline data. Exiting."
    exit 0
}

Write-Host "Processing $($LogonIds.Count) unique Logon IDs extracted from the timeline data."

# --- MAIN LOGIC LOOP ---

foreach ($LogonId in $LogonIds) {
    Write-Host "--- Processing Logon ID: $LogonId ---"

    # Reset tracking variables for this Logon ID
    $FirstLogonEpoch = [long]::MaxValue
    $AbsoluteMinEpoch = [long]::MaxValue
    $LastEpoch = [long]::MinValue
    $TargetUserName = $null
    $StartingLogonType = $null
    $StartingTimestamp = $null
    $FoundStartEvent = $false
    $FoundEndEvent = $false
    $NoLogonStartFound = $false
    $HasIntermediateActivity = $false

    # 1. Find the definitive session start and end
    
    foreach ($Record in $DataRecords) {
        
        # Access mandatory fields
        $TargetId = $Record.$TargetLogonIdProp.Trim()
        $SubjectId = $Record.$SubjectLogonIdProp.Trim()
        
        # Safe access for optional LegacyLogonId
        $LegacyId = ""
        if ($LegacyLogonIdProp) {
            $LegacyId = $Record.$LegacyLogonIdProp.Trim()
        }
        
        # Check if the event is associated with the session ID (Target, Subject, or Legacy match)
        $IsMatchingLogonId = ($TargetId -eq $LogonId) -or ($SubjectId -eq $LogonId) -or ($LegacyId -eq $LogonId)
        
        if ($IsMatchingLogonId) {
            
            try {
                # Import-Csv fields are strings, so we still need to parse to long
                $CurrentEpoch = [long]::Parse($Record.$EpochTimeProp)
            }
            catch {
                # If EpochTime is corrupted for this record, skip it but continue the loop
                continue
            }

            $CurrentEventCode = $Record.$EventCodeProp.Trim()
            
            # Track the absolute minimum epoch for fallback (IGNORING 4634)
            if (($CurrentEpoch -lt $AbsoluteMinEpoch) -and ($CurrentEventCode -ne '4634')) {
                $AbsoluteMinEpoch = $CurrentEpoch
                # Capture user details from this earliest event
                $TargetUserName = $Record.$TargetUserNameProp.Trim()
                # Capture the LogonType from this earliest event (used as the primary fallback)
                $StartingLogonType = $Record.$LogonTypeProp.Trim()
                $StartingTimestamp = $Record.$TimestampProp.Trim() 
            }

            # --- START EVENT CRITERIA (Minimum Epoch Time - STRICT LOGON: 4624/4672) ---
            if ($CurrentEventCode -in @('4624', '4672')) {
                
                if ($CurrentEpoch -lt $FirstLogonEpoch) {
                    $FoundStartEvent = $true
                    $FirstLogonEpoch = $CurrentEpoch
                    
                    # Capture details from the earliest STRICT logon event
                    $TargetUserName = $Record.$TargetUserNameProp.Trim()
                    $StartingLogonType = $Record.$LogonTypeProp.Trim()
                    $StartingTimestamp = $Record.$TimestampProp.Trim() 
                }
            }
            
            # --- END EVENT CRITERIA (Maximum Epoch Time - LOGOFF: 4634) ---
            if ($CurrentEventCode -eq '4634') {
                if ($CurrentEpoch -gt $LastEpoch) {
                    $FoundEndEvent = $true
                    $LastEpoch = $CurrentEpoch
                }
            }
        }
    }

    # --- SET START BOUNDARY ---
    if ($FoundStartEvent) {
        $FirstEpoch = $FirstLogonEpoch
    } 
    elseif ($AbsoluteMinEpoch -ne [long]::MaxValue) {
        $FirstEpoch = $AbsoluteMinEpoch
        $NoLogonStartFound = $true
        Write-Host "Logon ID ${LogonId}: No 4624/4672 start event found. Using first recorded NON-LOGOFF event ($FirstEpoch) as start (appending -nologon)."
    }
    else {
        Write-Host "Logon ID ${LogonId}: No Logon or meaningful events found. Skipping."
        continue
    }
    
    # --- SET END BOUNDARY ---
    if (-not $FoundEndEvent) {
        Write-Host "Logon ID ${LogonId}: No 4634 logoff event found to set end bound. Searching for the absolute last event."
        
        $LastEpoch = [long]::MinValue
        foreach ($Record in $DataRecords) {
            
            $TargetId = $Record.$TargetLogonIdProp.Trim()
            $SubjectId = $Record.$SubjectLogonIdProp.Trim()
            
            $LegacyId = ""
            if ($LegacyLogonIdProp) {
                $LegacyId = $Record.$LegacyLogonIdProp.Trim()
            }
            
            $IsMatchingLogonId = ($TargetId -eq $LogonId) -or ($SubjectId -eq $LogonId) -or ($LegacyId -eq $LogonId)
            
            if ($IsMatchingLogonId) {
                try {
                    $CurrentEpoch = [long]::Parse($Record.$EpochTimeProp)
                    if ($CurrentEpoch -gt $LastEpoch) {
                        $LastEpoch = $CurrentEpoch
                    }
                }
                catch {
                    # Ignore lines that can't be parsed here
                }
            }
        }
    }
    
    if ($FirstEpoch -gt $LastEpoch) {
        Write-Host "Logon ID ${LogonId}: Start Epoch ($FirstEpoch) is later than End Epoch ($LastEpoch). Adjusting end to start time."
        $LastEpoch = $FirstEpoch
    }
    
    # --- Calculate and Format Duration ---
    $DurationSeconds = $LastEpoch - $FirstEpoch
    $TimeSpan = New-TimeSpan -Seconds $DurationSeconds
    $DurationDisplay = $TimeSpan.ToString("hh\:mm\:ss") 
    Write-Host "Session Duration: $DurationDisplay ($DurationSeconds seconds)"
    $DurationFileSafe = $DurationDisplay -replace ":", "_"

    $CleanTimestamp = ($StartingTimestamp -replace '[^a-zA-Z0-9]', '_').Trim('_')
    if ($CleanTimestamp.Length -gt 50) { $CleanTimestamp = $CleanTimestamp.Substring(0, 50) }

    $MinDate = [datetimeoffset]::FromUnixTimeSeconds($FirstEpoch).ToLocalTime()
    $MaxDate = [datetimeoffset]::FromUnixTimeSeconds($LastEpoch).ToLocalTime()
    Write-Host "Session Range: [$($MinDate)] to [$($MaxDate)]"
    
    # 2. Extract and Filter Events
    
    $SessionRecords = @()
    $EventCount = 0

    foreach ($Record in $DataRecords) {
        
        try {
            $CurrentEpoch = [long]::Parse($Record.$EpochTimeProp)
        }
        catch {
            # Skip line if EpochTime parsing fails
            continue
        }
        
        $TargetId = $Record.$TargetLogonIdProp.Trim()
        $SubjectId = $Record.$SubjectLogonIdProp.Trim()
        
        $LegacyId = ""
        if ($LegacyLogonIdProp) {
            $LegacyId = $Record.$LegacyLogonIdProp.Trim()
        }
        
        # Check if the event is associated with the session ID (Target, Subject, or Legacy match)
        $IsMatchingLogonId = ($TargetId -eq $LogonId) -or ($SubjectId -eq $LogonId) -or ($LegacyId -eq $LogonId)
        
        if (($CurrentEpoch -ge $FirstEpoch) -and 
            ($CurrentEpoch -le $LastEpoch) -and 
            ($IsMatchingLogonId)) 
        {
            $SessionRecords += $Record
            $EventCount++
            
            # Check for intermediate activity (any event NOT in the ignore list)
            $CurrentEventCode = $Record.$EventCodeProp.Trim()
            
            # IGNORE LIST: 4634 (Logoff), 4624 (Logon), 4672 (Admin Logon), 4627 (Group Membership)
            if ($CurrentEventCode -notin @('4634', '4624', '4672', '4627')) {
                $HasIntermediateActivity = $true
            }
        }
    }

    # 3. Prepare File Name and Fallback Check
    
    # FALLBACK: If TargetUserName wasn't captured or is empty (e.g., first event was not a logon)
    if ([string]::IsNullOrEmpty($TargetUserName) -or $TargetUserName -eq '-') {
        Write-Host "Logon ID ${LogonId}: TargetUserName not captured/valid from boundary events. Searching intermediate records for a valid username..."
        
        # If the primary variable is still invalid, loop through session records for a name
        if ([string]::IsNullOrEmpty($TargetUserName) -or $TargetUserName -eq '-') {
            foreach ($Record in $SessionRecords) {
                $TargetNameCheck = $Record.$TargetUserNameProp.Trim()
                $SubjectNameCheck = if ($SubjectUserNameProp) { $Record.$SubjectUserNameProp.Trim() } else { "" }
                
                # Check 1: TargetUserName (must not be empty, null, or a hyphen)
                if (-not [string]::IsNullOrEmpty($TargetNameCheck) -and $TargetNameCheck -ne '-') {
                    $TargetUserName = $TargetNameCheck
                    Write-Host "Found TargetUserName fallback: $TargetUserName"
                    break
                } 
                # Check 2: SubjectUserName (must not be empty, null, or a hyphen)
                elseif (-not [string]::IsNullOrEmpty($SubjectNameCheck) -and $SubjectNameCheck -ne '-') {
                    # Use SubjectUserName as a secondary fallback for naming the session
                    $TargetUserName = $SubjectNameCheck
                    Write-Host "Found SubjectUserName fallback: $TargetUserName"
                    break
                }
            }
        }

        # If still null, use the Logon ID as the username for the filename
        if ([string]::IsNullOrEmpty($TargetUserName) -or $TargetUserName -eq '-') {
            $TargetUserName = "UNKNOWN_USER_$LogonId"
            Write-Host "Could not find any user name. Using placeholder: $TargetUserName"
        }
    }

    # FALLBACK LOGIC (9): Check session records for a valid LogonType if the starting one is missing
    if ([string]::IsNullOrEmpty($StartingLogonType)) {
        Write-Host "Logon ID ${LogonId}: Starting LogonType is missing. Searching intermediate records for the first valid LogonType..."
        foreach ($Record in $SessionRecords) {
            $LogonTypeCheck = $Record.$LogonTypeProp.Trim()
            if (-not [string]::IsNullOrEmpty($LogonTypeCheck)) {
                $StartingLogonType = $LogonTypeCheck
                Write-Host "Found LogonType fallback: $StartingLogonType"
                break
            }
        }
    }
    
    # Filename construction with LogonType check
    # FIXED: Replaced '?' with 'missing' as '?' is an illegal character in Windows file paths.
    $LogonTypeDisplay = if ([string]::IsNullOrEmpty($StartingLogonType)) { 'missing' } else { $StartingLogonType }
    $CleanUserName = $TargetUserName -replace '[^a-zA-Z0-9_-]', '_'
    $OutputFileName = "$($CleanUserName)-$LogonId-$LogonTypeDisplay"
    
    if ($NoLogonStartFound) { $OutputFileName += "-nologon" }
    
    if (-not [string]::IsNullOrEmpty($CleanTimestamp)) { $OutputFileName += "-$CleanTimestamp" }

    $OutputFileName += "-Duration-$DurationFileSafe"
    
    $OutputFileName += ".csv"
    
    # 4. Determine Target Directory and Export
    
    $TargetDirectory = $OutputDirectory
    $SkipReason = $null
    
    if (-not $HasIntermediateActivity) {
        $SkipReason = "No Intermediate Activity (Only Logon/Logoff/Admin events)"
        $TargetDirectory = $IgnoredDirectory
        
        Write-Host "Session is ignored: $SkipReason. Exporting to '$IgnoredDirectory' subdirectory."
        $IgnoredSessions += "$OutputFileName | Reason: $SkipReason"
        
        # Add a prefix to the filename in the ignored directory for easy identification
        $OutputFileName = "IGNORED_$OutputFileName"
    }

    $OutputPath = Join-Path -Path $TargetDirectory -ChildPath $OutputFileName
    
    # Export the objects. PowerShell's Export-Csv handles formatting, quotes, and line endings correctly.
    $SessionRecords | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    
    Write-Host "Exported $EventCount events to: $OutputPath"
}

# --- FINAL EXPORT OF SKIPPED SESSIONS SUMMARY ---
if ($IgnoredSessions.Count -gt 0) {
    # The summary file is now placed inside the 'ignored' subdirectory
    $IgnoredFilePath = Join-Path -Path $IgnoredDirectory -ChildPath "summary-of-skipped-sessions.txt"
    # Sort the array alphabetically before outputting
    $IgnoredSessions | Sort-Object | Out-File -FilePath $IgnoredFilePath -Encoding UTF8
    Write-Host "Exported $($IgnoredSessions.Count) skipped session file names to: $IgnoredFilePath"
}

Write-Host "Processing complete. Check the '$OutputDirectory' directory for primary session files and '$IgnoredDirectory' for filtered sessions."