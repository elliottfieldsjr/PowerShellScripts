# Input Variables
$computerName = "HV-VM1"
$resourceGroupName ="ASR-VA"
$storageContainerName = "standardvhds"
$sasExpiryDuration = "3600"

# Get Old VM Values
$OldVM = Get-AzVM -Name $computerName -ResourceGroupName $resourceGroupName
$VMStatus = Get-AzVM -Name $computerName -ResourceGroupName $resourceGroupName -Status
$OldDiskName = $OldVM.StorageProfile.OsDisk.Name
$OldOSDisk = Get-AzDisk -Name $OldDiskName -ResourceGroupName $resourceGroupName
$AvailabilitySetId = $OldVM.AvailabilitySetReference.Id
$Datadisks = $OldVM.StorageProfile.DataDisks
$NetworkInterfaces = $OldVM.NetworkProfile.Networkinterfaces

# Create Values
$NewDiskName = $computerName + '_OSDisk'
$BlobName = $NewDiskName + '.vhd'
$Location = $OldVM.Location
$storageAccountName = Get-Random
Stop-AzVM -Name $computerName -ResourceGroupName $resourceGroupName -Force

# Create Storage Account
New-AzStorageAccount -Name $StorageAccountName -ResourceGroupName $resourceGroupName -Location $Location -SkuName Standard_LRS -Kind Storage

# Get Storage Context
$context = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -AccountName $storageAccountName).context

# Create Storage Container for VHD
New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $context

# Get Storage Account Variables
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $StorageAccountName)[0].Value
$storageAccountId = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -AccountName $storageAccountName).Id

# Get Disk Export SAS URL
$sas = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $OldDiskName -DurationInSecond $sasExpiryDuration -Access Read

# Set Storage Account Context
$destinationContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

# Buld Destination Blob Uri
$vhdUri = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -AccountName $storageAccountName).PrimaryEndpoints.Blob  + $storageContainerName + '/' + $BlobName

# Copy VM OSDisk to Storage Account
Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestContainer $storageContainerName -DestContext $destinationContext -DestBlob $BlobName
$CopyStatus = Get-AzStorageBlobCopyState -Blob $BlobName -Container $storageContainerName -Context $context

while ($CopyStatus.Status -ne 'Success'){
    sleep 10;
    $CopyStatus = Get-AzStorageBlobCopyState -Blob $BlobName -Container $storageContainerName -Context $context
}

# Create New OS Managed Disk
$diskConfig = New-AzDiskConfig -SkuName $OldOSDisk.Sku.Name -Location $location -DiskSizeGB $OldOSDisk.DiskSizeGB -SourceUri $vhdUri -StorageAccountId $storageAccountId -CreateOption Import -OSType $OldVM.StorageProfile.OsDisk.OsType -HyperVGeneration $VMStatus.HyperVGeneration
$NewOSDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

IF ($OldOSDisk.Encryption.DiskEncryptionSetId -ne $null){
    New-AzDiskUpdateConfig -EncryptionType $OldOSDisk.Encryption.Type -DiskEncryptionSetId $OldOSDisk.Encryption.DiskEncryptionSetId | Update-AzDisk -ResourceGroupName $resourceGroupName -DiskName $NewOSDisk.Name
}

# Remove Old VM
Remove-AzVM -Name $OldVM.Name -ResourceGroupName $resourceGroupName -Force

# Create New VM Config
IF ($AvailabilitySetId -eq $null){
    $NewVM = New-AzVMConfig -VMName $OldVM.Name -VMSize $OldVM.HardwareProfile.VmSize -SecurityType "Standard"
}
ELSE {$NewVM = New-AzVMConfig -VMName $OldVM.Name -VMSize $OldVM.HardwareProfile.VmSize -SecurityType "Standard" -AvailabilitySetId $AvailabilitySetId}

# Add New OS Managed Disk to VM Config
Set-AzVMOSDisk -VM $NewVM -ManagedDiskId $NewOSDisk.Id -StorageAccountType $OldOSDisk.Sku.Name -Name $NewDiskName -CreateOption Attach -Windows -DeleteOption Delete -Verbose

# Add Old Data Managed Disks to VM Config
IF ($Datadisks -ne $null){
    foreach ($Datadisk in $Datadisks){
        $Disk = Get-AzDisk -Name $Datadisk.Name -ResourceGroupName $resourceGroupName
        Add-AzVMDataDisk -VM $NewVM -Name $Datadisk.Name -CreateOption Attach -ManagedDiskId $Disk.Id -Lun $Datadisk.Lun -DiskEncryptionSetId $OldOSDisk.Encryption.DiskEncryptionSetId -Caching $Datadisk.Caching
    }
}

# Add Old Network Interfaces to VM Config
foreach ($NetworkInterface in $NetworkInterfaces){
    $Primary = $NetworkInterface.Primary
    IF ($Primary -eq 'False'){
        Add-AzVMNetworkInterface -Id $NetworkInterface.Id -VM $NewVM
    }
    ELSE {Add-AzVMNetworkInterface -Id $NetworkInterface.Id -VM $NewVM -Primary}
}

# Remove Disk Export from Old OS Managed Disk
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $OldOSDisk.Name

# Remove Original 
Remove-AzVM -Name $computerName -ResourceGroupName $resourceGroupName -ForceDeletion

# Create New VM
New-AzVM -ResourceGroupName $resourceGroupName -Location $OldVM.Location -VM $NewVM -Verbose

Start-AzVM -Name $computerName -ResourceGroupName $resourceGroupName

# Manually Add Load Balancer
# Manually Enable Managed Identity