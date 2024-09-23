$VMsToConvert = @()
$VMsToConvert += 'WIN-VM-TL'
$VMsToConvert += 'WIN-VM-SL'

$StorageResourceGroupName ="WIN-Infra"
$storageContainerName = "standardvhds"
$sasExpiryDuration = "3600"
$NewDiskEncryptionSetID = "/subscriptions/e4409240-d678-41c2-9508-691da4fc7120/resourceGroups/WIN-Infra/providers/Microsoft.Compute/diskEncryptionSets/WIN-Infra-DDES-01"
$storageAccountName = Get-Random
$StorageLocation = "usgovvirginia"

# Create Storage Account
New-AzStorageAccount -Name $StorageAccountName -ResourceGroupName $StorageResourceGroupName -Location $StorageLocation -SkuName Standard_LRS -Kind Storage

# Get Storage Context
$context = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -AccountName $storageAccountName).context

# Create Storage Container for VHD
New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $context

# Get Storage Account Variables
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName)[0].Value
$storageAccountId = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -AccountName $storageAccountName).Id

# Set Storage Account Context
$destinationContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

foreach ($computerName in $VMsToConvert){
    # Input Variables

    # Get Old VM Values
    $VM = Get-AzVM -Name $computerName
    $VMResourceGroupName = $VM.ResourceGroupName
    $VMStatus = Get-AzVM -Name $computerName -ResourceGroupName $VMResourceGroupName -Status
    $OldDiskName = $VM.StorageProfile.OsDisk.Name
    $OldOSDisk = Get-AzDisk -Name $OldDiskName -ResourceGroupName $VMResourceGroupName

    # Create Values
    $NewDiskName = $computerName + '_DESUpdated'
    $BlobName = $NewDiskName + '.vhd'
    $Location = $VM.Location
    Stop-AzVM -Name $computerName -ResourceGroupName $VMResourceGroupName -Force

    # Get Disk Export SAS URL
    $sas = Grant-AzDiskAccess -ResourceGroupName $VMResourceGroupName -DiskName $OldDiskName -DurationInSecond $sasExpiryDuration -Access Read

    # Buld Destination Blob Uri
    $vhdUri = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -AccountName $storageAccountName).PrimaryEndpoints.Blob  + $storageContainerName + '/' + $BlobName

    # Copy VM OSDisk to Storage Account
    Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestContainer $storageContainerName -DestContext $destinationContext -DestBlob $BlobName
    $CopyStatus = Get-AzStorageBlobCopyState -Blob $BlobName -Container $storageContainerName -Context $context

    while ($CopyStatus.Status -ne 'Success'){
        sleep 10;
        $CopyStatus = Get-AzStorageBlobCopyState -Blob $BlobName -Container $storageContainerName -Context $context
    }

    # Create New OS Managed Disk
    $diskConfig = New-AzDiskConfig -SkuName $OldOSDisk.Sku.Name -Location $VM.Location -DiskSizeGB $OldOSDisk.DiskSizeGB -SourceUri $vhdUri -StorageAccountId $storageAccountId -CreateOption Import -OSType $VM.StorageProfile.OsDisk.OsType -HyperVGeneration $VMStatus.HyperVGeneration
    $SecurityType = $VM.SecurityProfile.SecurityType
    IF ($SecurityType -eq 'TrustedLaunch'){
        Set-AzDiskSecurityProfile -Disk $diskconfig -SecurityType "TrustedLaunch"
    }
    $NewOSDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $VMResourceGroupName

    IF ($OldOSDisk.Encryption.DiskEncryptionSetId -ne $null){
        New-AzDiskUpdateConfig -EncryptionType $OldOSDisk.Encryption.Type -DiskEncryptionSetId $NewDiskEncryptionSetID | Update-AzDisk -ResourceGroupName $VMResourceGroupName -DiskName $NewOSDisk.Name
    }

    # Swap OS Disk
    Set-AzVMOSDisk -VM $VM -ManagedDiskId $NewOSDisk.Id -Name $NewOSDisk.Name
    Update-AzVM -ResourceGroupName $VMResourceGroupName -VM $VM
    Start-AzVM -ResourceGroupName $VMResourceGroupName -Name $VM.Name

    # Remove Disk Export from Old OS Managed Disk
    Revoke-AzDiskAccess -ResourceGroupName $VMResourceGroupName -DiskName $OldOSDisk.Name
}