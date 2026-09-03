import { apiInitializer } from "discourse/lib/api";

// v1.0.1 modified the core preferences/account controller so it could reuse
// Discourse's native delete button. The plugin now owns its button and routing
// through the user-preferences-account outlet instead. Keep this initializer as
// a valid no-op so in-place upgrades from v1.0.1 cleanly neutralize the old
// controller modification without breaking Discourse's initializer loader.
export default apiInitializer(() => {});
