# Touch Up login launcher

This per-user LaunchAgent starts the signed `/Applications/Touch Up.app` fifteen
seconds after an Aqua login. It then waits up to 90 seconds for the privileged
helper's readiness socket. The helper publishes that socket only after it owns
the WCH mouse interface, so Touch Up cannot win the capture race during login.

Install it as the logged-in desktop user:

```sh
./extras/touch-up-launcher/install.sh
```

The launcher passes the exact installed app bundle path to LaunchServices,
rather than resolving an app by name or directly executing it from the unsigned
delay wrapper. This preserves Touch Up's signed TCC identity. It restarts after
a nonzero launcher exit—including a helper-readiness timeout—but respects a
normal user quit. Its diagnostic log is capped to the current 1 MiB file plus
one previous file under `~/Library/Logs`. Installing this user component needs
no administrator privileges; the required helper is installed separately by
the combined rack-screen suite.

To remove only the launcher:

```sh
./extras/touch-up-launcher/uninstall.sh
```

The installed files live under `~/Library/Application Support/com.rofkek.touch-up/`
and `~/Library/LaunchAgents/com.rofkek.touch-up.plist`.
