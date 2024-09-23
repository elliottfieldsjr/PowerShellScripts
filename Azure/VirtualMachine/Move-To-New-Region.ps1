# Disk Export SAS Expiration in Seconds
$sasExpiryDuration = "86400"

# Get VM Subscription
$Subscriptions = Get-AzSubscription | Select-Object Name, ID
$SelectedSubscription = $Subscriptions | Out-GridView -PassThru -Title "Please Select the Subscription Where VM Exists"
$SubscriptionID = $SelectedSubscription.Id
Select-AzSubscription -Subscription $SubscriptionID

# Get Source VM
$VirtualMachines = Get-AzVM | Select-Object Name,ResourceGroupName
$SelectedVirtualMachine = $VirtualMachines | Out-GridView -PassThru -Title "Please Select the Source VM"
$computerName = $SelectedVirtualMachine.Name
$SourceResourceGroupName = $SelectedVirtualMachine.ResourceGroupName

# Get Destination Resource Group
$ResourceGroups = Get-AzResourceGroup | Select-Object ResourceGroupName, Location
$SelectedResourceGroup = $ResourceGroups | Out-GridView -PassThru -Title "Please Select the Destination Resource Group"
$DestinationResourceGroupName = $SelectedResourceGroup.ResourceGroupName
$DestinationLocation = $SelectedResourceGroup.Location

# Get Destination Virtual Network
$VirtualNetworks = Get-AzVirtualNetwork | Where-Object {$_.Location -like $DestinationLocation} | Select-Object Name, Location
$SelectedVirtualNetwork = $VirtualNetworks | Out-GridView -PassThru -Title "Please Select the Destination Virtual Network"
$DestinationVirtualNetworkName = $SelectedVirtualNetwork.Name
$DestinationVirtualNetwork = Get-AzVirtualNetwork -Name $DestinationVirtualNetworkName -ResourceGroupName $DestinationResourceGroupName

# Get Destination Subnet
$Subnets = $DestinationVirtualNetwork.Subnets | Select-Object Name,Id
$SelectedSubnet = $Subnets | Out-GridView -PassThru -Title "Please Select the Destination Subnet"
$DestinationSubnetName = $SelectedSubnet.Name
$DestinationSubnet = $Subnets | Where-Object {$_.Name -eq $DestinationSubnetName}

# Get Old VM Values
$OldVM = Get-AzVM -Name $computerName -ResourceGroupName $SourceResourceGroupName
$VMStatus = Get-AzVM -Name $computerName -ResourceGroupName $SourceResourceGroupName -Status
$OldOSDiskName = $OldVM.StorageProfile.OsDisk.Name
$OldOSDisk = Get-AzDisk -Name $OldOSDiskName -ResourceGroupName $SourceResourceGroupName
$AvailabilitySetId = $OldVM.AvailabilitySetReference.Id
$Datadisks = $OldVM.StorageProfile.DataDisks
$OldNetworkInterfaces = $OldVM.NetworkProfile.Networkinterfaces

IF ($OldOSDisk.Encryption.DiskEncryptionSetId -ne $null){
    $DiskEncryptionSets = Get-AzDiskEncryptionSet | Where-Object {$_.Location -like $DestinationLocation} | Select-Object Name,ResourceGroupName, Id
    $SelectedDiskEncryptionSet = $DiskEncryptionSets | Out-GridView -PassThru -Title "Please Select the Destination Disk Encryption Set"
    $DestinationDiskEncryptionSetName = $SelectedDiskEncryptionSet.Name
    $DestinationDiskEncryptionSet = Get-AzDiskEncryptionSet -Name $DestinationDiskEncryptionSetName -ResourceGroupName $DestinationResourceGroupName
}

# Create Values
$NewOSDiskName = $computerName + '_OSDisk'
$OSDiskBlobName = $NewOSDiskName + '.vhd'
$Location = $OldVM.Location
Stop-AzVM -Name $computerName -ResourceGroupName $SourceResourceGroupName -Force

# Create Storage Account
$storageAccountName = Get-Random
New-AzStorageAccount -Name $StorageAccountName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -SkuName Standard_LRS -Kind Storage

# Get Storage Context
$context = (Get-AzStorageAccount -ResourceGroupName $DestinationResourceGroupName -AccountName $storageAccountName).context

# Create Storage Container for VHD
$storageContainerName = "standardvhds"
New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $context

# Get Storage Account Variables
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $DestinationResourceGroupName -Name $StorageAccountName)[0].Value
$storageAccountId = (Get-AzStorageAccount -ResourceGroupName $DestinationResourceGroupName -AccountName $storageAccountName).Id

# Get OSDisk Export SAS URL
$OSDisksas = Grant-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $OldOSDiskName -DurationInSecond $sasExpiryDuration -Access Read

