# Data Operator for Managed Disks Role must be granted to all Managed Disks that will be modified
$VMsToConvert = @()
$VMsToConvert += 'WIN-VM-TL'
$VMsToConvert += 'WIN-VM-SL'
$VMsToConvert += 'LIN-VM-TL'
$SubscriptionID = Read-Host 'Please Enter a Subscription ID'

$DESResourceGroupName = 'Disk-Infra'
$DESName = 'Linux-DDES'
$DiskNameAddOn = 'DESUpdated3'
$DiskAccessName = 'des-transfer'
$MgmtVMResourceGroupName = 'Disk-Infra'
$MgmtVMVNetResourceGroupName = 'Disk-Infra'
$MgmtVMVNetName = 'VM-VNet'

$StorageResourceGroupName = 'Disk-Infra'
$StorageVNetResourceGroupName = 'Disk-Infra'
$StorageVNetName = 'Storage-VNet1'
$storageContainerName = 'standardvhds'
$sasExpiryDuration = '3600'
$storageAccountName = Get-Random
$StorageLocation = 'usgovvirginia'
$StorageDNSZone = 'privatelink.blob.core.usgovcloudapi.net'
$DiskAccessEndpointGroupID = 'disks'
$BlobEndpointGroupID = 'blob'

# Load Disk Encryption Set Resource ID
$NewDiskEncryptionSetID = '/subscriptions/' + $SubscriptionID + '/resourceGroups/' + $DESResourceGroupName + '/providers/Microsoft.Compute/diskEncryptionSets/' + $DESName

# Load Virtual Networks
$StorageVNet = Get-AzVirtualNetwork -ResourceGroupName $StorageVNetResourceGroupName -Name $StorageVNetName
$MgmtVMVNet = Get-AzVirtualNetwork -ResourceGroupName $MgmtVMVNetResourceGroupName -Name $MgmtVMVNetName

# Create Storage Account
New-AzStorageAccount -Name $StorageAccountName -ResourceGroupName $StorageResourceGroupName -Location $StorageLocation -SkuName Standard_LRS -Kind StorageV2

# Place the previously created StorageAccount into a variable
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $storageAccountName

# Create the Blob Private Endpoint Connection
$pec = @{
    Name = $StorageAccount.StorageAccountName + '-' + $BlobEndpointGroupID
    PrivateLinkServiceId = $StorageAccount.Id
    GroupID = $BlobEndpointGroupID
}
$privateEndpointConnection = New-AzPrivateLinkServiceConnection @pec

# Create the Disk Access Private Endpoint
$pe = @{
    ResourceGroupName = $StorageResourceGroupName
    Name = $storageAccount.StorageAccountName + '-' + $BlobEndpointGroupID
    Location = $StorageLocation
    Subnet = $StorageVNet.Subnets[0]
    PrivateLinkServiceConnection = $privateEndpointConnection
}
New-AzPrivateEndpoint @pe

# Create the Blob Private DNS Zone
$zn = @{
    ResourceGroupName = $StorageResourceGroupName
    Name = $StorageDNSZone
}
$zone = New-AzPrivateDnsZone @zn

# Configure the DNS zone. ##
$cg = @{
    Name = $StorageDNSZone
    PrivateDnsZoneId = $zone.ResourceId
}
$config = New-AzPrivateDnsZoneConfig @cg

# Create a Storage VNet DNS Network LInk
$lk = @{
    ResourceGroupName = $StorageResourceGroupName
    ZoneName = $StorageDNSZone
    Name = $StorageVNet.Name
    VirtualNetworkId = $StorageVNet.Id
}
$link = New-AzPrivateDnsVirtualNetworkLink @lk

# Create the DNS Zone Group
$zg = @{
    ResourceGroupName = $StorageResourceGroupName
    PrivateEndpointName = $storageAccount.StorageAccountName + '-' + $BlobEndpointGroupID
    Name = $BlobEndpointGroupID
    PrivateDnsZoneConfig = $config
}
New-AzPrivateDnsZoneGroup @zg

# Disable Public Access
Set-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -Name $StorageAccount.StorageAccountName -PublicNetworkAccess Disabled

# Get Storage Context
$context = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -AccountName $storageAccountName).context

# Create Storage Container for VHD
New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $context

# Get Storage Account Variables
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $StorageResourceGroupName -Name $StorageAccountName)[0].Value
$storageAccountId = (Get-AzStorageAccount -ResourceGroupName $StorageResourceGroupName -AccountName $storageAccountName).Id

# Set Storage Account Context
$destinationContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey

# Create disk Access
New-AzDiskAccess -ResourceGroupName $StorageResourceGroupName -Name $DiskAccessName -Location $StorageLocation

# Place the previously created DiskAccess into a variable
$DiskAccess = Get-AzDiskAccess -ResourceGroupName $StorageResourceGroupName -Name $DiskAccessName

# Create the Disk Access Private Endpoint Connection
$pec = @{
    Name = $DiskAccess.Name + '-' + $DiskAccessEndpointGroupID
    PrivateLinkServiceId = $DiskAccess.ID
    GroupID = $DiskAccessEndpointGroupID
}
$privateEndpointConnection = New-AzPrivateLinkServiceConnection @pec

# Create the Disk Access Private Endpoint
$pe = @{
    ResourceGroupName = $StorageResourceGroupName
    Name = $DiskAccess.Name + '-' + $DiskAccessEndpointGroupID
    Location = $StorageLocation
    Subnet = $StorageVNet.Subnets[0]
    PrivateLinkServiceConnection = $privateEndpointConnection
}
New-AzPrivateEndpoint @pe

# Configure the DNS Zone
$cg = @{
    Name = $StorageDNSZone
    PrivateDnsZoneId = $zone.ResourceId
}
$config = New-AzPrivateDnsZoneConfig @cg

# Create the Disk Access DNS Zone Group
$zg = @{
    ResourceGroupName = $StorageResourceGroupName
    PrivateEndpointName = $DiskAccess.Name + '-' + $DiskAccessEndpointGroupID
    Name = $DiskAccessEndpointGroupID
    PrivateDnsZoneConfig = $config
}
New-AzPrivateDnsZoneGroup @zg

# Create a Management VM VNet DNS Network LInk
$lk = @{
    ResourceGroupName = $StorageResourceGroupName
    ZoneName = $StorageDNSZone
    Name = $MgmtVMVNet.Name
    VirtualNetworkId = $MgmtVMVNet.Id
}
$link = New-AzPrivateDnsVirtualNetworkLink @lk

foreach ($computerName in $VMsToConvert){
    # Input Variables

    # Get VM Values
    $VM = Get-AzVM -Name $computerName
    $VMResourceGroupName = $VM.ResourceGroupName
    $VMStatus = Get-AzVM -Name $computerName -ResourceGroupName $VMResourceGroupName -Status
    $OldDiskName = $VM.StorageProfile.OsDisk.Name
    $OldOSDisk = Get-AzDisk -Name $OldDiskName -ResourceGroupName $VMResourceGroupName
    $VMNetworkInterfaceCount = ($VM.NetworkProfile.NetworkInterfaces).count
    IF ($VMNetworkInterfaceCount -gt 1){
        $VMNetworkInterface = $VM.NetworkProfile.NetworkInterfaces | Where-Object {$_.Primary -like 'True'}
    }
    ELSE{
        $VMNetworkInterface =  $VM.NetworkProfile.NetworkInterfaces
    }
    $VMNetworkInterfaceName = ($VMNetworkInterface.id).Split('/')[-1]
    $VMNetworkInterfaceInfo = Get-AzNetworkInterface -Name $VMNetworkInterfaceName
    $VMVNetName = (($VMNetworkInterfaceInfo.IpConfigurations[0].Subnet.Id).Split('/'))[-3]
    $VMVNetResourceGroupName = (($VMNetworkInterfaceInfo.IpConfigurations[0].Subnet.Id).Split('/'))[-7]
    $VMVNet = Get-AzVirtualNetwork -ResourceGroupName $VMVNetResourceGroupName -Name $VMVNetName

    $VMLinkExists = Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $StorageResourceGroupName -ZoneName $StorageDNSZone -Name $VMVNetName -ErrorAction 0
    IF ($VMLinkExists -eq $null){
        # Create a VM VNet DNS Network Link
        $lk = @{
            ResourceGroupName = $StorageResourceGroupName
            ZoneName = $StorageDNSZone
            Name = $VMVNetName
            VirtualNetworkId = $VMVNet.Id
        }
        $link = New-AzPrivateDnsVirtualNetworkLink @lk
    }

    # Create Values
    $NewDiskName = $computerName + '_' + $DiskNameAddOn
    $BlobName = $NewDiskName + '.vhd'
    $Location = $VM.Location
    Stop-AzVM -Name $computerName -ResourceGroupName $VMResourceGroupName -Force

    # Get Disk Export SAS URL
    New-AzDiskUpdateConfig -NetworkAccessPolicy AllowPrivate -DiskAccessId $DiskAccess.Id | Update-AzDisk -ResourceGroupName $VMResourceGroupName  -DiskName $OldDiskName
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