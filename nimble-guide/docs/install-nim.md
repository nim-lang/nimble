# Installing Nim

Nimble can be used to install Nim globally and manage global Nim versions. In this quality, it's direct replacement for tools like [choosenim](https://github.com/dom96/choosenim) and [grabnim](https://codeberg.org/janAkali/grabnim).

## Steps

1. Download Nimble binary for your platform from the [releases page](https://github.com/nim-lang/nimble/releases) and extract the downloaded binary somewhere in your `PATH`.

1. If you're on Windows, download an archive with the DLLs required for Nim from the [official Nim website](https://nim-lang.org/download/dlls.zip) and extract its content somewhere in your `PATH`.

1. Install the latest Nim globally:

    ```shell
    $ nimble install -g nim
    ```

    If you need a specific version:

    ```shell
    $ nimble install -g nim@2.2.6`.
    ```

1. To set up development environment, install nimlangserver and nph globally:

    ```shell
    $ nimble install -g nimlangserver nph
    ```