# Set Storage Account Context
$destinationContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

# Build Destination OS Disk Blob Uri
$OSDiskvhdUri = (Get-AzStorageAccount -ResourceGroupName $DestinationResourceGroupName -AccountName $storageAccountName).PrimaryEndpoints.Blob  + $storageContainerName + '/' + $OSDiskBlobName

# Copy VM OSDisk to Storage Account
Start-AzStorageBlobCopy -AbsoluteUri $OSDisksas.AccessSAS -DestContainer $storageContainerName -DestContext $destinationContext -DestBlob $OSDiskBlobName
$CopyStatus = Get-AzStorageBlobCopyState -Blob $OSDiskBlobName -Container $storageContainerName -Context $context

while ($CopyStatus.Status -ne 'Success'){
    sleep 10;
    $CopyStatus = Get-AzStorageBlobCopyState -Blob $OSDiskBlobName -Container $storageContainerName -Context $context
}

# Create New OS Managed Disk
$OSdiskConfig = New-AzDiskConfig -SkuName $OldOSDisk.Sku.Name -Location $DestinationLocation -DiskSizeGB $OldOSDisk.DiskSizeGB -SourceUri $OSDiskvhdUri -StorageAccountId $storageAccountId -CreateOption Import -OSType $OldVM.StorageProfile.OsDisk.OsType -HyperVGeneration $VMStatus.HyperVGeneration
$NewOSDisk = New-AzDisk -DiskName $NewOSDiskName -Disk $OSdiskConfig -ResourceGroupName $DestinationResourceGroupName

IF ($OldOSDisk.Encryption.DiskEncryptionSetId -ne $null){
    New-AzDiskUpdateConfig -EncryptionType $OldOSDisk.Encryption.Type -DiskEncryptionSetId $DestinationDiskEncryptionSet.Id | Update-AzDisk -ResourceGroupName $DestinationResourceGroupName -DiskName $NewOSDisk.Name
}

# Get Data Disks Export SAS URL's
IF ($Datadisks -ne $null){
    foreach ($Datadisk in $Datadisks){
        $DatadiskName = $Datadisk.Name
        $DataDiskObject = Get-AzDisk -Name $DatadiskName -ResourceGroupName $SourceResourceGroupName
        $DataDiskBlobName = $DatadiskName + '.vhd'
        $DataDisksas = Grant-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $DatadiskName -DurationInSecond $sasExpiryDuration -Access Read
        Start-AzStorageBlobCopy -AbsoluteUri $DataDisksas.AccessSAS -DestContainer $storageContainerName -DestContext $destinationContext -DestBlob $DatadiskBlobName
        $DataDiskCopyStatus = Get-AzStorageBlobCopyState -Blob $DatadiskBlobName -Container $storageContainerName -Context $context

        while ($DataDiskCopyStatus.Status -ne 'Success'){
            sleep 10;
            $DataDiskCopyStatus = Get-AzStorageBlobCopyState -Blob $DatadiskBlobName -Container $storageContainerName -Context $context
        }
        
        $DataDiskvhdUri = (Get-AzStorageAccount -ResourceGroupName $DestinationResourceGroupName -AccountName $storageAccountName).PrimaryEndpoints.Blob  + $storageContainerName + '/' + $DataDiskBlobName


        $DatadiskConfig = New-AzDiskConfig -SkuName $DataDiskObject.Sku.Name -Location $DestinationLocation -DiskSizeGB $DataDiskObject.DiskSizeGB -SourceUri $DataDiskvhdUri -StorageAccountId $storageAccountId -CreateOption Import
        $DataDisk = New-AzDisk -DiskName $DataDiskName -Disk $DatadiskConfig -ResourceGroupName $DestinationResourceGroupName
        
        $DataDiskObject.Encryption.DiskEncryptionSetId

        IF ($DataDiskObject.Encryption.DiskEncryptionSetId -ne $null){
            New-AzDiskUpdateConfig -EncryptionType $DataDiskObject.Encryption.Type -DiskEncryptionSetId $DestinationDiskEncryptionSet.Id | Update-AzDisk -ResourceGroupName $DestinationResourceGroupName -DiskName $DatadiskName
        }
    }
}

# Create New VM Config
IF ($AvailabilitySetId -eq $null){
    $NewVM = New-AzVMConfig -VMName $OldVM.Name -VMSize $OldVM.HardwareProfile.VmSize -SecurityType "Standard"
}
ELSE {$NewVM = New-AzVMConfig -VMName $OldVM.Name -VMSize $OldVM.HardwareProfile.VmSize -SecurityType "Standard" -AvailabilitySetId $AvailabilitySetId}

