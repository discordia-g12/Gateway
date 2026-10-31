const DENY_EMAIL_NOT_VERIFIED = "email_not_verified";
const DENY_STAFF_ONLY = "staff_only";

// Secrets de la Action (Auth0 Dashboard → Actions → esta Action → Secrets):
//   BACKOFFICE_CLIENT_ID  client ID de la aplicación "Discordia Backoffice" (backoffice.discordia.lol)

exports.onExecutePostLogin = async (event, api) => {
  const NAMESPACE = "https://discordia.app";

  if (event.user.email_verified !== true) {
    return api.access.deny(DENY_EMAIL_NOT_VERIFIED);
  }

  const role = (event.user.app_metadata && event.user.app_metadata.role) || "user";

  // Al backoffice solo entra el staff: a cualquier otra cuenta se le rechaza el login de esa aplicación,
  // así no obtiene un token para backoffice.discordia.lol. Es una capa más: sin el secret el backoffice
  // igual muestra "sin acceso", y los endpoints de staff los vuelve a autorizar Kong (ADR-002 del Gateway)
  const backofficeClientId = event.secrets && event.secrets.BACKOFFICE_CLIENT_ID;
  if (backofficeClientId && event.client.client_id === backofficeClientId && role !== "staff") {
    return api.access.deny(DENY_STAFF_ONLY);
  }

  if (event.user.email) {
    api.accessToken.setCustomClaim(`${NAMESPACE}/email`, event.user.email);
  }

  api.accessToken.setCustomClaim(`${NAMESPACE}/email_verified`, event.user.email_verified === true);

  api.accessToken.setCustomClaim(`${NAMESPACE}/role`, role);

  const username = event.user.user_metadata && event.user.user_metadata.username;
  if (typeof username === "string" && username.length > 0) {
    api.idToken.setCustomClaim(`${NAMESPACE}/username`, username);
  }
};