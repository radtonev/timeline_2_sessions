### Prerequisites:
Windows event log in CSV format.

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