# Add New OS Managed Disk to VM Config
Set-AzVMOSDisk -VM $NewVM -ManagedDiskId $NewOSDisk.Id -StorageAccountType $OldOSDisk.Sku.Name -Name $NewOSDiskName -CreateOption Attach -Windows -DeleteOption Delete -Verbose

# Add Old Data Managed Disks to VM Config
IF ($Datadisks -ne $null){
    foreach ($Datadisk in $Datadisks){
        $Disk = Get-AzDisk -Name $Datadisk.Name -ResourceGroupName $DestinationResourceGroupName
        Add-AzVMDataDisk -VM $NewVM -Name $Datadisk.Name -CreateOption Attach -ManagedDiskId $Disk.Id -Lun $Datadisk.Lun -Caching $Datadisk.Caching
    }
}

# Add Network Interfaces to VM Config
foreach ($NetworkInterface in $OldNetworkInterfaces){
    $Primary = $NetworkInterface.Primary
    IF ($Primary -eq 'False'){
        $OldNic = Get-AzNetworkInterface -ResourceId $NetworkInterface.Id
        $OldNicConfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $OldNic
        IF ($OldNicConfig.PublicIpAddressText -ne $null){
            $PublicIPName = $computerName + '-pip1'
            $PublicIP = New-AzPublicIpAddress -Name $PublicIPName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4
            $NICRandom = Get-Random
            $NicName = $computerName + '-' + (Get-Random)
            $Nic = New-AzNetworkInterface -Force -Name $NicName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -SubnetId $DestinationSubnet.Id -PublicIpAddressId $PublicIP.Id
            Add-AzVMNetworkInterface -Id $Nic.Id -VM $NewVM
        }
        ELSE {
            $NicName = $computerName + '-' + (Get-Random)
            $Nic = New-AzNetworkInterface -Force -Name $NicName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -SubnetId $DestinationSubnet.Id
            Add-AzVMNetworkInterface -Id $Nic.Id -VM $NewVM
        }
    }
    ELSE {
        $OldNic = Get-AzNetworkInterface -ResourceId $NetworkInterface.Id
        $OldNicConfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $OldNic
        IF ($OldNicConfig.PublicIpAddressText -ne $null){
            $PublicIPName = $computerName + '-pip1'
            $PublicIP = New-AzPublicIpAddress -Name $PublicIPName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4
            $NICRandom = Get-Random
            $NicName = $computerName + '-' + (Get-Random)
            $Nic = New-AzNetworkInterface -Force -Name $NicName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -SubnetId $DestinationSubnet.Id -PublicIpAddressId $PublicIP.Id
            Add-AzVMNetworkInterface -Id $Nic.Id -VM $NewVM -Primary
        }
        ELSE {
            $NicName = $computerName + '-' + (Get-Random)
            $Nic = New-AzNetworkInterface -Force -Name $NicName -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -SubnetId $DestinationSubnet.Id
            Add-AzVMNetworkInterface -Id $Nic.Id -VM $NewVM -Primary
        }
    }
}

# Remove Disk Export from Old OS Managed Disk
Revoke-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $OldOSDisk.Name

# Remove Disk Export from old Data Disks
IF ($Datadisks -ne $null){
    foreach ($Datadisk in $Datadisks){
        $DatadiskName = $Datadisk.Name
        Revoke-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $DatadiskName
    }
}

# Create New VM
New-AzVM -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -VM $NewVM -Verbose

Start-AzVM -Name $computerName -ResourceGroupName $DestinationResourceGroupName

$NewVM = Get-AzVM -Name $computerName -ResourceGroupName $DestinationResourceGroupName

# Manually Add Load Balancer
# Manually Enable Managed Identity
$IdentityExists = $OldVM.Identity

IF ($IdentityExists -ne $null){
    IF ($IdentityExists.Type -eq 'SystemAssigned'){
        # Disable System Managed Identity on Old VM
        Update-AzVm -ResourceGroupName $SourceResourceGroupName -VM $OldVM -IdentityType None    
        Update-AzVm -ResourceGroupName $DestinationResourceGroupName -VM $NewVM -IdentityType SystemAssigned   
    }
    IF ($IdentityExists.Type -eq 'UserAssigned'){
        Update-AzVm -ResourceGroupName $SourceResourceGroupName -VM $OldVM -IdentityType None
        $UserAssignedIdentityKeys = $OldVM.Identity.UserAssignedIdentities.Keys
        foreach ($Key in $UserAssignedIdentities){
            Update-AzVm -ResourceGroupName $DestinationResourceGroupName -VM $NewVM -IdentityType UserAssigned -IdentityId $Key
        }
    }
}

# Remove Old VM
Remove-AzVM -Name $OldVM.Name -ResourceGroupName $SourceResourceGroupName -Force
