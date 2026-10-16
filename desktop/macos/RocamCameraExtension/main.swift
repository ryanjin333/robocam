import CoreMediaIO

let providerSource = RocamProviderSource()
CMIOExtensionProvider.startService(provider: providerSource.provider)
dispatchMain()
