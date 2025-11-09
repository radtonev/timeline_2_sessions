### Prerequisites:
Windows event log in CSV format.

If you have **.evtx** files use this script to convert them to sorted csv timeline: https://github.com/radtonev/bulk-evtx-2-csv

**The events need to be sorted by timestamp ascending!** 

### Result:
The script generates separate CSV timelines for each individual user session. This makes it useful for log analysis because you can get more context  what happened while someone had active session on the system.

### Usage:
Windows: `timeline_2_sessions.ps1 -TimelineCsv path/to/timeline.csv` 

Linux: `pwsh timeline_2_sessions.ps1 -TimelineCsv path/to/timeline.csv`

### Output:
#### Directory: 
`./output/sessions`

`./output/sessions/ignored`	- sessions that do not contain any significant events

#### Naming format:
`[UserName]-[LogonId]-[LogonType]-[StartTimestamp]-[SessionDuration-H_M_S].csv`

`[UserName]-[LogonId]-[LogonType]-[StartTimestamp]-[SessionDuration-H_M_S]-nologon.csv`	- when there is no logon event in the logs for this specific user

# Screenshot:

<img width="1394" height="573" alt="image" src="https://github.com/user-attachments/assets/24c63818-0724-4713-b4ca-80074c61a08b" />

#### Troubleshooting:

If you receive errors that a field can't be found in the csv, modify the following lines in the script based on the column headers of the csv you provide in the arguments. Make sure the correspond to the proper value.

```
# --- Define Field Definitions (Mandatory or Optional) ---
# Key = variable name; Alternatives = array of possible field names; Mandatory = boolean
$FieldDefinitions = @(
    @{ Key='EpochTimeProp'; Alternatives=@('EpochTime'); Mandatory=$true },
    @{ Key='EventCodeProp'; Alternatives=@('EventCode', 'EventID', 'MY_CUSTOM_COLUMN_HEADER'); Mandatory=$true },
    @{ Key='TimestampProp'; Alternatives=@('Timestamp', 'TimeGenerated', 'datetime', 'TimeCreated'); Mandatory=$true },
    @{ Key='TargetUserNameProp'; Alternatives=@('TargetUserName', 'UserName'); Mandatory=$true },
    @{ Key='LogonTypeProp'; Alternatives=@('LogonType'); Mandatory=$true },
    @{ Key='TargetLogonIdProp'; Alternatives=@('TargetLogonId', 'TargetId'); Mandatory=$true },
    @{ Key='SubjectLogonIdProp'; Alternatives=@('SubjectLogonId', 'SubjectId'); Mandatory=$true },
    @{ Key='SubjectUserNameProp'; Alternatives=@('SubjectUserName', 'SubjectUser'); Mandatory=$false },
    @{ Key='LegacyLogonIdProp'; Alternatives=@('LogonId'); Mandatory=$false }
)
```
Example:
@{ Key='EventCodeProp'; Alternatives=@('EventCode', 'EventID', **'MY_CUSTOM_COLUMN_HEADER'**); Mandatory=$true },

Other option is to just modify your input csv column headers accordingly.

**If you have missing mandatory columns you need to add them to your csv!**

If you are missing EpochTime as your first column you can use the following command to generate it and output a sorted timeline:
```
cat timeline.csv | awk -F, 'BEGIN {OFS=","} NR==1 {print "EpochTime", $0; next} {gsub(/"/, "", $8); cmd = "date -d \"" $8 "\" +%s"; cmd | getline epoch_time; close(cmd); print epoch_time, $0}' | sort -n > sorted-timeline.csv
```
$8 needs to correspond to the index of date/time column in your timeline.csv
