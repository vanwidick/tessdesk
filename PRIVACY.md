# TessDesk: Privacy and Disclosures

_Version 4.1 · Oct 1, 2026 · Design by Van_

TessDesk (the Windows desktop widget and the phone web app at vanwidick.github.io/tessdesk) is an **unofficial** app. It is **not made by, affiliated with, or endorsed by Tesla, Inc. or Tessie**.

## What TessDesk reads and does
- It uses **your Tessie API token** to **read vehicle data** from Tessie: location, battery and range, charging, tire pressures and warnings, lock state, windows and climate.
- It **sends commands only when you press a control**: lock/unlock, vent/close windows, climate on/off, cabin temperature, charge limit. Each one asks you to confirm when that makes sense (for example unlock, vent and charge limit).
- Regular polling uses Tessie's cached state, so it does not wake the car. **Commands can wake the car and use a little battery.**
- Use the controls only when it is safe and legal (not while driving).

## Where your data lives
- **Desktop:** your token, settings, and email App Password are stored only on your PC, in the TessDesk folder. The token and password are encrypted with Windows DPAPI, so only your Windows account can read them.
- **Phone:** your token and settings stay in your browser's local storage on that phone.
- The token is sent **only to api.tessie.com**. TessDesk has no server, no analytics, and no tracking, and nothing is sent to the TessDesk author.

## Reminders
- Desktop reminders ("Remind me to get air") are sent at the time you pick by Windows Task Scheduler, through **your own email account** (SMTP), as email and/or as a text through your carrier's email-to-SMS gateway.
- Carrier gateways are being shut down. AT&T stopped in June 2025, T-Mobile is unreliable, and Verizon ends by Mar 31, 2027. **Email is the reliable choice.**
- Phone reminders are a calendar event (.ics file or Google Calendar link) or an email draft that you send yourself. TessDesk does not send them.

## Costs
Charging costs are **estimates** based on the rates and efficiency you enter. They are not your utility bill.

## No warranty
TessDesk is provided as is, with no warranty of any kind. You use it at your own risk. **Tessie's Terms of Service** apply to your Tessie account and API token.

## Permissions you choose (saved with a timestamp in config.json / on the phone)
1. Read vehicle data from Tessie (required).
2. Send vehicle commands (optional; when off, the controls are disabled).
3. Reminders by email/text (optional).

## Revoke access or uninstall
- **Revoke:** delete the API token in the Tessie app (Settings → API) or at https://dash.tessie.com/settings/api. TessDesk then can't read or control anything.
- **Uninstall (desktop):** double-click "Uninstall TessDesk.cmd" in the TessDesk folder (%LOCALAPPDATA%\TessDesk by default). It stops the widget and removes its reminder tasks, shortcuts, and folder (token, settings, and password included).
- **Phone:** Settings → "Forget token", then remove the home-screen icon and clear the site data for vanwidick.github.io.
