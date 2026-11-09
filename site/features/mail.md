# Mail

WordPress sends mail through PHP's `mail()`. The image routes that through
[msmtp](https://marlam.de/msmtp/) to an SMTP relay, configured from the
chart's values through environment variables. No mail plugin is needed and
nothing is written to the database.

```yaml
smtpHost: smtp.example.com
smtpPort: "587"
smtpUser: wordpress@example.com
smtpExistingSecret: my-smtp-secret   # key: smtp-password
smtpProtocol: tls
smtpFromEmail: wordpress@example.com
smtpFromName: Example Blog
```

Without `smtpHost` every send fails, with a line in the container log:
`[mail error] SMTP_HOST is not defined`.

## Parameters

| Parameter | Description | Default |
|---|---|---|
| `smtpHost` | SMTP relay host | `""` |
| `smtpPort` | SMTP relay port. Empty leaves it to msmtp: 25, or 465 with `smtpProtocol: ssl` | `""` |
| `smtpUser` | SMTP user name. Authentication switches on as soon as a user or a password is set | `""` |
| `smtpPassword` | SMTP password | `""` |
| `smtpExistingSecret` | Name of a Secret with the password under the key `smtp-password`; `smtpPassword` is then ignored | `""` |
| `smtpProtocol` | Connection security, see below | `""` |
| `smtpFromEmail` | Sender address, see below | `""` |
| `smtpFromName` | Display name for the sender address; requires `smtpFromEmail` | `""` |

## Connection security

| `smtpProtocol` | Connection |
|---|---|
| `tls` | STARTTLS; relays usually offer it on port 587, which `smtpPort` has to name |
| `ssl` | implicit TLS (smtps), port 465 |
| `none` | unencrypted, even with credentials |
| `""` (default) | unencrypted without credentials; STARTTLS as soon as `smtpUser` or a password is set |

Credentials set through these values are therefore not sent over an
unencrypted connection unless `none` says so. Set `none` only for an internal
relay that authenticates but offers no TLS. Any other value fails the render.

The empty default looks at `smtpUser`, `smtpPassword` and `smtpExistingSecret`
only. Credentials that reach the container another way, as `SMTP_USER` or
`SMTP_PASSWORD` in `extraEnvVars`, `extraEnvVarsCM` or `extraEnvVarsSecret`,
switch nothing on: set `smtpProtocol: tls` or `ssl` next to them.

## Sender address

With `smtpFromEmail` set, the address becomes the envelope sender and replaces
the message's `From` header on its way into msmtp. The rewriting happens in
the transport; no code is added to WordPress. Relays that tie the sender to
the authenticated identity need it: Office 365, for one, rejects a message
whose `From` header differs from the account.

`smtpFromName` adds a display name (`Name <address>`); names outside ASCII are
encoded per RFC 2047. Setting it without `smtpFromEmail` fails the render.

Left empty, envelope and header stay what WordPress wrote, by default
`wordpress@<site host>`.
