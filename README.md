# Prerequisites:
Windows event log in CSV format. 
The events neet to be sorted by timestamp! 

# Result:
The script generates separate CSV timelines for each individual user session.
This makes it useful for log analysis because you can get more context for each user (sometimes service) activity on the system. 

# Usage:
Windows: timeline_2_sessions.ps1 -TimelineCsv path/to/timeline.csv 
Linux: pwsh timeline_2_sessions.ps1 -TimelineCsv path/to/timeline.csv

# Output:
Directory: 
./output/sessions
./output/sessions/ignored	(sessions that do not contain any significant events)

Naming format:
[UserName]-[LogonId]-[LogonType]-[StartTimestamp]-[SessionDuration-H_M_S].csv
[UserName]-[LogonId]-[LogonType]-[StartTimestamp]-[SessionDuration-H_M_S]-nologon.csv	(when there is no logon event)

# Screenshots:


