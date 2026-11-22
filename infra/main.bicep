targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Name of the Linux AKS cluster.')
param clusterName string = 'ood-aks'

@description('Minimum autoscaled node count. Must not exceed nodeMaxCount.')
@minValue(1)
@maxValue(50)
param nodeMinCount int = 1

@description('Maximum autoscaled node count. Must be at least nodeMinCount.')
@minValue(1)
@maxValue(50)
param nodeMaxCount int = 3

param nodeVmSize string = 'Standard_D4s_v5'

@description('Capacity of the dedicated premium NFS share in GiB.')
@minValue(100)
@maxValue(102400)
param shareQuotaGiB int = 100

var suffix = uniqueString(resourceGroup().id, clusterName)
var registryName = 'oodacr${suffix}'
var storageAccountName = 'oodnfs${suffix}'
var shareName = 'ondemand'
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource network 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${clusterName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
  }
}

resource nodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: network
  name: 'aks'
  properties: {
    // Enough addresses for 50 Azure CNI nodes, their pods, and rolling upgrades.
    addressPrefix: '10.20.0.0/20'
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
      }
    ]
  }
}

resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-identity'
  location: location
}

resource subnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(nodeSubnet.id, clusterIdentity.id, networkContributorRoleId)
  scope: nodeSubnet
  properties: {
    principalId: clusterIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
  }
}

resource cluster 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentity.id}': {}
    }
  }
  properties: {
    dnsPrefix: clusterName
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        vmSize: nodeVmSize
        count: nodeMinCount
        enableAutoScaling: true
        minCount: nodeMinCount
        maxCount: nodeMaxCount
        maxPods: 30
        vnetSubnetID: nodeSubnet.id
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      serviceCidr: '10.21.0.0/16'
      dnsServiceIP: '10.21.0.10'
    }
  }
  dependsOn: [
    subnetNetworkContributor
  ]
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, cluster.id, acrPullRoleId)
  scope: registry
  properties: {
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    // Azure Files NFS uses port 2049, not HTTPS; subnet ACLs restrict access.
    supportsHttpsTrafficOnly: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      ipRules: []
      virtualNetworkRules: [
        {
          id: nodeSubnet.id
          action: 'Allow'
        }
      ]
    }
  }
}

resource nfsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  name: '${storage.name}/default/${shareName}'
  properties: {
    enabledProtocols: 'NFS'
    shareQuota: shareQuotaGiB
    // One isolated user's share per deployment, not a shared multi-user export.
    // A root init container must create/chown directories to ondemand UID/GID 1000.
    // NoRootSquash permits that initialization; portal and jobs then run as 1000:1000.
    rootSquash: 'NoRootSquash'
  }
}

output clusterName string = cluster.name
output registryLoginServer string = registry.properties.loginServer
output nfsServer string = '${storage.name}.file.${environment().suffixes.storage}'
output nfsPath string = '/${storage.name}/${shareName}'
