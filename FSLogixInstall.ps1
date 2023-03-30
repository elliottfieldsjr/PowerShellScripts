$Directory = New-Item -Path C:\FSLogixInstall -ItemType Directory
$OutputFilePath = 'C:\' + $Directory.Name + '\FSLogix.zip'
$UnzipPath = 'C:\' + $Directory.Name
Invoke-WebRequest -Uri https://download.microsoft.com/download/c/4/4/c44313c5-f04a-4034-8a22-967481b23975/FSLogix_Apps_2.9.8440.42104.zip -OutFile $OutputFilePath
Expand-Archive -Path "$OutputFilePath" -DestinationPath "$UnzipPath"
Start-Process "C:\FSLogixInstall\x64\release\FSLogixAppsSetup.exe" -ArgumentList "/install /quiet" -Wait
$regPath = "HKLM:\SOFTWARE\FSLogix\Profiles"
New-ItemProperty -Path $regPath -Name Enabled -PropertyType DWORD -Value 1 -Force
New-ItemProperty -Path $regPath -Name VHDLocations -PropertyType MultiString -Value \\avdsmartcardtesting01.file.core.usgovcloudapi.net\profiles -Force
