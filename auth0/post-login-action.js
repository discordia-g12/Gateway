/**
 * Auth0 Post Login Action — "Discordia: enforce email verification + custom claims"
 *
 * Trigger: Login / Post Login. Corre en cada login y en cada renovación con
 * refresh token, para todas las aplicaciones del tenant.
 *
 * 1) Barrera principal de verificación de email.
 *
 * 2) Claims custom para la API.
 *    Los access tokens de una API custom (audience = https://api.discordia.com)
 *    no traen email ni email_verified
 *    Se inyectan como claims namespaced que el Gateway lee y propaga como headers.
 *
 * Los nombres tienen que coincidir con las variables de entorno del Gateway
 * @param {Event} event
 * @param {PostLoginAPI} api
 */
exports.onExecutePostLogin = async (event, api) => {
  const NAMESPACE = "https://discordia.app";

  if (event.user.email_verified !== true) {
    return api.access.deny(
      "Verificá tu email antes de ingresar a Discordia. Te enviamos un enlace a tu casilla de correo.",
    );
  }

  if (event.user.email) {
    api.accessToken.setCustomClaim(`${NAMESPACE}/email`, event.user.email);
  }

  api.accessToken.setCustomClaim(`${NAMESPACE}/email_verified`, event.user.email_verified === true);

  const role = (event.user.app_metadata && event.user.app_metadata.role) || "user";
  api.accessToken.setCustomClaim(`${NAMESPACE}/role`, role);
};
