# WeiboIntegrationFix

Restores the built-in Weibo integration on iOS 6 without a computer, proxy, or LAN bridge. The tweak translates the retired system API calls locally and connects the device directly to Weibo over HTTPS.

Tested on an iPhone 5 (`iPhone5,2`) running iOS 6.1.3.

## Features

- SMS-code login
- Account name and profile information
- Text posts
- Photo posts with accompanying text
- Requests from the built-in share sheet and compatible Notification Center widgets
- Direct HTTPS communication with `api.weibo.cn` and `login.sina.com.cn`

## Requirements

- Jailbroken iOS 6 device
- MobileSubstrate
- A Weibo account whose phone number can receive Weibo verification messages

No TLS tweak or companion server is required.

## Installation

Install the `.deb` from the Releases page using your preferred package manager, then respring or reboot the device.

If another Weibo API repair tweak or bridge is installed, disable it first to avoid request-handler conflicts.

## Login

Open **Settings → Weibo → Add Account**.

The original iOS 6 screen has no SMS button, so login is performed in two passes:

1. Enter the phone number and any non-numeric placeholder in the password field, then tap **Sign In**. A verification message is requested; iOS may display this first attempt as a login error.
2. Replace the password with the SMS verification code and tap **Sign In** again.

A 4–8 digit value is treated as a verification code only after a code has been requested. The placeholder password is not sent to Weibo.

The current login path is confirmed with a mainland China number. International-number behavior depends on Weibo's current SMS endpoint and has not yet been verified.

## Privacy and security

- API and login traffic uses HTTPS.
- The Weibo session credential is stored by iOS as the account's OAuth token.
- The tweak's preferences retain the phone number, UID, screen name, and temporary SMS-login state so iOS can renew the account. Do not share that preferences file.
- Diagnostic output is written to `/var/tmp/weibointegrationfix.log` and does not intentionally include passwords, SMS codes, or session tokens.

## Building

Install [Theos](https://theos.dev/docs/installation), then run:

```sh
./package.sh
```

The project targets armv7 and iOS 6.0 or later.

## Known limitations

- SMS login uses the existing username/password fields because the stock Settings pane has no SMS button.
- International phone numbers are currently unverified.
- A separately installed Notification Center sharing widget may be required because stock iOS 6 exposes only the built-in Facebook and Twitter compose widgets.

## License

MIT
