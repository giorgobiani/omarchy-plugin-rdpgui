# omarchy-plugin-rdpgui

Remote Desktop (RDP) bookmarks in the [Omarchy](https://omarchy.org/) bar,
powered by FreeRDP. Save your Windows machines once, then click to connect.
The widget handles passwords, certificate trust, a VPN that has to come up
first, and the list of open sessions.

Sessions open as normal Hyprland windows, tile, and resize with the tile.

Plugin id: `shota.rdp`

## Requirements

- Omarchy 4 (the Quickshell-based `omarchy-shell` with plugin support)
- Packages:

  ```bash
  omarchy pkg add freerdp libsecret gnome-keyring
  ```

  FreeRDP 3.x is required (the plugin runs `sdl-freerdp3`). `python` and
  `openssl` are also used; they come with every Omarchy install.

- Optional, to bring a VPN up automatically before connecting:
  [omarchy-plugin-vpngui](https://github.com/giorgobiani/omarchy-plugin-vpngui)

## Install

```bash
omarchy plugin add https://github.com/giorgobiani/omarchy-plugin-rdpgui.git --enable
```

`omarchy plugin add` shows a warning and asks you to confirm. Run in a
terminal, it also asks which bar section the widget goes in (the default is
right).

If any required package is missing, the panel says which and offers an
**Install** button that runs `omarchy pkg add` in a terminal.

### Add the window rule (recommended)

Plugins can't install Hyprland window rules, so add this line to
`~/.config/hypr/hyprland.lua`:

```lua
o.window("^(omarchy-rdp-.*)$", { tile = true, idle_inhibit = "focus" })
```

With it, sessions tile (the remote resolution follows the tile) and your
screen doesn't lock while a session is focused. Check the config with
`hyprctl reload && hyprctl configerrors`.

### Manual install

```bash
git clone https://github.com/giorgobiani/omarchy-plugin-rdpgui.git \
  ~/.config/omarchy/plugins/shota.rdp
omarchy-shell shell rescanPlugins
omarchy plugin enable shota.rdp
```

The folder has to be named after the plugin id (`shota.rdp`).

## Update / uninstall

```bash
omarchy plugin update shota.rdp   # shows the diff, then fast-forwards
omarchy plugin remove shota.rdp
```

To remove everything the plugin stored:

```bash
rm -rf ~/.local/state/omarchy/plugins/shota.rdp ~/.cache/omarchy/shota.rdp
secret-tool clear service omarchy-rdp   # saved passwords
```

Also remove the `omarchy-rdp-` window rule from `~/.config/hypr/hyprland.lua`.

## Use

1. Click the monitor icon (󰢹) in the bar.
2. Choose **Add your first computer** and fill in:
   - **Name**: e.g. `Office PC`
   - **Computer**: host name or IP, optionally with a port
     (`pc01.corp.example.com`, `10.0.0.5:3390`, `[fe80::1]:3389`)
   - optionally **Username**, **Domain**, and **Remember password**
   - **Connect VPN first**: pick one of your VPN profiles (OpenConnect or
     OpenVPN, from [omarchy-plugin-vpngui](https://github.com/giorgobiani/omarchy-plugin-vpngui)) to have
     it connected before the session starts
3. Click the bookmark to connect. Clicking a bookmark whose session is
   already open brings that window to the front.

On the first connection you're usually asked to trust the server
certificate, which is normal for Windows machines with a self-signed
certificate. The panel shows the SHA-256 fingerprint, common name and
expiry date. If the certificate changes later, you're warned in red instead
of it being accepted silently.

A wrong password asks again, up to three attempts.

### Mouse and keys

| Action | What it does |
|--------|--------------|
| Left click on the icon | Open / close the panel |
| Click a bookmark / `Enter` | Connect, or focus the open session |
| `↑` `↓` / `j` `k` | Pick a bookmark |
| `x` | Disconnect the selected session |
| `n` | New bookmark |
| `e` | Edit the selected bookmark |
| `r` | Refresh |
| `Esc` | Cancel the connection in progress, or close the panel |
| `Tab` | Switch to the next bar panel |

### Bookmark options

| Option | Default | Notes |
|--------|---------|-------|
| Display | Window | *Window* starts at screen size and follows the tile (dynamic resolution); *Full screen* uses `/f` |
| Scale | Automatic | 100–200 % for HiDPI screens |
| Shared clipboard | On | Copy and paste in both directions |
| Share home folder | Off | Your home folder shows up as a drive in Windows |
| Play sound here | On | Remote audio plays on this machine |
| Send shortcuts to Windows | Off | Grabs keyboard and mouse so Alt+Tab and the Windows key go to the remote machine. Off keeps your Hyprland shortcuts working |
| Use Kerberos | Off | Only for domain-joined PCs where a domain controller is reachable (see below) |
| RD Gateway | empty | Remote Desktop Gateway host; it uses the same username, password and domain |

### Settings

| Key | Default | Range |
|-----|---------|-------|
| `refreshIntervalSec` | `5` | 2–600 |

```bash
omarchy bar set shota.rdp refreshIntervalSec 10
```

### Keyboard shortcut

Bind the IPC target in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + R", "Remote Desktop", "omarchy-shell shota.rdp toggle")
```

## IPC

```bash
omarchy-shell shota.rdp open | close | toggle | refresh | cancel
omarchy-shell shota.rdp connect "<name or id>"      # focuses the session if it's already open
omarchy-shell shota.rdp disconnect "<name or id>"
omarchy-shell shota.rdp add
omarchy-shell shota.rdp edit "<name or id>"
omarchy-shell shota.rdp status                      # e.g. "1 session open"
```

## How it works

`Panel.qml` is the bar widget and panel, `Service.qml` holds the state, and
`helper.py connect <id>` does the rest:

1. **VPN**: if the bookmark has a linked VPN that isn't up, it asks the VPN
   widget to connect it (`omarchy-shell shota.openconnect connect <uuid>`)
   and waits until the widget reports it active (`omarchy-shell
   shota.openconnect profiles`; straight from NetworkManager when the widget
   isn't loaded). The VPN widget shows its
   own password / SMS / SSO prompts.
2. **Certificate**: RDP only switches to TLS after an X.224 exchange, so the
   helper does that exchange itself and reads the server certificate. A
   certificate that is CA-signed for the host name is left to FreeRDP.
   Otherwise you're asked to trust its SHA-256 fingerprint, which is then
   passed to FreeRDP as `/cert:fingerprint:sha256:…`.
3. **Credentials**: you're asked for the username and password when needed.
   A saved password comes from the keyring.
4. **Launch**: `sdl-freerdp3` starts detached. All of its options, the
   password included, go through a private pipe (`/args-from:fd:N`), never
   in the process's command-line arguments. The window gets the Wayland app
   id `omarchy-rdp-<id>`.
5. **Result**: the helper waits for the window. FreeRDP's `ERRCONNECT_*`
   codes turn into readable errors, and a wrong password asks again.

Sessions keep running when the shell restarts. They're found again through
`hyprctl clients` (by app id or the recorded pid).

**Kerberos is off by default.** Without a reachable domain controller (KDC)
every Kerberos attempt stalls for about 30 seconds, and Windows drops the
half-open login. The plugin passes `/auth-pkg-list:!kerberos` and a
realm-less `KRB5_CONFIG`, so NTLM is used right away. Turn on *Use Kerberos*
only for domain-joined machines.

## Storage and security

- **`~/.local/state/omarchy/plugins/shota.rdp/connections.json`** (mode
  `0600`) holds the bookmarks and trusted certificate fingerprints. It holds
  no secrets.
- **Passwords** are stored only in the Secret Service keyring
  (`service=omarchy-rdp id=<id>`), and only when *Remember password* is on.
  They're saved either from the edit form or after a successful sign-in.
- **Logs**: `~/.cache/omarchy/shota.rdp/<id>.log`, FreeRDP at WARN level,
  with no credentials.

Like every Omarchy plugin, this runs unsandboxed inside `omarchy-shell`.
Read the code before you enable it.

## Troubleshooting

- **"FreeRDP isn't installed"**: `omarchy pkg add freerdp`.
- **Login hangs for about 30 seconds, then fails**: turn *Use Kerberos* off
  for that bookmark.
- **"Enable the VPN widget …"**: the bookmark has a linked VPN,
  but [omarchy-plugin-vpngui](https://github.com/giorgobiani/omarchy-plugin-vpngui)
  isn't installed and enabled.
- **Session opens floating / at the wrong size**: add the window rule above.
- **Hyprland shortcuts don't work inside a session**: turn off *Send
  shortcuts to Windows* for that bookmark.
- **Any other error**: check the session log in
  `~/.cache/omarchy/shota.rdp/<id>.log`. The id is in `connections.json`.

## License

[MIT](LICENSE)
