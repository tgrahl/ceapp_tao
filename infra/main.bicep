// TAO Assessment on Azure Container Apps with scale-to-zero.
//
//   Internet ──HTTPS──► Container App "tao" (min 0 replicas, HTTP-scaled)
//                         │  Azure Files: /var/www/html/config, /var/www/html/data
//                         └─(VNet, private)──► Azure Database for MySQL Flexible Server
//   Container Apps Job "tao-install" (manual) performs the one-time TAO install.

targetScope = 'resourceGroup'

@description('Short prefix for all resource names (lowercase letters/digits, 3-12 chars).')
@minLength(3)
@maxLength(12)
param prefix string = 'tao'

param location string = resourceGroup().location

@description('Name of an existing Azure Container Registry in this resource group holding the TAO image.')
param acrName string

@description('Image repository:tag inside the registry.')
param image string = 'tao:latest'

@description('MySQL administrator login (also used by TAO).')
param mysqlAdminUser string = 'taoadmin'

@secure()
@description('MySQL administrator password.')
param mysqlAdminPassword string

@description('TAO back-office administrator login.')
param taoAdminUser string = 'admin'

@secure()
@description('TAO back-office administrator password.')
param taoAdminPassword string

@description('Comma-separated TAO extensions for the install job. TAO >= 2026.x needs taoMediaManager in addition to taoCe.')
param taoExtensions string = 'taoCe'

@description('Show the "Guest access" link on the login page and allow anonymous guest deliveries. Applied by the install job on every deployment.')
param taoGuestAccess bool = false

@description('One-off recovery: set the TAO admin user\'s password to taoAdminPassword during this deployment. TAO otherwise uses taoAdminPassword only at install time.')
param resetAdminPassword bool = false

@description('TAO log level written to the container output (Container Apps console logs). Applied by the install job on every deployment.')
@allowed([ 'debug', 'info', 'notice', 'warning', 'error', 'critical' ])
param taoLogLevel string = 'warning'

@description('Maximum replicas under load. Minimum is always 0 (scale to zero).')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

@description('Seconds without traffic before the app scales back to 0.')
param cooldownSeconds int = 900

@description('Concurrent HTTP requests per replica before another replica is added.')
param concurrentRequestsPerReplica int = 30

@allowed([ '0.5', '1.0', '1.5', '2.0' ])
param cpu string = '1.0'

@allowed([ '1Gi', '2Gi', '3Gi', '4Gi' ])
param memory string = '2Gi'

@description('MySQL compute SKU. Standard_B1ms (1 vCore, 2 GiB, ~171 connections) is the smallest size Azure reliably offers; Standard_B1s (1 GiB) is cheaper but refused in many regions (OperationNotSupportedStandardB1s).')
param mysqlSku string = 'Standard_B1ms'

@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param mysqlTier string = 'Burstable'

param mysqlStorageGB int = 20

@description('Quota (GiB) of the TAO data file share.')
param dataShareQuotaGB int = 100

param tags object = { app: 'tao' }

var suffix = uniqueString(resourceGroup().id, prefix)
var appName = '${prefix}-app'
var dbName = 'tao'

// ---------------------------------------------------------------- monitoring
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------- network
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.40.0.0/16' ] }
    subnets: [
      {
        name: 'aca'
        properties: {
          addressPrefix: '10.40.0.0/23'
          delegations: [
            { name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
        }
      }
      {
        name: 'mysql'
        properties: {
          addressPrefix: '10.40.2.0/24'
          delegations: [
            { name: 'mysql', properties: { serviceName: 'Microsoft.DBforMySQL/flexibleServers' } }
          ]
        }
      }
    ]
  }
}

resource mysqlDns 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${prefix}${suffix}.private.mysql.database.azure.com'
  location: 'global'
  tags: tags
}

resource mysqlDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: mysqlDns
  name: 'vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// ---------------------------------------------------------------- database
resource mysql 'Microsoft.DBforMySQL/flexibleServers@2023-12-30' = {
  name: '${prefix}-mysql-${suffix}'
  location: location
  tags: tags
  sku: { name: mysqlSku, tier: mysqlTier }
  properties: {
    version: '8.0.21'
    administratorLogin: mysqlAdminUser
    administratorLoginPassword: mysqlAdminPassword
    storage: { storageSizeGB: mysqlStorageGB, autoGrow: 'Enabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: {
      delegatedSubnetResourceId: '${vnet.id}/subnets/mysql'
      privateDnsZoneResourceId: mysqlDns.id
      publicNetworkAccess: 'Disabled'
    }
  }
  dependsOn: [ mysqlDnsLink ]
}

