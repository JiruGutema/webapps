### webapps

Turn any website into a desktop app on Linux with one command, using Firefox's built-in web apps feature ("Taskbar Tabs").

```bash
./webapps.sh https://youtube.com
```

The app gets its own window, icon and launcher in your app menu. It runs inside your normal Firefox profile, so you stay logged in and no extra Firefox is started.

### Requirements

- Linux with a freedesktop desktop (GNOME, KDE, …)
- Firefox 157 or newer
- `jq`, `unzip`, `python3`

### Usage

```bash
./webapps.sh https://youtube.com           # install
./webapps.sh x.com -n "X"                  # https:// is optional; -n sets the name
./webapps.sh -r youtube.com                # remove by URL…
./webapps.sh -r YouTube                    # …or by name
./webapps.sh list                          # list installed apps
./webapps.sh check                         # check profiles, enable the feature
./webapps.sh frameless off                 # app windows with a toolbar
./webapps.sh frameless on                  # app windows without one (default)
```

Options:

| Option | Description |
| --- | --- |
| `-p <profile>` | Use a specific Firefox profile (name or path) |
| `-n <name>` | App name shown in the menu |
| `-y` | Answer yes to every prompt |

Running the install again for an app that already exists refreshes its icon.

### First run

The feature is off by default in Firefox. The script scans all your Firefox profiles and offers to turn it on:

```
Firefox profiles:
  default-release      disabled
  Profile 1            disabled
  default-esr          incompatible: its Firefox install (/usr/lib/firefox-esr) no longer exists

Web apps (Taskbar Tabs) are disabled in 2 profile(s). Enable them? [Y/n]
```

Restart Firefox afterwards, then install apps. Incompatible profiles, such as ones whose Firefox is too old or no longer installed, are reported and logged to `~/.local/state/webapps/install.log`.

### How it works

- The script launches `firefox -taskbar-tab <id> -new-window <url>`. Firefox registers the app, opens its window and writes the launcher to `~/.local/share/applications/`.
- The script then downloads a sharp icon from the site's web app manifest, `apple-touch-icon` or favicons, falling back to Google's favicon service. Firefox on its own only uses favicons it already has cached.
- Frameless mode adds a marked block to the profile's `userChrome.css` that hides the toolbar in app windows only. Normal browser windows are unaffected. Your own CSS is left alone.

### Good to know

- App windows belong to your running Firefox. Closing the main browser window keeps apps open, but quitting Firefox (Ctrl+Q) closes them too.
- In frameless windows: move with **Super+drag**, maximize with **Super+Up**, close with **Ctrl+W**.
- Apps can also be added from Firefox itself with the "Add tab to taskbar" button in the address bar.
