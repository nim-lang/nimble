# Troubleshooting



* `SSL support is not available. Cannot connect over SSL. [HttpRequestError]`

Make sure that Nimble is configured to run with SSL, adding a `-d:ssl` flag to the file `src/nimble.nim.cfg`.
After that, you can run `src/nimble install` and overwrite the existing installation.



* `Could not download: error:14077410:SSL routines:SSL23_GET_SERVER_HELLO:sslv3 alert handshake failure`

If you are on macOS, you need to set and export the `DYLD_LIBRARY_PATH` environment variable to the directory where your OpenSSL libraries are.
For example, if you use OpenSSL, you have to set `export DYLD_LIBRARY_PATH=/usr/local/opt/openssl/lib` in your `$HOME/.bashrc` file.



* `Error: ambiguous identifier: 'version' --use nimscriptapi.version or system.version`

Make sure that you are running at least version 0.16.0 of Nim (or the latest nightly).



* `Error: cannot open '/home/user/.nimble/lib/system.nim'.`

Nimble cannot find the Nim standard library.
This is considered a bug so please report it.
As a workaround, you can set the `NIM_LIB_PREFIX` environment variable to the directory where `lib/system.nim` (and other standard library files) are found.
Alternatively, you can also configure this in Nimble's config file.