resource mysqlDb 'Microsoft.DBforMySQL/flexibleServers/databases@2023-12-30' = {
  parent: mysql
  name: dbName
  properties: { charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci' }
}

// TAO's installer cannot pass TLS options to PDO. The server is reachable only
// through the private VNet subnet (public access disabled), so plain transport is
// confined to the VNet.
resource mysqlTls 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'require_secure_transport'
  properties: { value: 'OFF', source: 'user-override' }
}

// ---------------------------------------------------------------- storage
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: take('${prefix}st${suffix}', 24)
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // required for Azure Files mounts in Container Apps
    supportsHttpsTrafficOnly: true
  }
}

resource fileSvc 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource configShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileSvc
  name: 'tao-config'
  properties: { shareQuota: 1 }
}

resource dataShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileSvc
  name: 'tao-data'
  properties: { shareQuota: dataShareQuotaGB }
}

// ---------------------------------------------------------------- registry access
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id'
  location: location
  tags: tags
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

// ---------------------------------------------------------------- container apps
resource env 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: '${prefix}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: '${vnet.id}/subnets/aca'
      internal: false
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    zoneRedundant: false
  }
}

resource envConfigStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: env
  name: 'taoconfig'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: configShare.name
      accessMode: 'ReadWrite'
    }
  }
}

resource envDataStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: env
  name: 'taodata'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: dataShare.name
      accessMode: 'ReadWrite'
    }
  }
}

var imageRef = '${acr.properties.loginServer}/${image}'
var taoUrl = 'https://${appName}.${env.properties.defaultDomain}'
// uid/gid 33 = www-data in the php:*-bookworm image.
var mountOptions = 'uid=33,gid=33,dir_mode=0775,file_mode=0664,mfsymlinks,nobrl,cache=strict'

var volumes = [
  { name: 'config', storageType: 'AzureFile', storageName: envConfigStorage.name, mountOptions: mountOptions }
  { name: 'data', storageType: 'AzureFile', storageName: envDataStorage.name, mountOptions: mountOptions }
]
var volumeMounts = [
  { volumeName: 'config', mountPath: '/var/www/html/config' }
  { volumeName: 'data', mountPath: '/var/www/html/data' }
]
var registries = [
  { server: acr.properties.loginServer, identity: identity.id }
]

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'tao'
          image: imageRef
          resources: { cpu: json(cpu), memory: memory }
          volumeMounts: volumeMounts
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/healthz', port: 8080 }
              initialDelaySeconds: 1
              periodSeconds: 3
              failureThreshold: 10
            }
            {
              type: 'Liveness'
              httpGet: { path: '/healthz', port: 8080 }
              periodSeconds: 30
            }
          ]
        }
      ]
      volumes: volumes
      scale: {
        minReplicas: 0
        maxReplicas: maxReplicas
        cooldownPeriod: cooldownSeconds
        rules: [
          {
            name: 'http'
            http: { metadata: { concurrentRequests: string(concurrentRequestsPerReplica) } }
          }
        ]
      }
    }
  }
  dependsOn: [ acrPull ]
}

// One-time installer. Start with: az containerapp job start -g <rg> -n <prefix>-install
resource installJob 'Microsoft.App/jobs@2025-01-01' = {
  name: '${prefix}-install'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      replicaTimeout: 3600
      replicaRetryLimit: 0
      registries: registries
      secrets: [
        { name: 'db-password', value: mysqlAdminPassword }
        { name: 'tao-admin-password', value: taoAdminPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'install'
          image: imageRef
          args: [ '/usr/local/bin/tao-install.sh' ]
          resources: { cpu: json(cpu), memory: memory }
          volumeMounts: volumeMounts
          env: [
            { name: 'TAO_DB_DRIVER', value: 'pdo_mysql' }
            { name: 'TAO_DB_HOST', value: mysql.properties.fullyQualifiedDomainName }
            { name: 'TAO_DB_NAME', value: dbName }
            { name: 'TAO_DB_USER', value: mysqlAdminUser }
            { name: 'TAO_DB_PASSWORD', secretRef: 'db-password' }
            { name: 'TAO_URL', value: taoUrl }
            { name: 'TAO_ADMIN_USER', value: taoAdminUser }
            { name: 'TAO_ADMIN_PASSWORD', secretRef: 'tao-admin-password' }
            { name: 'TAO_EXTENSIONS', value: taoExtensions }
            { name: 'TAO_GUEST_ACCESS', value: taoGuestAccess ? 'on' : 'off' }
            { name: 'TAO_LOG_LEVEL', value: taoLogLevel }
            { name: 'TAO_RESET_ADMIN_PASSWORD', value: resetAdminPassword ? 'yes' : 'no' }
          ]
        }
      ]
      volumes: volumes
    }
  }
  dependsOn: [ acrPull, mysqlDb, mysqlTls ]
}

output taoUrl string = taoUrl
output appName string = app.name
output installJobName string = installJob.name
output mysqlHost string = mysql.properties.fullyQualifiedDomainName
output storageAccount string = storage.name
