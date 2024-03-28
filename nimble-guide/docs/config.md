# Configuration

At startup Nimble will attempt to read ``~/.config/nimble/nimble.ini`` on Linux (on Windows it will attempt to read ``C:\Users\<YourUser>\AppData\Roaming\nimble\nimble.ini``).

The format of this file corresponds to the ini format with some Nim enhancements.
For example:

```ini
nimbleDir = r"C:\Nimble\"

[PackageList]
name = "CustomPackages"
url = "http://mydomain.org/packages.json"

[PackageList]
name = "Local project packages"
path = r"C:\Projects\Nim\packages.json"
```

You can currently configure the following in this file:

* `nimbleDir` - The directory which Nimble uses for package installation.
  **Default:** `~/.nimble/`
* `chcp` - Whether to change the current code page when executing Nim application packages.
  If `true` this will add `chcp 65001` to the .cmd stubs generated in `~/.nimble/bin/`.
  **Default:** `true`
* `[PackageList]` + `name` + (`url` | `path`) - You can use this section to specify a new custom package list.
  Multiple package lists can be specified.
  Nimble defaults to the "Official" package list, you can override it by specifying a `[PackageList]` section named "official".
  Multiple URLs can be specified under each section, Nimble will try each in succession if downloading from the first fails.
  Alternatively, ``path`` can specify a local file path to copy a package list `.json` file from.
* `cloneUsingHttps` - Whether to replace any `git://` inside URLs with `https://`.
  **Default:** `true`
* `httpProxy` - The URL of the proxy to use when downloading package listings.
  Nimble will also attempt to read the `http_proxy` and `https_proxy` environment variables.
  **Default:** `""`
