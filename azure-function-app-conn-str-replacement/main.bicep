@description('The name of the storage account to create')
param storageAccountName string = 'myblobstore${uniqueString(resourceGroup().id)}'

@description('The name of the Cosmos DB account to create')
param cosmosDBAccountName string = 'mycosmosdb${uniqueString(resourceGroup().id)}'

@description('The name of the function app to create')
param functionAppName string = 'myfunctionapp${uniqueString(resourceGroup().id)}'

@description('The name of the key vault to create')
param keyVaultName string = 'mykeyvault-${uniqueString(resourceGroup().id)}'

@description('The name of the managed identity resource.')
param identityName string = 'myuseridentity-${uniqueString(resourceGroup().id)}'

@description('The name of the Language Understanding resource.')
param textAnalyticsName string = 'lang-identity-training-demo-002'

@description('Whether the managed identity has contributor access on the resource group level')
param isRGContributor bool = false

@description('The name of the region to deploy resources to')
param location string = resourceGroup().location

param tags object = {
  Environment: 'Demo'
  Contact: 'info@mungana.com'
  Repo: 'https://github.com/rihonegroup/remote-assets/securing-azure-paas-access-managed-identities'
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource lang 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: textAnalyticsName
  location: location
  kind: 'TextAnalytics'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  sku: {
    name: 'F0'
  }
  properties: {
    customSubDomainName: textAnalyticsName
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'myblobcontainer'
  parent: blobService
  properties: {}
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${functionAppName}'
  location: location
  properties: any({
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${functionAppName}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'Y1'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    reserved: true
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      keyVaultReferenceIdentity: managedIdentity.properties.principalId
      appSettings: [
        // This is the traditional way to authenticate the Function App runtime to access the storage account
        // We will use the managed identity instead
        // {
        //   name: 'AzureWebJobsStorage'
        //   value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=core.windows.net;AccountKey=${storageAccount.listKeys().keys[0].value}'
        // }

        // It is important to note that this may affect your binding configuration
        // Learn more: https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference?tabs=blob&pivots=programming-language-python#connecting-to-host-storage-with-an-identity
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        // Uncomment if your prefer to use the user-assigned identity instead of the system-assigned identity
        // {
        //   name: 'AzureWebJobsStorage__clientId'
        //   value: managedIdentity.properties.clientId
        // }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '${storageAccount.properties.primaryEndpoints.blob}${blobContainer.name}/deployments/functionapp.zip'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableWorkerIndexing'
        }
        {
          name: 'AzureWebJobsSecretStorageType'
          value: 'keyvault'
        }
        {
          name: 'AzureWebJobsSecretStorageKeyVaultUri'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'AzureWebJobsSecretStorageKeyVaultClientId'
          value: managedIdentity.properties.clientId
        }
        // We could use keyvault.getSecrets() to retrieve the secrets, but I think this
        // will require the value to be passed in as a secure parameter - maybe later
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsDisableHomepage'
          value: 'true'
        }
        {
          name: 'KEYVAULT_ENDPOINT'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'USER_IDENTITY_CLIENT_ID'
          value: managedIdentity.properties.clientId
        }
        {
          name: 'AZURE_LANGUAGE_ENDPOINT'
          value: lang.properties.endpoint
        }
        {
          name: 'COSMOSDB_ENDPOINT'
          value: cosmosDb.properties.documentEndpoint
        }
      ]
    }
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosDBAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    locations: [
      {
        locationName: location
      }
    ]
    databaseAccountOfferType: 'Standard'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-04-15' = {
  name: 'IdentityDemoDB'
  parent: cosmosDb
  properties: {
    options: {
      autoscaleSettings: {
        maxThroughput: 1000
      }
    }
    resource: {
      id: 'IdentityDemoDB'
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  name: 'mydbcontainer'
  parent: database
  properties: {
    resource: {
      id: 'mydbcontainer'
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
      }
    }
    options: {
      throughput: 400
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enablePurgeProtection: true
    // This must be enabled if we intend to use keyvault.getSecrets() to reference secrets during deployment
    enabledForDeployment: true
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource langSubscriptionSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  name: 'language-api-key'
  parent: keyVault
  properties: {
    value: lang.listKeys().key1
    contentType: 'text/plain'
  }
}

resource appInsightsConnStr 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  name: 'appi-connection-string'
  parent: keyVault
  properties: {
    value: appInsights.properties.ConnectionString
    contentType: 'text/plain'
  }
}

// Assign automation roles
// Role Definitions Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
resource resourceGroupAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (isRGContributor) {
  name: guid('${managedIdentity.name}-rg-control-access')
  scope: resourceGroup()
  properties: {
    description: 'Allow identity to perform automated management tasks on the resource group'
    principalType: 'ServicePrincipal'
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  }
}

resource storageAccountBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${managedIdentity.name}-storage-blob-access')
  scope: storageAccount
  properties: {
    description: 'Allow identity to read and write blob data'
    principalType: 'ServicePrincipal'
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource storageAccountQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${managedIdentity.name}-storage-queue-access')
  scope: storageAccount
  properties: {
    description: 'Allow identity to read and write queue messages'
    principalType: 'ServicePrincipal'
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

resource cosmosDbReadWriteRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2023-04-15' = {
  name: guid('${cosmosDb.name}-customreadwriterole')
  parent: cosmosDb
  properties: {
    assignableScopes: [
      cosmosDb.id
    ]
    permissions: [
      {
        dataActions: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
        ]
        notDataActions: []
      }
    ]
    roleName: 'Cosmos DB Custom Data Contributor'
    type: 'CustomRole'
  }
}

@description('Allow identity to list containers, as well as read and write from CosmosDB')
resource cosmosDBDataAccess 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15' = {
  name: guid('${managedIdentity.name}-cosmosdb-data-access')
  parent: cosmosDb
  properties: {
    scope: cosmosDb.id
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: cosmosDbReadWriteRole.id
    // https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-setup-rbac#built-in-role-definitions
    // THIS DOES NOT WORK, Because Azure...
    // roleDefinitionId: '/subscriptions/${subscription().id}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosDb.name}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
  }
}

resource keyVaultSecretsAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${managedIdentity.name}-kv-secrets-access')
  scope: keyVault
  properties: {
    description: 'Allow identity to read key vault secrets'
    principalType: 'ServicePrincipal'
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

// Assign Function App roles for the runtime and blob trigger
@description('Storage Account Contributor Role')
resource functionAppAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${functionApp.name}-function-app-access')
  scope: storageAccount
  properties: {
    description: 'Allow function app system-assigned identity to access storage account'
    principalType: 'ServicePrincipal'
    principalId: functionApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  }
}

@description('Storage Blob Data Owner Role')
resource functionAppBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${functionApp.name}-function-app-blob-access')
  scope: storageAccount
  properties: {
    description: 'Allow function app system-assigned identity to read and write blob data'
    principalType: 'ServicePrincipal'
    principalId: functionApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

@description('Storage Queue Data Contributor Role')
resource functionAppQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${functionApp.name}-function-app-queue-access')
  scope: storageAccount
  properties: {
    description: 'Allow function app system-assigned identity to read and write queue messages'
    principalType: 'ServicePrincipal'
    principalId: functionApp.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}
