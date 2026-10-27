// Firefox default preferences of the beamai_muse browser (installed into the
// app's defaults/pref; ordinary defaults, not locked). Only what running it
// unattended needs; everything else is Firefox's own default.

// our bridge extension sits unsigned in the system scope
// (/usr/share/mozilla/extensions/<firefox id>/, as Debian's webext-* packages;
// Debian's build accepts unsigned add-ons there): enable it on first start
// instead of asking (policies.json locks it, so it cannot be removed)
pref("extensions.autoDisableScopes", 0);
// no first-run, welcome, privacy-notice or default-browser tabs and prompts
pref("browser.aboutwelcome.enabled", false);
pref("datareporting.policy.firstRunURL", "");
pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
pref("toolkit.telemetry.reportingpolicy.firstRun", false);
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.startup.homepage_override.mstone", "ignore");
// a browser restarted by init.sh starts clean: muse re-opens its sessions
pref("browser.sessionstore.resume_from_crash", false);
// localhost goes through the egress proxy too (as Chrome's <-loopback>)
pref("network.proxy.allow_hijacking_localhost", true);
