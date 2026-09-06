import MacParakeetViewModels

@MainActor
struct AppFeatureDependencies {
    #if !MACPARAKEET_DISABLE_DISCOVER
    let discoverViewModel = DiscoverViewModel()
    #endif
}
