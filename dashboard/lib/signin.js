"use strict";
/**
 * How people sign in to this panel (2026-11-02; the administrator: "remove the authenticator
 * option completely" for Hamdiano's installs).
 *
 *   default            username + password + a second factor: the authenticator code (TOTP),
 *                      or a passkey (Windows Hello). Step-up asks for either.
 *   HHOS_PASSWORD_ONLY=1   username + password, nothing else: no authenticator enrolment, no
 *                      code at sign-in, no passkeys; step-up (approving a sensitive action)
 *                      asks for the password again. Hamdiano (github.com/hamdyy10/Hamdiano) sets it.
 */
const passwordOnly = process.env.HHOS_PASSWORD_ONLY === "1";

module.exports = { passwordOnly };
