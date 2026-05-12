# list-smb-shares
List SMB Shares with Active Directory or with input file

Command to start the programm: .\ListSMBShares.ps1 -OutDir ".\ShareInventory" -ServerListPath ".\test.txt" -Throttle 20 -IncludeAdminShares -WithLocal -WithNfsShares

# Requirements:
 - Server who runs the script needs the following:
   - AD DS and AD LDS Tools installed on Machine for running the Script
   - Login with a Domain Admin
   - Machine is joined the AD

 - Server who recieve the Script:
   - Machine is joined the AD

# Parameters (Input):
 - OutDir (optional): Set up the driectory for the CSV files
 - Throttel (optional): Set the Maximum number of concurrent remote connections
 - IncludeAdminShares (optional): If its set to true, the programm will include the default admin shares into the summary
 - NoDetails (optional): If set to true, the programm will only create a summary, no detailed files of NTFS and Shares
 - WithLocal (optional): If set to true, the programm will also run the script on the local machine and include it in the summary
 - WithNfsShares (optional): If set to true, the programm will also include NFS Shares in the summary

 Input txt file: (If Path field is empty, he will use Active Directory to find server)
 The file consist of the hostnames of the server.
 Example:
 vm-testShare2
 vm-testShareAD
 vm-testShare3

# Output:
 The programm will create three CSV files in the selected folder. If the flag "NoDetails" is set to true, the programm will only create one summary file.
 The Structure looks as following:

 ShareSummary.csv: Summarize per Share
 ServerName, FQDNS, IP Address, OS, OS Version, ShareName, Description, Path, SharePermission (if it is SMB Share), NFS Permission (if it is NFS Share), NTFS Share Permission, PSComputerName, RunspaceId, PSShowComputerName
 Share Permission are summarized in an string with the following structure:
 "AccountName:AccessRight:AccessControlType | AccountName:AccessRight:AccessControlType"
 NFS Share Permission are summarized in an String with the following structure:
 "ClientName:Permission:AllowRootAccess | ClientName:Permission:AllowRootAccess"
 NTFS Share Permission are summarized in an String with the following structure:
 "IdentityReference:FileSystemRights:AccessControlType:IsInherited | IdentityReference:FileSystemRights:AccessControlType:IsInherited"
 
 ShareACE.csv: Summarize per Account/ClientName
 ServerName, ShareName, Path, Account, Right, Type, PSComputerName, RunspaceId, PSShowComputerName

 NtfsACE.csv: Summarize per Account/ClientName
 ServerName, ShareName, Path, Identity, FileSystemRights, AccessControlType, IsInherited, InheritanceFlags, PropagationFlags, PSComputerName, RunspaceId, PSShowComputerName
