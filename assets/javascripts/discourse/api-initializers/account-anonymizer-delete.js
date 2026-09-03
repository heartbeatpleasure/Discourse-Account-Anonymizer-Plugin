// Intentionally empty since v1.0.2.
//
// v1.0.1 modified the core preferences/account controller so it could reuse
// Discourse's native delete button. That button is not guaranteed to be
// rendered once core decides the account is no longer directly deletable.
// v1.0.2 therefore owns its button and live routing entirely through the
// user-preferences-account plugin outlet. Keeping this no-op file ensures an
// in-place upgrade cleanly neutralizes the v1.0.1 initializer.
