const DENY_EMAIL_NOT_VERIFIED = "email_not_verified";

exports.onExecutePostLogin = async (event, api) => {
  const NAMESPACE = "https://discordia.app";

  if (event.user.email_verified !== true) {
    return api.access.deny(DENY_EMAIL_NOT_VERIFIED);
  }

  if (event.user.email) {
    api.accessToken.setCustomClaim(`${NAMESPACE}/email`, event.user.email);
  }

  api.accessToken.setCustomClaim(`${NAMESPACE}/email_verified`, event.user.email_verified === true);

  const role = (event.user.app_metadata && event.user.app_metadata.role) || "user";
  api.accessToken.setCustomClaim(`${NAMESPACE}/role`, role);

  const username = event.user.user_metadata && event.user.user_metadata.username;
  if (typeof username === "string" && username.length > 0) {
    api.idToken.setCustomClaim(`${NAMESPACE}/username`, username);
  }
};